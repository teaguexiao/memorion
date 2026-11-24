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
import '../plaud_connection.dart';
import '../offline_recordings/import_store.dart';
import 'identity_store.dart';
import 'import_store.dart';
import 'sync_controller.dart';
import 'wifi_connector.dart';

/// App-owned queue, active while the app runs; mobile OS suspension can pause BLE.
class PlaudSyncService with WidgetsBindingObserver implements IDeviceServiceSubsciption {
  final IDeviceService devices;
  final String Function() currentOwner;
  final BtDevice? Function() pairedDevice;
  final PlaudSyncController Function(BtDevice, String)? createController;
  final _controllers = <(String, String), PlaudSyncController>{};
  Timer? _timer;
  StreamSubscription<User?>? _auth;
  bool _started = false;
  String? _owner;
  (String, DeviceConnectionState)? _lastConnectionEvent;
  PlaudSyncService(
      {required this.devices,
      String Function()? currentOwner,
      BtDevice? Function()? pairedDevice,
      this.createController})
      : currentOwner = currentOwner ?? PlaudDeviceConnection.currentOwner,
        pairedDevice = pairedDevice ?? (() => SharedPreferencesUtil().btDevice);

  PlaudSyncController controllerFor(BtDevice device) {
    final owner = currentOwner();
    return _controllers.putIfAbsent((owner, device.id), () {
      if (createController != null) return createController!(device, owner);
      return PlaudSyncController(
        deviceId: device.id,
        connectWifi: PlaudWifiConnector.supported ? PlaudWifiConnector.connect : null,
        readIdentity: () => const PlaudIdentityStore().read(owner, device.id),
        isCurrentOwner: () => owner.isNotEmpty && currentOwner() == owner,
        fetchJob: AudioJobsApi().get,
        reconnectSession: () async {
          if (currentOwner() != owner) return null;
          await devices.forceDisconnect(device.id);
          if (currentOwner() != owner) return null;
          final connection = await devices.ensureConnection(device.id, force: true);
          return connection is PlaudDeviceConnection ? connection.session : null;
        },
        openSession: () async {
          if (currentOwner() != owner || devices.connectedDevice?.id != device.id) return null;
          final connection = await devices.ensureConnection(device.id);
          return connection is PlaudDeviceConnection ? connection.session : null;
        },
        openStore: () async => PlaudImportStore(
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
                  recordingKey: 'plaud:${device.id}:${file.uri.pathSegments.last}',
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
        if (connected?.type == DeviceType.plaudNote) await devices.forceDisconnect(connected!.id);
      }
      _owner = owner;
      if (owner.isEmpty) return;
      final device = devices.connectedDevice ?? pairedDevice();
      if (device?.type == DeviceType.plaudNote) await controllerFor(device!).refresh();
    } catch (_) {/* Auth/BLE transitions retry on next event or tick. */}
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) {
    final device = devices.connectedDevice ?? pairedDevice();
    if (device?.type != DeviceType.plaudNote || device?.id != deviceId) return;
    final event = (deviceId, state);
    // Failed reconnect attempts can repeatedly publish "disconnected". They do
    // not change the recording directory; the periodic check still retries
    // cached uploads, and the next actual transition refreshes immediately.
    if (_lastConnectionEvent == event) return;
    _lastConnectionEvent = event;
    unawaited(Future<void>.microtask(checkNow));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(checkNow());
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      for (final controller in _controllers.values) {
        controller.cancelWifi();
      }
    }
  }

  @override
  void onDevices(List<BtDevice> devices) {}
  @override
  void onStatusChanged(DeviceServiceStatus status) {}
  void stop() {
    _started = false;
    _lastConnectionEvent = null;
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
