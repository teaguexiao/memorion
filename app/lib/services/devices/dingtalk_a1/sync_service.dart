import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/http/api/audio_upload.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import 'package:path_provider/path_provider.dart';
import '../dingtalk_a1_connection.dart';
import '../offline_recordings/import_store.dart';
import 'identity_store.dart';
import 'import_store.dart';
import 'sync_controller.dart';

/// App-owned queue, active while the app runs; mobile OS suspension can pause BLE.
class A1SyncService with WidgetsBindingObserver implements IDeviceServiceSubsciption {
  final IDeviceService devices;
  final String Function() currentOwner;
  final BtDevice? Function() pairedDevice;
  final A1SyncController Function(BtDevice, String)? createController;
  final _controllers = <(String, String), A1SyncController>{};
  Timer? _timer;
  StreamSubscription<User?>? _auth;
  bool _started = false;
  String? _owner;
  A1SyncService(
      {required this.devices,
      String Function()? currentOwner,
      BtDevice? Function()? pairedDevice,
      this.createController})
      : currentOwner = currentOwner ?? A1DeviceConnection.currentOwner,
        pairedDevice = pairedDevice ?? (() => SharedPreferencesUtil().btDevice);

  A1SyncController controllerFor(BtDevice device) {
    final owner = currentOwner();
    return _controllers.putIfAbsent((owner, device.id), () {
      if (createController != null) return createController!(device, owner);
      return A1SyncController(
        isCurrentOwner: () => owner.isNotEmpty && currentOwner() == owner,
        readAutoSync: () => const A1IdentityStore().autoSync(owner, device.id),
        writeAutoSync: (enabled) => const A1IdentityStore().setAutoSync(owner, device.id, enabled),
        fetchJob: AudioJobsApi().get,
        openSession: () async {
          if (currentOwner() != owner || devices.connectedDevice?.id != device.id) return null;
          final connection = await devices.ensureConnection(device.id);
          return connection is A1DeviceConnection ? connection.session : null;
        },
        openStore: () async => A1ImportStore(
            root: await getApplicationDocumentsDirectory(),
            ownerId: owner,
            deviceId: device.id,
            currentOwner: currentOwner,
            uploadWithProgress: (file, startedAt, progress) async {
              if (currentOwner() != owner) throw StateError('Account changed');
              int? status;
              AudioUploadFailure? failure;
              final result = await uploadAudioForConversation(
                  audioFile: file,
                  startedAt: startedAt,
                  language: 'auto',
                  saveRecording: true,
                  deferProcessing: true,
                  recordingKey: 'dingtalk_a1:${device.id}:${file.uri.pathSegments.last}',
                  onProgress: progress,
                  onHttpError: (code, _) => status = code,
                  onFailure: (value) => failure = value);
              if (result == null) throw OfflineImportException(status, failure);
              return OfflineImportReceipt(result.conversationId, processing: result.status == 'processing');
            }),
      );
    });
  }

  void start({Stream<User?>? authChanges}) {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    devices.subscribe(this, this);
    if (authChanges != null) _auth = authChanges.listen((_) => unawaited(checkNow()));
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(checkNow()));
    unawaited(checkNow());
  }

  Future<void> checkNow() async {
    if (!_started) return;
    try {
      final owner = currentOwner();
      if (_owner != null && owner != _owner) {
        for (final c in _controllers.values) {
          c.retire();
        }
        _controllers.clear();
        final connected = devices.connectedDevice;
        if (connected?.type == DeviceType.dingtalkA1) await devices.forceDisconnect(connected!.id);
      }
      _owner = owner;
      if (owner.isEmpty) return;
      final device = devices.connectedDevice ?? pairedDevice();
      if (device?.type == DeviceType.dingtalkA1) await controllerFor(device!).refresh();
    } catch (_) {/* Auth/BLE transitions retry on next event or tick. */}
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) =>
      unawaited(Future<void>.microtask(checkNow));
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
    _auth?.cancel();
    devices.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    for (final c in _controllers.values) {
      c.retire();
    }
    _controllers.clear();
  }
}
