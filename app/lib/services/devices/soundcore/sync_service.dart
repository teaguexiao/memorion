import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:memorion/backend/http/api/audio_upload.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/soundcore_connection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'import_store.dart';
import 'sync_controller.dart';
import 'wifi_connector.dart';

/// App-lifetime coordinator. Works even if the recordings route was never opened.
class SoundcoreSyncService with WidgetsBindingObserver implements IDeviceServiceSubsciption {
  static const _pendingProResumePrefix = 'soundcore.pending_pro_resume.';
  final IDeviceService devices;
  final String Function() currentOwner;
  final BtDevice? Function() pairedDevice;
  final SoundcoreSyncController Function(BtDevice device, String owner)? createController;
  final Duration pollInterval;
  final _controllers = <(String, String), SoundcoreSyncController>{};
  Timer? _timer;
  StreamSubscription<User?>? _authSubscription;
  bool _started = false;

  SoundcoreSyncService({
    required this.devices,
    String Function()? currentOwner,
    BtDevice? Function()? pairedDevice,
    this.createController,
    this.pollInterval = const Duration(seconds: 30),
  })  : currentOwner = currentOwner ?? _signedInOwner,
        pairedDevice = pairedDevice ?? (() => SharedPreferencesUtil().btDevice);

  static String _signedInOwner() {
    // ApiConfig can fall back to bundled values even after logout. Background
    // uploads require a real signed-in user, matching the API account.
    final user = FirebaseAuth.instance.currentUser;
    final owner = getExternalUserId();
    return user != null && !user.isAnonymous && user.uid == owner && getAuthHeader().isNotEmpty ? owner : '';
  }

  SoundcoreSyncController controllerFor(BtDevice device) {
    final owner = currentOwner();
    return _controllers.putIfAbsent((owner, device.id), () {
      if (createController != null) return createController!(device, owner);
      return SoundcoreSyncController(
        fetchProcessingJob: AudioJobsApi().get,
        retryProcessingJob: AudioJobsApi().retry,
        lookupRecordings: (recordings) async {
          String key(int id) => 'soundcore:${device.id}:$id.ogg';
          final result = await AudioJobsApi().lookupRecordings({
            for (final file in recordings) key(file.id): file.startedAt,
          });
          return {for (final file in recordings) file.id: result[key(file.id)]!};
        },
        deviceId: device.id,
        openWifi: SoundcoreWifiConnector.supported
            ? (session, onPhase) => SoundcoreWifiConnector.connect(session, onPhase: onPhase)
            : null,
        reconnectSession: () async {
          if (currentOwner() != owner) return null;
          // Physically stop the old stream, then establish a fresh protocol
          // generation. No recording or device-file deletion commands.
          await devices.forceDisconnect(device.id);
          if (currentOwner() != owner) return null;
          final connection = await devices.ensureConnection(device.id, force: true);
          return connection is SoundcoreDeviceConnection ? connection.session : null;
        },
        isCurrentOwner: () => owner.isNotEmpty && currentOwner() == owner,
        openSession: () async {
          if (devices.connectedDevice?.id != device.id) return null;
          final connection = await devices.ensureConnection(device.id);
          return connection is SoundcoreDeviceConnection ? connection.session : null;
        },
        openStore: () async => SoundcoreImportStore(
          root: await getApplicationDocumentsDirectory(),
          ownerId: owner,
          deviceId: device.id,
          currentOwner: currentOwner,
          uploadWithProgress: (file, startedAt, onProgress) async {
            if (currentOwner() != owner) throw StateError('Soundcore account changed');
            int? status;
            AudioUploadFailure? failure;
            final response = await uploadAudioForConversation(
              audioFile: file,
              startedAt: startedAt,
              language: 'auto',
              saveRecording: true,
              deferProcessing: true,
              recordingKey: 'soundcore:${device.id}:${file.uri.pathSegments.last}',
              onHttpError: (code, _) => status = code,
              onProgress: onProgress,
              onFailure: (value) => failure = value,
            );
            if (response == null) throw SoundcoreImportException(status, failure);
            return SoundcoreImportReceipt(response.conversationId, processing: response.status == 'processing');
          },
        ),
      );
    });
  }

  void start({Stream<User?>? authChanges}) {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    devices.subscribe(this, this);
    if (authChanges != null) _authSubscription = authChanges.listen((_) => unawaited(checkNow()));
    _timer = Timer.periodic(pollInterval, (_) => unawaited(checkNow()));
    unawaited(checkNow());
  }

  Future<void> checkNow() async {
    if (!_started) return;
    try {
      final owner = currentOwner();
      // Do not dispose a controller while its original account's in-flight
      // request is still completing. Its owner guard stops subsequent work.
      if (owner.isEmpty) return;
      final device = devices.connectedDevice ?? pairedDevice();
      if (device?.type == DeviceType.soundcore) {
        final controller = controllerFor(device!);
        final preferences = await SharedPreferences.getInstance();
        final pendingKey = '$_pendingProResumePrefix$owner';
        if (preferences.getBool(pendingKey) == true) {
          try {
            await controller.resumeAfterSubscriptionUpgrade();
          } finally {
            // This marker bridges only the disconnected/restarted gap. Once a
            // recorder is available, consume it exactly once; PurchaseProvider
            // owns the bounded entitlement-sync retries.
            await preferences.remove(pendingKey);
          }
        } else {
          await controller.sync();
        }
      }
    } catch (_) {
      // Startup/auth and BLE may be transitioning; next connect/resume/tick retries.
    }
  }

  Future<bool> resumeAfterSubscriptionUpgrade() async {
    final owner = currentOwner();
    if (owner.isEmpty) return false;
    final preferences = await SharedPreferences.getInstance();
    final pendingKey = '$_pendingProResumePrefix$owner';
    // Persist before consulting BLE state. Purchase reconciliation is allowed
    // to finish while the recorder is away; checkNow consumes this marker on
    // the next connection, app resume, auth change, or poll (including after a
    // process restart).
    await preferences.setBool(pendingKey, true);
    final device = devices.connectedDevice ?? pairedDevice();
    if (device?.type != DeviceType.soundcore) return true;
    try {
      return await controllerFor(device!).resumeAfterSubscriptionUpgrade();
    } finally {
      await preferences.remove(pendingKey);
    }
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) {
    // Defer until DeviceService releases its connect mutex.
    unawaited(Future<void>.microtask(checkNow));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(checkNow());
  }

  @override
  void onDevices(List<BtDevice> devices) {}
  @override
  void onStatusChanged(DeviceServiceStatus status) {}

  void stop() {
    _started = false;
    _timer?.cancel();
    _authSubscription?.cancel();
    devices.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
  }
}
