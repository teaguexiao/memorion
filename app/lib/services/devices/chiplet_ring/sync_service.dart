import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/http/api/audio_upload.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import '../chiplet_ring_connection.dart';
import 'import_store.dart';
import 'models.dart';
import 'sync_controller.dart';

class RingSyncService with WidgetsBindingObserver implements IDeviceServiceSubsciption {
  final IDeviceService devices;
  final String Function() currentOwner;
  final BtDevice? Function() pairedDevice;
  final RingSyncController Function(BtDevice, String)? createController;
  final _controllers = <(String, String), RingSyncController>{};
  Timer? _timer;
  StreamSubscription<User?>? _auth;
  Future<void>? _retiring;
  bool _started = false;
  RingSyncService(
      {required this.devices,
      String Function()? currentOwner,
      BtDevice? Function()? pairedDevice,
      this.createController})
      : currentOwner = currentOwner ?? _owner,
        pairedDevice = pairedDevice ?? (() => SharedPreferencesUtil().btDevice);
  static String _owner() {
    final user = FirebaseAuth.instance.currentUser;
    final owner = getExternalUserId();
    return user != null && !user.isAnonymous && user.uid == owner && getAuthHeader().isNotEmpty ? owner : '';
  }

  RingSyncController controllerFor(BtDevice device) {
    final owner = currentOwner();
    return _controllers.putIfAbsent((owner, device.id), () {
      if (createController != null) return createController!(device, owner);
      String key(String id) => 'chiplet_ring:${device.id}:$id.wav';
      return RingSyncController(
        isCurrentOwner: () => owner.isNotEmpty && currentOwner() == owner,
        openTransport: () async {
          if (currentOwner() != owner || devices.connectedDevice?.id != device.id) return null;
          final connection = await devices.ensureConnection(device.id);
          return connection is RingDeviceConnection ? connection.transport : null;
        },
        lookup: (files) async {
          final result =
              await AudioJobsApi().lookupRecordings({for (final file in files) key(file.id): file.startedAt!});
          return {for (final file in files) file.id: result[key(file.id)]!};
        },
        retryJob: AudioJobsApi().retry,
        reconnectTransport: () async {
          if (owner.isEmpty || currentOwner() != owner) return;
          await devices.forceDisconnect(device.id);
          if (currentOwner() == owner) await devices.ensureConnection(device.id, force: true);
        },
        openStore: () async => RingImportStore(
            root: await getApplicationDocumentsDirectory(),
            owner: owner,
            deviceId: device.id,
            currentOwner: currentOwner,
            upload: (file, time, id, progress) async {
              if (owner.isEmpty || currentOwner() != owner) throw StateError('Ring account changed');
              AudioUploadFailure? failure;
              int? status;
              final response = await uploadAudioForConversation(
                  audioFile: file,
                  startedAt: time,
                  language: 'auto',
                  saveRecording: true,
                  deferProcessing: true,
                  recordingKey: key(id),
                  onProgress: progress,
                  onFailure: (value) => failure = value,
                  onHttpError: (code, _) => status = code);
              if (response == null) {
                throw failure ??
                    AudioUploadFailure(
                        status != null && status! >= 500 ? AudioUploadIssue.server : AudioUploadIssue.unknown,
                        statusCode: status);
              }
              return RingReceipt(response.conversationId, processing: response.status == 'processing');
            }),
      );
    });
  }

  void start({Stream<User?>? authChanges}) {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    devices.subscribe(this, this);
    _auth = authChanges?.listen((_) => unawaited(checkNow()));
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(checkNow()));
    unawaited(checkNow());
  }

  Future<void> checkNow() async {
    if (!_started) return;
    final owner = currentOwner();
    final retired = _controllers.entries.where((entry) => entry.key.$1 != owner).toList();
    // Remove synchronously so concurrent auth, connection and timer callbacks
    // cannot cancel/dispose the same controller more than once.
    for (final entry in retired) {
      _controllers.remove(entry.key);
    }
    if (retired.isNotEmpty) {
      final previous = _retiring;
      _retiring = () async {
        try {
          await previous;
        } catch (_) {/* Continue retiring the next owner. */}
        for (final entry in retired) {
          try {
            await entry.value.cancelForAccount();
          } catch (_) {
            // A peripheral error must not retain the previous account's queue.
          } finally {
            entry.value.dispose();
          }
        }
        final active = devices.connectedDevice;
        if (active?.type == DeviceType.chipletRing && retired.any((entry) => entry.key.$2 == active!.id)) {
          try {
            await devices.forceDisconnect(active!.id);
          } catch (_) {}
        }
      }();
    }
    await _retiring;
    if (!_started || currentOwner() != owner) return;
    // Pairing and battery display do not require a cloud import account. An
    // actual account change still retires its queue/transport above.
    if (owner.isEmpty) return;
    final device = devices.connectedDevice ?? pairedDevice();
    if (device?.type != DeviceType.chipletRing) return;
    try {
      await controllerFor(device!).sync();
    } catch (_) {}
  }

  Future<void> resumeAfterSubscriptionUpgrade() async {
    if (currentOwner().isEmpty) return;
    final device = devices.connectedDevice ?? pairedDevice();
    if (device?.type == DeviceType.chipletRing) await controllerFor(device!).resumeAfterSubscriptionUpgrade();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(checkNow());
  }

  @override
  void onDevices(List<BtDevice> devices) {}
  @override
  void onStatusChanged(DeviceServiceStatus status) {}
  @override
  void onDeviceConnectionStateChanged(String id, DeviceConnectionState state) => unawaited(checkNow());
  void stop() {
    _started = false;
    _timer?.cancel();
    unawaited(_auth?.cancel());
    devices.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in _controllers.values) {
      unawaited(controller.cancelForAccount().catchError((Object _) {}));
      controller.dispose();
    }
    _controllers.clear();
  }
}
