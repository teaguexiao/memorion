import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/soundcore/sync_service.dart';
import 'package:memorion/services/devices/dingtalk_a1/sync_service.dart';
import 'package:memorion/services/devices/plaud/sync_service.dart';
import 'package:memorion/services/devices/chiplet_ring/sync_service.dart';
import 'package:memorion/services/sockets.dart';
import 'package:memorion/services/wals.dart';
import 'package:flutter/services.dart';

class ServiceManager {
  late IMicRecorderService _mic;
  late IDeviceService _device;
  late ISocketService _socket;
  late IWalService _wal;
  late SoundcoreSyncService _soundcoreSync;
  late A1SyncService _a1Sync;
  late PlaudSyncService _plaudSync;
  late RingSyncService _ringSync;

  static ServiceManager? _instance;

  static ServiceManager _create() {
    ServiceManager sm = ServiceManager();
    sm._mic = MicRecorderBackgroundService(
      runner: BackgroundService(),
    );
    sm._device = DeviceService();
    sm._soundcoreSync = SoundcoreSyncService(devices: sm._device);
    sm._a1Sync = A1SyncService(devices: sm._device);
    sm._plaudSync = PlaudSyncService(devices: sm._device);
    sm._ringSync = RingSyncService(devices: sm._device);
    sm._socket = SocketServicePool();
    sm._wal = WalService();

    return sm;
  }

  static ServiceManager instance() {
    if (_instance == null) {
      throw Exception("Service manager is not initiated");
    }

    return _instance!;
  }

  IMicRecorderService get mic => _mic;

  IDeviceService get device => _device;

  ISocketService get socket => _socket;

  IWalService get wal => _wal;
  SoundcoreSyncService get soundcoreSync => _soundcoreSync;
  A1SyncService get a1Sync => _a1Sync;
  PlaudSyncService get plaudSync => _plaudSync;
  RingSyncService get ringSync => _ringSync;

  static void init() {
    if (_instance != null) {
      throw Exception("Service manager is initiated");
    }
    _instance = ServiceManager._create();
  }

  Future<void> start() async {
    _device.start();
    _soundcoreSync.start(authChanges: FirebaseAuth.instance.authStateChanges());
    _a1Sync.start(authChanges: FirebaseAuth.instance.authStateChanges());
    _plaudSync.start(authChanges: FirebaseAuth.instance.authStateChanges());
    _ringSync.start(authChanges: FirebaseAuth.instance.authStateChanges());
    _wal.start();
  }

  void deinit() async {
    _soundcoreSync.stop();
    _a1Sync.stop();
    _plaudSync.stop();
    _ringSync.stop();
    await _wal.stop();
    _mic.stop();
    _device.stop();
  }
}

enum BackgroundServiceStatus {
  initiated,
  running,
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  return true;
}

@pragma('vm:entry-point')
Future onStart(ServiceInstance service) async {
  // Recorder
  MicRecorderService? recorder;
  service.on('recorder.start').listen((event) async {
    recorder = MicRecorderService(isInBG: Platform.isAndroid ? true : false);
    try {
      await recorder?.start(onByteReceived: (bytes) {
        Uint8List audioBytes = bytes;
        List<dynamic> audioBytesList = audioBytes.toList();
        service.invoke("recorder.ui.audioBytes", {"data": audioBytesList});
      }, onStop: () {
        service.invoke("recorder.ui.stateUpdate", {"state": 'stopped'});
      }, onRecording: () {
        service.invoke("recorder.ui.stateUpdate", {"state": 'recording'});
      }, onInitializing: () {
        service.invoke("recorder.ui.stateUpdate", {"state": 'initializing'});
      });
    } catch (error) {
      debugPrint('Microphone startup failed: $error');
      service.invoke("recorder.ui.stateUpdate", {"state": 'stopped'});
    }
  });

  service.on('recorder.stop').listen((event) async {
    service.invoke("recorder.ui.stateUpdate", {"state": 'stopped'});
    recorder?.stop();
  });

  service.on('stop').listen((event) async {
    if (recorder?.status != RecorderServiceStatus.stop) {
      recorder?.stop();
    }
    service.invoke("recorder.ui.stateUpdate", {"state": 'stopped'});
    service.stopSelf();
  });

  // watchdog
  var pongAt = DateTime.now();
  service.on('pong').listen((event) async {
    pongAt = DateTime.now();
  });
  Timer.periodic(const Duration(seconds: 5), (timer) async {
    if (pongAt.isBefore(DateTime.now().subtract(const Duration(seconds: 15)))) {
      // retire
      if (recorder?.status != RecorderServiceStatus.stop) {
        recorder?.stop();
      }
      service.invoke("recorder.ui.stateUpdate", {"state": 'stopped'});
      service.stopSelf();
      return;
    }
    service.invoke("ui.ping");
  });
}

class BackgroundService {
  late FlutterBackgroundService _service;
  BackgroundServiceStatus? _status;

  BackgroundServiceStatus? get status => _status;

  Future<void> init() async {
    _service = FlutterBackgroundService();
    _status = BackgroundServiceStatus.initiated;

    await _service.configure(
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
      androidConfiguration: AndroidConfiguration(
        autoStart: false,
        onStart: onStart,
        isForegroundMode: true,
        autoStartOnBoot: false,
        foregroundServiceTypes: [AndroidForegroundType.microphone],
      ),
    );

    _status = BackgroundServiceStatus.initiated;
  }

