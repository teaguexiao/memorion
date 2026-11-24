import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:memorion/backend/http/api/speech_profile.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/message_event.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/services/sockets/transcription_connection.dart';
import 'package:memorion/utils/audio/wav_bytes.dart';
import 'package:memorion/utils/localization_helper.dart';

class SpeechProfileProvider extends ChangeNotifier
    with MessageNotifierMixin
    implements IDeviceServiceSubsciption, ITransctipSegmentSocketServiceListener {
  DeviceProvider? deviceProvider;
  bool? permissionEnabled;
  bool loading = false;
  BtDevice? device;

  final targetWordsCount = 70;
  final maxDuration = 150;

  /// Calculate word count with multi-language support (Chinese, Japanese, Korean, etc.)
  /// For CJK languages that don't use spaces, each character is counted.
  /// For space-separated languages, words are counted by splitting on spaces.
  /// Mixed content uses a weighted calculation.
  int getWordCount(String text) {
    text = text.trim();
    if (text.isEmpty) return 0;

    // Count CJK characters (Chinese, Japanese Kanji, Korean Hanja)
    // Chinese: U+4E00 - U+9FFF (CJK Unified Ideographs)
    // Japanese Hiragana: U+3040 - U+309F
    // Japanese Katakana: U+30A0 - U+30FF
    // Korean Hangul: U+AC00 - U+D7AF
    int cjkCharCount = 0;
    StringBuffer nonCjkBuffer = StringBuffer();

    for (int rune in text.runes) {
      bool isCjk = (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK Unified Ideographs
          (rune >= 0x3040 && rune <= 0x309F) || // Hiragana
          (rune >= 0x30A0 && rune <= 0x30FF) || // Katakana
          (rune >= 0xAC00 && rune <= 0xD7AF); // Korean Hangul

      if (isCjk) {
        cjkCharCount++;
      } else {
        nonCjkBuffer.writeCharCode(rune);
      }
    }

    // Count space-separated words from non-CJK text
    String nonCjkText = nonCjkBuffer.toString().trim();
    int spaceWordCount = nonCjkText.isEmpty
        ? 0
        : nonCjkText.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length;

    // For CJK characters: roughly 2 CJK characters ≈ 1 English word in speaking time
    // This provides a balanced progress calculation for mixed language content
    int cjkWordEquivalent = (cjkCharCount / 2).ceil();

    return cjkWordEquivalent + spaceWordCount;
  }

  StreamSubscription<OnConnectionStateChangedEvent>? connectionStateListener;
  List<TranscriptSegment> segments = [];
  double? streamStartedAtSecond;
  late WavBytesUtil audioStorage;
  StreamSubscription? _bleBytesStream;

  TranscriptSegmentSocketService? _socket;

  bool startedRecording = false;

  // Phone microphone mode (when no device connected)
  bool _usePhoneMic = false;
  bool get usePhoneMic => _usePhoneMic;
  double percentageCompleted = 0;
  bool uploadingProfile = false;
  bool profileCompleted = false;
  Timer? forceCompletionTimer;

  bool isInitialising = false;
  bool isInitialised = false;

  String text = '';
  String message = '';

  late Function? _finalizedCallback;

  /// only used during onboarding /////
  String loadingText = 'Uploading your voice profile....';
  ServerConversation? conversation;

  /////////////////////////////////

  void updateLoadingText(String text) {
    loadingText = text;
    notifyListeners();
  }

  void setInitialising(bool value) {
    isInitialising = value;
    notifyListeners();
  }

  void setInitialised(bool value) {
    isInitialised = value;
    notifyListeners();
  }

  void setProviders(DeviceProvider provider) {
    deviceProvider = provider;
    notifyListeners();
  }

  Future<void> updateDevice() async {
    if (device == null) {
      await deviceProvider?.scanAndConnectToDevice();
      device = deviceProvider?.connectedDevice;
    }
    notifyListeners();
  }

  Future<void> initialise({Function? finalizedCallback, bool forcePhoneMic = false}) async {
    _finalizedCallback = finalizedCallback;
    setInitialising(true);
    device = deviceProvider?.connectedDevice;

    // Decide whether to use phone microphone or device
    _usePhoneMic = forcePhoneMic || device == null;

    BleAudioCodec codec;
    if (_usePhoneMic) {
      // Phone microphone uses PCM16 at 16kHz
      codec = BleAudioCodec.pcm16;
      audioStorage = WavBytesUtil(codec: codec, framesPerSecond: 100); // 16000 / 160 = 100 frames/sec
    } else {
      codec = await _getAudioCodec(device!.id);
      audioStorage = WavBytesUtil(codec: codec, framesPerSecond: codec.getFramesPerSecond());
    }

    await _initiateWebsocket(codec: codec, force: true);

    if (_usePhoneMic) {
      await _initiatePhoneMicStreaming();
    } else {
      await initiateDeviceAudioStreaming();
    }

    if (_socket?.state != SocketServiceState.connected) {
      // wait for websocket to connect
      await Future.delayed(const Duration(seconds: 2));
    }

    setInitialising(false);
    setInitialised(true);
    // initiateConnectionListener();
    notifyListeners();
  }

  /// Start streaming audio from phone microphone
  Future<void> _initiatePhoneMicStreaming() async {
    await ServiceManager.instance().mic.start(
      onByteReceived: (bytes) {
        if (bytes.isEmpty) return;
        // Phone mic produces raw PCM16 bytes without BLE packet headers
        audioStorage.storeRawPcmBytes(bytes.toList());

        if (_socket?.state == SocketServiceState.connected) {
          _socket?.send(bytes.toList());
        }
      },
    );
  }

  void updateStartedRecording(bool value) {
    startedRecording = value;
    notifyListeners();
  }

  changeLoadingState(bool value) {
    loading = value;
    notifyListeners();
  }

  initiateConnectionListener() async {
    if (device == null || connectionStateListener != null) return;
    ServiceManager.instance().device.subscribe(this, this);
  }

  Future<void> _initiateWebsocket({required BleAudioCodec codec, bool force = false}) async {
    // Phone microphone always uses 16kHz, device codec determines sample rate
    int sampleRate;
    if (_usePhoneMic) {
      sampleRate = 16000; // Phone mic records at 16kHz
    } else {
      sampleRate = (codec.isOpusSupported() ? 16000 : 8000);
    }
    _socket = await ServiceManager.instance()
        .socket
        .speechProfile(codec: codec, sampleRate: sampleRate, language: "auto", force: force);
    if (_socket == null) {
      throw Exception("Can not create new speech profile socket");
    }
    _socket?.subscribe(this, this);
  }

  _handleCompletion() async {
    if (uploadingProfile || profileCompleted) return;
    String text = segments.map((e) => e.text).join(' ').trim();
    int wordsCount = getWordCount(text);
    percentageCompleted = (wordsCount / targetWordsCount).clamp(0, 1);
    notifyListeners();
    if (percentageCompleted == 1) {
      await finalize();
    }
    notifyListeners();
  }

  Future finalize() async {
    try {
      if (uploadingProfile || profileCompleted) return;

      int duration = segments.isEmpty ? 0 : segments.last.end.toInt();
      if (duration < 10 || duration > 155) {
        if (percentageCompleted < 80) {
          notifyError('NO_SPEECH');
          return;
        }
      }

      String text = segments.map((e) => e.text).join(' ').trim();
      if (getWordCount(text) < (targetWordsCount / 2)) {
        // 35 words (or equivalent for CJK languages)
        notifyError('TOO_SHORT');
        return;
      }
      uploadingProfile = true;
      notifyListeners();
      await _socket?.stop(reason: 'finalizing');
      forceCompletionTimer?.cancel();
      connectionStateListener?.cancel();
      _bleBytesStream?.cancel();

      // Stop phone microphone if it was being used
      if (_usePhoneMic) {
        ServiceManager.instance().mic.stop();
      }

      updateLoadingText(appT((s) => s.speechProfileMemorizing, 'Memorizing your voice...'));
      var data = await audioStorage.createWavFile(filename: 'speaker_profile.wav');
      try {
        await uploadProfile(data.item1);
      } catch (e) {}

      updateLoadingText(appT((s) => s.speechProfilePersonalizing, 'Personalizing your experience...'));
      SharedPreferencesUtil().hasSpeakerProfile = true;
      // if (_isFromOnboarding) {
      //   await createMemory();
      // }
      uploadingProfile = false;
      profileCompleted = true;
      text = '';
      updateLoadingText(appT((s) => s.speechProfileAllSet, "You're all set!"));
      notifyListeners();
    } finally {
      if (_finalizedCallback != null) {
        _finalizedCallback!();
      }
    }
  }

  // TODO: use connection directly
  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return BleAudioCodec.pcm8;
    }
    return connection.getAudioCodec();
  }

  Future<StreamSubscription?> _getBleAudioBytesListener(
    String deviceId, {
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleAudioBytesListener(onAudioBytesReceived: onAudioBytesReceived);
  }

  Future<void> initiateDeviceAudioStreaming() async {
    _bleBytesStream = await _getBleAudioBytesListener(
      device!.id,
      onAudioBytesReceived: (List<int> value) {
        if (value.isEmpty) return;
        audioStorage.storeFramePacket(value);

        value.removeRange(0, 3);
        if (_socket?.state == SocketServiceState.connected) {
          _socket?.send(value);
        }
      },
    );
  }

  _validateSingleSpeaker() {
    int speakersCount = segments.map((e) => e.speaker).toSet().length;
    debugPrint('_validateSingleSpeaker speakers count: $speakersCount');
    if (speakersCount > 1) {
      var speakerToWords = segments.fold<Map<int, int>>(
        {},
        (previousValue, element) {
          previousValue[element.speakerId] = (previousValue[element.speakerId] ?? 0) + getWordCount(element.text);
          return previousValue;
        },
      );
      debugPrint('speakerToWords: $speakerToWords');
      if (speakerToWords.values.every((element) => element / segments.length > 0.08)) {
        notifyError('MULTIPLE_SPEAKERS');
      }
    }
  }

  void resetSegments() {
    segments.clear();
    streamStartedAtSecond = null;
    audioStorage.clearAudioBytes();
    text = '';
    percentageCompleted = 0;
    notifyListeners();
  }

  Future setupSpeechRecording() async {
    final permission = await getStoreRecordingPermission();
    permissionEnabled = permission;
    if (permission != null) {
      SharedPreferencesUtil().permissionStoreRecordingsEnabled = permission;
    }
    notifyListeners();
  }

  void updateProgressMessage() {
    text = segments.map((e) => e.text).join(' ').trim();
    int wordsCount = getWordCount(text);
    message = appT((s) => s.speechProfileKeepSpeaking, 'Keep speaking until you get 100%.');
    if (wordsCount > 40) {
      message = appT((s) => s.speechProfileSoClose, 'So close, just a little more');
    } else if (wordsCount > 25) {
      message = appT((s) => s.speechProfileGreatJob, 'Great job, you are almost there');
    } else if (wordsCount > 10) {
      message = appT((s) => s.speechProfileKeepGoing, 'Keep going, you are doing great');
    }
    notifyListeners();
  }

  Future close() async {
    connectionStateListener?.cancel();
    // ⚠️ **这里刻意只 cancel 自己这个订阅对象，不去动 `bleAudioSubscriptions`**
    // （`services/devices/live_subscription_registry.dart`）。声纹录制和主录音共用同一个
    // key（BLE remoteId），而 `finalize()` 的完成回调 `_restartDeviceRecording` 已经让
    // CaptureProvider 重新订阅了 —— 此刻按 key 去 registry 里 cancel，杀掉的是**主录音刚
    // 建好的那个**订阅，症状是「录完声纹之后就再也不出转录了」。
    // 重复 cancel 一个已经被 registry 顶掉的订阅是无害的 no-op，所以这样就够了。
    _bleBytesStream?.cancel();
    forceCompletionTimer?.cancel();

    // Stop phone microphone if it was being used
    if (_usePhoneMic) {
      ServiceManager.instance().mic.stop();
      _usePhoneMic = false;
    }

    segments.clear();
    text = '';
    startedRecording = false;
    percentageCompleted = 0;
    uploadingProfile = false;
    profileCompleted = false;
    await _socket?.stop(reason: 'closing');
    notifyListeners();
  }

  @override
  void dispose() {
    // This won't be called unless the provider is removed from the widget tree. So we need to manually call this in the widget's dispose method.
    connectionStateListener?.cancel();
    _bleBytesStream?.cancel();
    forceCompletionTimer?.cancel();
    _finalizedCallback = null;
    _socket?.unsubscribe(this);
    ServiceManager.instance().device.unsubscribe(this);

    super.dispose();
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) async {
    switch (state) {
      case DeviceConnectionState.connected:
        var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
        if (connection == null) {
          return;
        }
        device = connection.device;
        notifyListeners();
        initiateDeviceAudioStreaming();
        break;
      case DeviceConnectionState.disconnected:
        if (deviceId == device?.id) {
          device = null;
          notifyListeners();
        }
      default:
        debugPrint("Device connection state is not supported $state");
    }
  }

  @override
  void onDevices(List<BtDevice> devices) {}

  @override
  void onStatusChanged(DeviceServiceStatus status) {}

  @override
  void onClosed([int? closeCode]) {
    // TODO: implement onClosed
  }

  @override
  void onError(Object err) {
    notifyError('WS_ERR');
  }

  @override
  void onMessageEventReceived(MessageEvent event) {
    // TODO: implement onMessageEventReceived
  }

  @override
  void onSegmentReceived(List<TranscriptSegment> newSegments) {
    if (newSegments.isEmpty) return;
    if (segments.isEmpty) {
      audioStorage.removeFramesRange(fromSecond: 0, toSecond: newSegments[0].start.toInt());
    }
    streamStartedAtSecond ??= newSegments[0].start;

    var remainSegments = TranscriptSegment.updateSegments(segments, newSegments);
    TranscriptSegment.combineSegments(
      segments,
      remainSegments,
      toRemoveSeconds: streamStartedAtSecond ?? 0,
    );
    updateProgressMessage();
    _validateSingleSpeaker();
    _handleCompletion();
    notifyInfo('SCROLL_DOWN');
    debugPrint('Conversation creation timer restarted');
  }

  @override
  void onConnected() {}
}