  Future<void> ensureRunning() async {
    await init();
    await start();
  }

  Future<void> start() async {
    _service.startService();

    // status
    if (await _service.isRunning()) {
      _status = BackgroundServiceStatus.running;
    }

    // heartbeat
    _service.on('ui.ping').listen((event) {
      _service.invoke("pong");
    });
  }

  void stop() {
    debugPrint("invoke stop");
    _service.invoke("stop");
  }

  void onStop(ServiceInstance instance) async {
    _service.invoke("recorder.stateUpdate", {"state": 'stopped'});
    instance.stopSelf();
  }

  void startRecorder({
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
  }) {
    StreamSubscription? recordAudioByteStream = _service.on('recorder.ui.audioBytes').listen((event) {
      Uint8List bytes = Uint8List.fromList(event!['data'].cast<int>());
      onByteReceived(bytes);
    });
    StreamSubscription? recordStateStream;
    recordStateStream = _service.on('recorder.ui.stateUpdate').listen((event) {
      if (event!['state'] == 'recording') {
        if (onRecording != null) {
          onRecording();
        }
      } else if (event['state'] == 'initializing') {
        if (onInitializing != null) {
          onInitializing();
        }
      } else if (event['state'] == 'stopped') {
        // Close streams
        recordAudioByteStream.cancel();
        recordStateStream?.cancel();

        // Callback
        if (onStop != null) {
          onStop();
        }
      }
    });

    // tell service > start record
    _service.invoke("recorder.start");
  }

  void stopRecorder() {
    if (_status == null) {
      // Service not initialized, nothing to stop
      return;
    }
    _service.invoke("recorder.stop");
  }
}

enum RecorderServiceStatus {
  initialising,
  recording,
  stop,
}

abstract class IMicRecorderService {
  Future<void> start({
    bool Function()? shouldStart,
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
  });
  void stop();
}

class MicRecorderBackgroundService implements IMicRecorderService {
  late BackgroundService _runner;

  MicRecorderBackgroundService({required BackgroundService runner}) {
    _runner = runner;
  }

  @override
  Future<void> start({
    bool Function()? shouldStart,
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
  }) async {
    await _runner.ensureRunning();
    if (shouldStart != null && !shouldStart()) throw StateError('Microphone start cancelled');

    _runner.startRecorder(
      onByteReceived: onByteReceived,
      onRecording: onRecording,
      onStop: onStop,
      onInitializing: onInitializing,
    );

    return;
  }

  @override
  void stop() {
    _runner.stopRecorder();
  }
}

class MicRecorderService implements IMicRecorderService {
  RecorderServiceStatus? _status;

  late FlutterSoundRecorder _recorder;
  StreamController<Uint8List>? _controller;

  Function(Uint8List bytes)? _onByteReceived;
  Function? _onRecording;
  Function? _onStop;

  bool _isInBG = false;

  MicRecorderService({bool isInBG = false}) {
    _recorder = FlutterSoundRecorder();
    _isInBG = isInBG;
  }

  @visibleForTesting
  MicRecorderService.forTesting(FlutterSoundRecorder recorder) : _recorder = recorder;

  get status => _status;

  @override
  Future<void> start({
    bool Function()? shouldStart,
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
  }) async {
    if (_status == RecorderServiceStatus.recording) {
      throw Exception("Recorder is recording, please stop it before start new recording.");
    }
    if (_status == RecorderServiceStatus.initialising) {
      throw Exception("Recorder is initialising");
    }

    _status = RecorderServiceStatus.initialising;

    // callback
    _onByteReceived = onByteReceived;
    _onStop = onStop;
    _onRecording = onRecording;
    onInitializing?.call();

    // new record
    try {
      await _recorder.openRecorder(isBGService: _isInBG);
      if (_status != RecorderServiceStatus.initialising || (shouldStart != null && !shouldStart())) {
        throw StateError('Microphone start cancelled');
      }
      _controller = StreamController<Uint8List>();

      await _recorder.startRecorder(
        toStream: _controller!.sink,
        codec: Codec.pcm16,
        numChannels: 1,
        sampleRate: 16000,
        bufferSize: 8192,
      );
      if (_status != RecorderServiceStatus.initialising || (shouldStart != null && !shouldStart())) {
        await _recorder.stopRecorder();
        throw StateError('Microphone start cancelled');
      }
      _controller!.stream.listen((buffer) {
        Uint8List audioBytes = buffer;
        if (_onByteReceived != null) {
          _onByteReceived!(audioBytes);
        }
      });

      _status = RecorderServiceStatus.recording;
      _onRecording?.call();
    } catch (_) {
      _controller?.close();
      _controller = null;
      _status = RecorderServiceStatus.stop;
      rethrow;
    }
    return;
  }

  @override
  void stop() {
    _recorder.stopRecorder();
    _controller?.close();
    _controller = null;

    // callback
    _status = RecorderServiceStatus.stop;
    if (_onStop != null) {
      _onStop!();
    }

    _onByteReceived = null;
    _onStop = null;
    _onRecording = null;
  }
}
