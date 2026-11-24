import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/http/api/audio_upload.dart';
import 'package:memorion/backend/http/api/images_api.dart';
import 'package:memorion/backend/http/api/speech_profile.dart' show identifyConversationSpeakers;
import 'package:memorion/services/local_audio_buffer.dart';
import 'package:memorion/services/local_audio_storage.dart';
import 'package:memorion/services/local_image_storage.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/main.dart';
import 'package:memorion/widgets/dialog.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/backend/schema/message_event.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/models/subscription.dart';
import 'package:memorion/providers/chat_session_provider.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/message_provider.dart';
import 'package:memorion/providers/people_provider.dart';
import 'package:memorion/providers/usage_provider.dart';
import 'package:memorion/services/press_to_talk_service.dart';
import 'package:memorion/services/ptt_keepalive_service.dart';
import 'package:memorion/services/audio_input_device_service.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/live_subscription_registry.dart';
import 'package:memorion/services/notifications.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/services/sockets/pure_socket.dart';
import 'package:memorion/services/sockets/sdcard_socket.dart';
import 'package:memorion/services/sockets/transcription_connection.dart';
import 'package:memorion/services/wals.dart';
import 'package:memorion/utils/alerts/app_snackbar.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:memorion/utils/enums.dart';
import 'package:memorion/utils/localization_helper.dart';
import 'package:memorion/utils/logger.dart';
import 'package:memorion/utils/notification_prefs.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:memorion/services/sockets/usage_limit_exception.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class CaptureProvider extends ChangeNotifier
    with MessageNotifierMixin, WidgetsBindingObserver
    implements ITransctipSegmentSocketServiceListener {
  ConversationProvider? conversationProvider;
  MessageProvider? messageProvider;
  PeopleProvider? peopleProvider;
  UsageProvider? usageProvider;
  PressToTalkService? pttService;
  ChatSessionProvider? chatSessionProvider;

  TranscriptSegmentSocketService? _socket;
  SdCardSocketService sdCardSocket = SdCardSocketService();
  Timer? _keepAliveTimer;
  int _keepAliveBackoffSeconds = 15;
  Timer? _bleHeartbeatTimer;
  int _bleHeartbeatFailCount = 0;

  IWalService get _wal => ServiceManager.instance().wal;

  IDeviceService get _deviceService => ServiceManager.instance().device;
  bool _isWalSupported = false;

  bool get isWalSupported => _isWalSupported;

  StreamSubscription<InternetStatus>? _internetStatusListener;
  InternetStatus? _internetStatus;

  get internetStatus => _internetStatus;

  DateTime? _lastUsageLimitDialogShown;
  bool get outOfCredits => usageProvider?.isOutOfCredits ?? false;

  List<MessageEvent> _transcriptionServiceStatuses = [];
  List<MessageEvent> get transcriptionServiceStatuses => _transcriptionServiceStatuses;

  CaptureProvider() {
    _internetStatusListener = PureCore().internetConnection.onStatusChange.listen((InternetStatus status) {
      onInternetSatusChanged(status);
    });

    // Load saved recording mode preference
    final savedMode = SharedPreferencesUtil().defaultRecordingMode;
    _recordingMode = savedMode == 'fileUpload' ? RecordingMode.fileUpload : RecordingMode.realtime;
    debugPrint('CaptureProvider: Loaded recording mode from preferences: $_recordingMode');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _handleAppResumed();
    }
  }

  void _handleAppResumed() async {
    // App 恢复前台时，补传之前失败的图片
    unawaited(_retryPendingImageUploads());
  }

  /// Get language for transcription with defensive checks.
  /// If local cache is inconsistent (hasSet=true but language empty), try to recover from backend.
  Future<String> _getLanguageForTranscription() async {
    final hasSet = SharedPreferencesUtil().hasSetPrimaryLanguage;
    final localLanguage = SharedPreferencesUtil().userPrimaryLanguage;

    // Case 1: Valid local cache
    if (hasSet && localLanguage.isNotEmpty) {
      return localLanguage;
    }

    // Case 2: Local cache missing or never set — try backend recovery first
    // This handles the scenario where TestFlight updates clear SharedPreferences
    debugPrint('[CaptureProvider] Local language cache empty (hasSet=$hasSet), attempting backend recovery...');
    try {
      final backendLanguage = await getUserPrimaryLanguage();
      if (backendLanguage != null && backendLanguage.isNotEmpty) {
        debugPrint('[CaptureProvider] Recovered language from backend: $backendLanguage');
        SharedPreferencesUtil().userPrimaryLanguage = backendLanguage;
        SharedPreferencesUtil().hasSetPrimaryLanguage = true;
        return backendLanguage;
      }
    } catch (e) {
      debugPrint('[CaptureProvider] Backend language recovery failed: $e');
    }

    // Fallback: no language available from backend either
    debugPrint('[CaptureProvider] No language available, using "multi"');
    if (hasSet) {
      // Reset inconsistent state
      SharedPreferencesUtil().hasSetPrimaryLanguage = false;
    }
    return "multi";
  }

  void updateProviderInstances(ConversationProvider? cp, MessageProvider? mp, PeopleProvider? pp, UsageProvider? up,
      {PressToTalkService? pttService, ChatSessionProvider? chatSession}) {
    conversationProvider = cp;
    messageProvider = mp;
    peopleProvider = pp;
    usageProvider = up;
    if (pttService != null) this.pttService = pttService;
    if (chatSession != null) chatSessionProvider = chatSession;

    notifyListeners();
  }

  BtDevice? _recordingDevice;
  ServerConversation? _conversation;
  List<TranscriptSegment> segments = [];
  List<ConversationPhoto> photos = [];
  Map<String, SpeakerLabelSuggestionEvent> suggestionsBySegmentId = {};
  List<String> taggingSegmentIds = [];

  // Track if persisted photos have been loaded
  bool _isPersistedPhotosInitialized = false;

  // 云端图片上传失败重试队列: {tempId: base64Data}
  final Map<String, String> _pendingImageUploads = {};

  bool hasTranscripts = false;

  // Voice trigger for photo capture
  DateTime? _lastVoicePhotoTrigger;
  static const Duration _voicePhotoTriggerCooldown = Duration(seconds: 5);
  static const List<String> _photoTriggerKeywords = [
    'take photo',
    'take a photo',
    'take picture',
    'take a picture',
    'what is this',
    'what\'s this',
    'help me see',
    'help me look',
    'look at this',
    'check this out',
    'let me see',
    'show me',
    'capture this',
    'capture photo',
    '拍照',
    '拍个照',
    '拍张照',
    '这是什么',
    '帮我看看',
    '帮我看一下',
    '看一下这个',
    '看看这个',
  ];

  StreamSubscription? _bleBytesStream;
  StreamSubscription? _blePhotoStream;

  get bleBytesStream => _bleBytesStream;

  StreamSubscription? _bleButtonStream;
  DateTime? _voiceCommandSession;

  StreamSubscription? _storageStream;

  get storageStream => _storageStream;

  RecordingState recordingState = RecordingState.stop;
  bool phoneRecordingShortcutStarting = false;
  Future<bool>? _deviceRecordingStartup;
  bool _deviceRecordingDeferred = false;
  bool get isDeviceRecordingStarting => _deviceRecordingStartup != null;

  bool get _phoneOwnsAudio => phoneRecordingShortcutStarting || recordingState == RecordingState.record;

  bool _isPaused = false;
  bool get isPaused => _isPaused;

  // Time offset for segment timestamps after pause/resume
  // When mic pauses, STT resets its clock to 0 on resume.
  // We track the max timestamp so we can offset new segments.
  double _segmentTimeOffset = 0.0;
  double _maxSegmentEnd = 0.0;

  // Independent photo capture state (separate from audio recording)
  bool _isPhotoCaptureActive = false;
  bool get isPhotoCaptureActive => _isPhotoCaptureActive;

  bool _transcriptServiceReady = false;

  // Recording mode: realtime (WebSocket) or fileUpload (local buffer + upload)
  RecordingMode _recordingMode = RecordingMode.realtime;
  RecordingMode get recordingMode => _recordingMode;

  // Whether on-device STT is active for the current session
  bool _isOnDeviceStt = false;
  bool get isOnDeviceStt => _isOnDeviceStt;

  // Local audio buffer for file upload mode
  LocalAudioBuffer? _localAudioBuffer;
  LocalAudioBuffer? get localAudioBuffer => _localAudioBuffer;

  // Current audio codec and sample rate (for file upload mode buffer initialization)
  BleAudioCodec? _currentAudioCodec;
  int _currentSampleRate = 16000;

  // Track if file upload is in progress
  bool _isUploadingAudio = false;
  bool get isUploadingAudio => _isUploadingAudio;

  // ---- 本次录音已经录了多久（实时采集页计时）----
  //
  // 计时必须从录音状态机维护的真实会话起点开始，不能从页面打开时才开始数：
  // 用户进入实时采集页时录音可能已经持续很久。`updateRecordingState` 无论前后台都会
  // 被调用，所以真正的会话起点只有这里知道。
  //
  // 暂停要扣掉：`_pausedTotal` 是已结束的暂停段之和，`_pausedSince` 是当前那段。
  DateTime? _sessionStartedAt;
  Duration _pausedTotal = Duration.zero;
  DateTime? _pausedSince;

  /// 本次录音的净录制时长（已扣掉暂停）。没在录音时为 null。
  Duration? get recordedDuration {
    final started = _sessionStartedAt;
    if (started == null) return null;
    final pausedNow = _pausedSince == null ? Duration.zero : DateTime.now().difference(_pausedSince!);
    final net = DateTime.now().difference(started) - _pausedTotal - pausedNow;
    return net.isNegative ? Duration.zero : net;
  }

  /// 由 [updateRecordingState] 在**每一次**状态变更时调用，维护上面三个字段。
  ///
  /// ⚠️ `initialising` 刻意算作「已经开始」：它紧接着就会变成 record，而它到 record
  /// 之间要请权限、连 socket，可能有好几秒。把它算成未开始会让计时器从负数补起。
  void _trackSessionClock(RecordingState state) {
    switch (state) {
      case RecordingState.stop:
      case RecordingState.error:
        _sessionStartedAt = null;
        _pausedTotal = Duration.zero;
        _pausedSince = null;
      case RecordingState.pause:
        _sessionStartedAt ??= DateTime.now();
        _pausedSince ??= DateTime.now();
      case RecordingState.initialising:
      case RecordingState.record:
      case RecordingState.deviceRecord:
        _sessionStartedAt ??= DateTime.now();
        final since = _pausedSince;
        if (since != null) {
          _pausedTotal += DateTime.now().difference(since);
          _pausedSince = null;
        }
    }
  }

  // Segment-based timeout for realtime mode (matches backend CONVERSATION_CREATION_TIMEOUT)
  // When no new segments arrive for this duration, auto-end the conversation.
  static const int _segmentTimeoutSeconds = 120;
  DateTime? _lastSegmentReceivedTime;
  Timer? _segmentTimeoutTimer;

  // 防止同一次录音的会话被重复提交到 POST /v1/conversations/process。
  // segment-timeout / socket-close / UI 手动三条触发路径都汇聚到
  // forceProcessingCurrentConversation()，在那唯一的汇聚点上拦。
  //
  // ⚠️ 治本在后端（按 session 加 Redis 分布式锁），这里只省掉一次注定被锁挡回来
  // 的 POST。收益既然这么小，这个标志就绝不该比它防的问题更危险 —— 漏掉任何一条
  // 早退路径没复位，它会永久停在 true，之后**每一次**录音都在函数入口被静默丢掉，
  // 只能重启 App 才恢复。为什么曾经真漏过一条，见
  // forceProcessingCurrentConversation() 里那段注释。
  bool _isProcessingConversation = false;

  // Silence detection for auto-upload in file upload mode
  DateTime? _lastSpeechDetectedTime;
  Timer? _silenceCheckTimer;
  bool _isSilenceDetectionActive = false;
  static const double _silenceThreshold = 500.0; // RMS threshold for speech detection

  // Silence countdown for UI display
  int _silenceCountdownSeconds = 0;
  int get silenceCountdownSeconds => _silenceCountdownSeconds;
  bool get isSilenceCountdownActive => _isSilenceDetectionActive && _silenceCountdownSeconds > 0;

  // Audio level tracking for waveform visualization
  final List<double> _audioLevels = List.generate(8, (_) => 0.15);
  List<double> get audioLevels => List.from(_audioLevels);

  /// Normalized audio level 0.0-1.0 for BreathingLight widget.
  /// Derived from the latest RMS audio level.
  double get currentAudioLevel => ((_audioLevels.last - 0.15) / (1.6 - 0.15)).clamp(0.0, 1.0);

  void _processAudioBytesForVisualization(List<int> bytes) {
    if (bytes.isEmpty) return;

    double rms = 0;

    // Process bytes as 16-bit samples (2 bytes per sample)
    for (int i = 0; i < bytes.length - 1; i += 2) {
      // Convert two bytes to a 16-bit signed integer
      int sample = bytes[i] | (bytes[i + 1] << 8);

      // Convert to signed value (if high bit is set)
      if (sample > 32767) {
        sample = sample - 65536;
      }

      // Square the sample and add to sum
      rms += sample * sample;
    }

    // Calculate RMS and normalize to 0.0-1.0 range
    int sampleCount = bytes.length ~/ 2;
    if (sampleCount > 0) {
      rms = math.sqrt(rms / sampleCount) / 32768.0;
    } else {
      rms = 0;
    }

    // Apply non-linear scaling for better dynamic range - quieter on silence, same on noise
    final level = (math.pow(rms, 0.3).toDouble() * 2.1).clamp(0.15, 1.6);

    // Shift all values left and add new level
    for (int i = 0; i < _audioLevels.length - 1; i++) {
      _audioLevels[i] = _audioLevels[i + 1];
    }
    _audioLevels[_audioLevels.length - 1] = level;

    notifyListeners(); // Notify UI to update waveform
  }

  /// Start segment-based timeout for realtime mode.
  /// Auto-ends the conversation when no new segments arrive for 120 seconds.
  ///
  /// 🚨 **有录音设备时刻意不启动**（2026-08-22 修）。这条客户端定时器与后端的静音切分
  /// 完全重复，而两者的副作用差了一个数量级：后端
  /// `developer_listen.py:1108 _flush_conversation()` 一样等 120s，但它只把当前 batch
  /// 交给 `_auto_process_conversation` 然后清空缓冲，**WebSocket 和 session 都继续跑**
  /// （那边注释写明这条路径「is SUPPOSED to fire repeatedly」——长录音就该被静音切成
  /// 多条对话）。客户端这条走的是 [forceProcessingCurrentConversation]，它第一件事就是
  /// `_socket.stop()`。
  ///
  /// 于是 always-on 的 DevKit1 上表现成这样：设备连着、`recordingState` 一直停在
  /// `deviceRecord`（首页波纹照红），但每静音满 120s WS 就被自己关掉、`segments` 被
  /// `_resetStateVariables()` 清空，要等 `onClosed` → [_startKeepAliveServices] 的 15s
  /// （失败则指数退避到 120s）才重建一条新 session。用户点进实时页看到的是空的
  /// 「正在聆听」+ 00:00，看着就像进页面重开了一个会话——而页面根本没重启采集。
  ///
  /// ⚠️ 比显示问题严重的是那 15s 空窗：BLE 音频照旧往 `_socket?.send()` 灌，而
  /// `PureSocket.send` 在 `status != connected` 时是**静默丢弃**的（只有 `_droppedSends`
  /// 那行采样日志）。DevKit1 没有卡，实时流是音频的唯一副本 ⇒ 那段录音永久丢失。
  ///
  /// 判据用 [havingRecordingDevice] 而不是 `recordingState`：本函数由
  /// [_initiateWebsocket] 调用，而设备路径上置 `deviceRecord` 的
  /// `_initiateDeviceAudioStreaming()` 排在 `_ensureDeviceSocketConnection()` **之后**
  /// ——走到这里时状态还是上一个值，看 `recordingState` 会把整条设备路径漏掉。
  ///
  /// 副作用是「BLE 连着但用户拨了『这次用手机麦录』」也不再由客户端结束会话。这是刻意
  /// 的：那条路上手机麦的音频同样是唯一副本，关 WS 一样在丢数据，而后端照旧会切分。
  void _startSegmentTimeout() {
    _segmentTimeoutTimer?.cancel();
    if (havingRecordingDevice) {
      // 留一行日志：这条 gate 生效与否在 UI 上看不出来（两种情况下头 120 秒都一样），
      // 真机上就靠它和「不再出现 `[SegmentTimeout] No new segments`」一起确认。
      debugPrint('[SegmentTimeout] Skipped — device recording, backend owns conversation splitting');
      _lastSegmentReceivedTime = null;
      return;
    }
    _lastSegmentReceivedTime = DateTime.now();
    _segmentTimeoutTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_lastSegmentReceivedTime == null) return;
      final elapsed = DateTime.now().difference(_lastSegmentReceivedTime!).inSeconds;
      if (elapsed >= _segmentTimeoutSeconds && hasTranscripts) {
        debugPrint('[SegmentTimeout] No new segments for ${elapsed}s, auto-ending conversation');
        _segmentTimeoutTimer?.cancel();
        _segmentTimeoutTimer = null;
        forceProcessingCurrentConversation();
      }
    });
  }

  void _stopSegmentTimeout() {
    _segmentTimeoutTimer?.cancel();
    _segmentTimeoutTimer = null;
    _lastSegmentReceivedTime = null;
  }

  /// Start silence detection for file upload mode auto-upload
  void _startSilenceDetection() {
    if (_recordingMode != RecordingMode.fileUpload) return;

    debugPrint('CaptureProvider: Starting silence detection');
    _isSilenceDetectionActive = true;
    _lastSpeechDetectedTime = DateTime.now();
    _silenceCountdownSeconds = 0;

    // Start a timer to check silence duration every second
    _silenceCheckTimer?.cancel();
    _silenceCheckTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _checkSilenceAndAutoUpload();
    });
  }

  /// Stop silence detection
  void _stopSilenceDetection() {
    debugPrint('CaptureProvider: Stopping silence detection');
    _isSilenceDetectionActive = false;
    _silenceCheckTimer?.cancel();
    _silenceCheckTimer = null;
    _lastSpeechDetectedTime = null;
    _silenceCountdownSeconds = 0;
  }

  /// Process audio for silence detection (called from audio callbacks)
  void _processAudioForSilenceDetection(List<int> bytes) {
    if (!_isSilenceDetectionActive || bytes.isEmpty) return;

    // Calculate RMS energy of audio
    double rms = 0;
    int sampleCount = 0;

    for (int i = 0; i < bytes.length - 1; i += 2) {
      int sample = bytes[i] | (bytes[i + 1] << 8);
      if (sample > 32767) {
        sample = sample - 65536;
      }
      rms += sample * sample;
      sampleCount++;
    }

    if (sampleCount > 0) {
      rms = math.sqrt(rms / sampleCount);
    }

    // Check if speech is detected
    if (rms > _silenceThreshold) {
      _lastSpeechDetectedTime = DateTime.now();
      if (_silenceCountdownSeconds > 0) {
        _silenceCountdownSeconds = 0;
        notifyListeners();
      }
    }
  }

  /// Check silence duration and auto-upload if timeout reached
  void _checkSilenceAndAutoUpload() async {
    if (!_isSilenceDetectionActive || _lastSpeechDetectedTime == null) return;

    final silenceDuration = DateTime.now().difference(_lastSpeechDetectedTime!).inSeconds;
    final timeoutSeconds = SharedPreferencesUtil().autoUploadTimeoutSeconds;

    // Update countdown for UI
    final newCountdown = (timeoutSeconds - silenceDuration).clamp(0, timeoutSeconds);
    if (newCountdown != _silenceCountdownSeconds) {
      _silenceCountdownSeconds = newCountdown;
      notifyListeners();
    }

    // Check if we should auto-upload
    if (silenceDuration >= timeoutSeconds) {
      debugPrint('CaptureProvider: Silence timeout reached ($silenceDuration >= $timeoutSeconds), auto-uploading...');
      _stopSilenceDetection();

      // Check if we have audio to upload
      if (_localAudioBuffer != null && !_localAudioBuffer!.isEmpty) {
        // Stop any active recording first
        if (recordingState == RecordingState.record) {
          ServiceManager.instance().mic.stop();
          updateRecordingState(RecordingState.stop);
        }

        // Upload the audio
        await stopAndUploadRecording();
      }
    }
  }

  bool get transcriptServiceReady => _transcriptServiceReady && _internetStatus == InternetStatus.connected;

  // having a connected device or using the phone's mic for recording
  bool get recordingDeviceServiceReady => _recordingDevice != null || recordingState == RecordingState.record;

  bool get havingRecordingDevice => _recordingDevice != null;

  // 统一的“正在录音”信号：手动 mic 录音(record) 或 BLE 设备录音(deviceRecord)，且未暂停。
  bool get isRecording =>
      (recordingState == RecordingState.record || recordingState == RecordingState.deviceRecord) && !isPaused;

  /// 「本次录音会话已经开始」——用来把「首次建连」和「录音中途重连」分开。
  ///
  /// ⚠️ **刻意不用 [isRecording]**：那个带 `!isPaused`，而暂停时会话并没有结束（socket
  /// 还活着、`_socket` 也没换），用它做判据会让暂停期间的一次重连被当成首次建连去回填
  /// 服务端快照。这里要的是「recordingState 是否已经进入录音态」这个更弱的事实。
  ///
  /// 判据成立依赖置位顺序：两条路径都是先建 socket、后置录音态（见
  /// `_initiateWebsocket` 里回填守卫处的说明），所以首次建连时它为 false。
  bool get _isMidRecordingSession =>
      recordingState == RecordingState.record || recordingState == RecordingState.deviceRecord;

  // 当前进行中的会话（后端 in_progress，可能为 null：录音刚开始尚未创建时）。
  // 用于实时页说话人分配（SpeakerMarkSheet 需要 conversation.id）。
  ServerConversation? get inProgressConversation => _conversation;

  void setHasTranscripts(bool value) {
    hasTranscripts = value;
    notifyListeners();
  }

  void setConversationCreating(bool value) {
    debugPrint('set Conversation creating $value');
    // ConversationCreating = value;
    notifyListeners();
  }

  void _updateRecordingDevice(BtDevice? device) {
    if (device?.usesOfflineImport == true) device = null;
    debugPrint('connected device changed from ${_recordingDevice?.id} to ${device?.id}');
    _recordingDevice = device;
    notifyListeners();
  }

  void updateRecordingDevice(BtDevice? device) {
    _updateRecordingDevice(device);
  }

  Future _resetStateVariables({bool clearPhotos = false}) async {
    _resetSessionBufferSync(clearPhotos: clearPhotos);
  }

  /// 会话缓冲复位的**同步**本体。
  ///
  /// ⚠️ 存在的理由是 [onClosed] 是 `void`、没法 await，而 [_resetStateVariables] 的签名是
  /// `Future ... async` —— 在那里裸调它「能同步跑完」只是因为函数体里恰好一个 `await` 都
  /// 没有。将来谁往里加一个 await，清缓冲就会**晚于** `_startKeepAliveServices()` 排的重连
  /// 发生（新 session 的段落先落进旧缓冲，然后被这次复位清掉），而单测仍然绿 —— 它们也
  /// 依赖同一个巧合。所以本体放在这里，两个调用方都走它。
  void _resetSessionBufferSync({bool clearPhotos = false}) {
    debugPrint('[CaptureProvider] reset session buffer (clearPhotos: $clearPhotos)');
    _stopSegmentTimeout();
    segments = [];
    _segmentTimeOffset = 0.0;
    _maxSegmentEnd = 0.0;
    // Only clear photos if explicitly requested (photos are now independently managed)
    if (clearPhotos) {
      debugPrint('[CaptureProvider] Clearing ${photos.length} photos');
      photos = [];
    }
    hasTranscripts = false;
    suggestionsBySegmentId = {};
    _conversation = null;
    taggingSegmentIds = [];
    notifyListeners();
  }

  /// Clear photos manually (call when user wants to discard captured photos)
  void clearPhotos() {
    debugPrint('[CaptureProvider] clearPhotos called, clearing ${photos.length} photos');
    photos = [];
    notifyListeners();
  }

  /// Initialize persisted photos from local storage
  /// Call this on app startup to restore photos that were captured before the app was closed
  Future<void> initPersistedPhotos() async {
    if (_isPersistedPhotosInitialized) {
      debugPrint('[CaptureProvider] Persisted photos already initialized, skipping');
      return;
    }

    try {
      debugPrint('[CaptureProvider] Loading persisted photos from local storage');
      final persistedPhotos = await LocalImageStorage().loadStoredPhotosAsConversationPhotos(unassociatedOnly: true);

      if (persistedPhotos.isNotEmpty) {
        debugPrint('[CaptureProvider] Loaded ${persistedPhotos.length} persisted photos');
        // Add persisted photos to the list (don't replace existing photos from current session)
        final existingIds = photos.map((p) => p.id).toSet();
        final newPhotos = persistedPhotos.where((p) => !existingIds.contains(p.id)).toList();
        if (newPhotos.isNotEmpty) {
          photos = [...newPhotos, ...photos];
          notifyListeners();
        }
      }

      _isPersistedPhotosInitialized = true;
    } catch (e) {
      debugPrint('[CaptureProvider] Error loading persisted photos: $e');
      _isPersistedPhotosInitialized = true; // Mark as initialized even on error to avoid retry loops
    }
  }

  Future<void> onRecordProfileSettingChanged() async {
    await _resetState();
  }

  Future<void> changeAudioRecordProfile({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
  }) async {
    debugPrint("changeAudioRecordProfile");
    await _resetState();
    await _initiateWebsocket(audioCodec: audioCodec, sampleRate: sampleRate, channels: channels, isPcm: isPcm);
  }

  /// Switch between realtime streaming and file upload recording modes
  Future<void> setRecordingMode(RecordingMode mode) async {
    if (_recordingMode == mode) return;

    debugPrint('CaptureProvider: Switching recording mode from $_recordingMode to $mode');
    _recordingMode = mode;

    if (mode == RecordingMode.fileUpload) {
      // Stop WebSocket connection for file upload mode
      await _socket?.stop(reason: 'switching to file upload mode');
      // Initialize local audio buffer (will be created when recording starts)
      _localAudioBuffer = null;
    } else {
      // Clear local buffer and restart WebSocket for realtime mode
      _localAudioBuffer?.clear();
      _localAudioBuffer = null;
      await _resetState();
    }

    notifyListeners();
  }

  /// Start recording in file upload mode
  Future<void> startFileUploadRecording({
    required BleAudioCodec codec,
    required int sampleRate,
  }) async {
    if (_recordingMode != RecordingMode.fileUpload) {
      debugPrint('CaptureProvider: Cannot start file upload recording - not in file upload mode');
      return;
    }

    debugPrint('CaptureProvider: Starting file upload recording with codec: $codec, sampleRate: $sampleRate');
    _localAudioBuffer = LocalAudioBuffer(codec: codec, sampleRate: sampleRate);
    notifyListeners();
  }

  /// Stop recording and upload the audio file to create a conversation
  Future<ServerConversation?> stopAndUploadRecording() async {
    // Stop silence detection first
    _stopSilenceDetection();

    if (_localAudioBuffer == null || _localAudioBuffer!.isEmpty) {
      debugPrint('CaptureProvider: No audio data to upload');
      return null;
    }

    if (_isUploadingAudio) {
      debugPrint('CaptureProvider: Upload already in progress');
      return null;
    }

    _isUploadingAudio = true;
    notifyListeners();

    try {
      debugPrint(
          'CaptureProvider: Exporting audio buffer (${_localAudioBuffer!.frameCount} frames, ${_localAudioBuffer!.durationSeconds.toStringAsFixed(1)}s)');

      // Export buffer to file
      final audioFile = await _localAudioBuffer!.export();
      debugPrint('CaptureProvider: Exported to ${audioFile.path}');

      // Get language for transcription
      final language = await _getLanguageForTranscription();

      // Upload and create conversation
      debugPrint('CaptureProvider: Uploading audio file...');
      final conversation = await uploadAudioAndCreateConversation(
        audioFile: audioFile,
        language: language,
        startedAt: _localAudioBuffer!.recordingStartedAt,
        saveRecording: SharedPreferencesUtil().saveUploadedAudio,
      );

      // Save audio locally for playback before cleanup
      if (conversation != null) {
        debugPrint('CaptureProvider: Saving audio locally for conversation ${conversation.id}');
        await LocalAudioStorage().saveAudioForConversation(conversation.id, audioFile);

        // Trigger speaker identification in background (non-blocking).
        // Uploaded recordings are not processed by the WS path, so nothing has
        // run identification on them yet — ask the backend to.
        unawaited(_requestSpeakerIdentification(conversation.id));
      }

      // Cleanup - delete temp file (savedPath is the permanent copy)
      await audioFile.delete();
      _localAudioBuffer?.clear();

      if (conversation != null) {
        debugPrint('CaptureProvider: Conversation created: ${conversation.id}');
        debugPrint('CaptureProvider: Title: ${conversation.structured.title}');
        debugPrint('CaptureProvider: Segments: ${conversation.transcriptSegments.length}');
        // Notify conversation provider to refresh
        if (conversationProvider != null) {
          debugPrint('CaptureProvider: Adding conversation to provider');
          conversationProvider!.addConversation(conversation);
          debugPrint('CaptureProvider: Total conversations: ${conversationProvider!.conversations.length}');
        } else {
          debugPrint('CaptureProvider: WARNING - conversationProvider is null!');
        }
      } else {
        debugPrint('CaptureProvider: Failed to create conversation from audio upload');
      }

      return conversation;
    } catch (e) {
      debugPrint('CaptureProvider: Error uploading audio: $e');
      return null;
    } finally {
      _isUploadingAudio = false;
      notifyListeners();
    }
  }

  /// Add audio frame to local buffer (for file upload mode)
  void _addFrameToLocalBuffer(List<int> frame) {
    if (_recordingMode != RecordingMode.fileUpload) return;

    // Auto-initialize buffer if needed
    if (_localAudioBuffer == null && _currentAudioCodec != null) {
      debugPrint(
          'CaptureProvider: Auto-initializing local audio buffer with codec: $_currentAudioCodec, sampleRate: $_currentSampleRate');
      _localAudioBuffer = LocalAudioBuffer(codec: _currentAudioCodec!, sampleRate: _currentSampleRate);
    }

    _localAudioBuffer?.addFrame(frame);
  }

  /// Get the current recording duration in file upload mode
  double get fileUploadRecordingDuration {
    return _localAudioBuffer?.durationSeconds ?? 0;
  }

  Future<void> _initiateWebsocket({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
    bool force = false,
  }) async {
    Logger.debug('initiateWebsocket in capture_provider');

    BleAudioCodec codec = audioCodec;
    sampleRate ??= mapCodecToSampleRate(codec);
    channels ??= (codec == BleAudioCodec.pcm16 || codec == BleAudioCodec.pcm8) ? 1 : 2;

    Logger.debug('is ws null: ${_socket == null}');
    Logger.debug('Initiating WebSocket with: codec=$codec, sampleRate=$sampleRate, channels=$channels, isPcm=$isPcm');

    // Connect to the transcript socket
    String language = await _getLanguageForTranscription();
    debugPrint('[CaptureProvider] Initiating WebSocket with language: $language');

    final useOnDeviceStt = SharedPreferencesUtil().useOnDeviceStt;
    _isOnDeviceStt = useOnDeviceStt;
    _socket = await ServiceManager.instance().socket.conversation(
        codec: codec, sampleRate: sampleRate, language: language, force: force, useOnDeviceStt: useOnDeviceStt);
    if (_socket == null) {
      // Check if failure was due to usage limit (429)
      if (ServiceManager.instance().socket.wasUsageLimitExceeded) {
        debugPrint('Socket creation failed due to usage limit - triggering out-of-credits UI');
        usageProvider?.markAsOutOfCreditsAndRefresh();
        notifyListeners();
        return;
      }
      _startKeepAliveServices();
      debugPrint("Can not create new conversation socket");
      return;
    }
    _socket?.subscribe(this, this);
    _transcriptServiceReady = true;

    // Start segment-based timeout for auto-ending conversations
    // This matches the backend's CONVERSATION_CREATION_TIMEOUT (120s)
    _startSegmentTimeout();

    // 回填后端的 in-progress 会话 —— 只在「本次录音刚开始」时做，录音中途重连不做。
    //
    // `segments.isEmpty` 那半是原有的：本地有段落就别用服务端快照去覆盖。
    // `!_isMidRecordingSession` 那半是 2026-08-22 补的，配合 `onClosed` 里清缓冲那段：
    // 中途重连拿到的是一条**新** session，它自己不可能已有对话；而这一刻后端很可能正在
    // 把**上一条** session 的段落归档，`create_conversation` 先写 `status: "in_progress"`
    // 才跑到 `finish_conversation`（`developer_data.py`），中间那个窗口里查 in_progress
    // 会把刚归档的那批段落捞回新 session 的缓冲里 —— 于是用户点「结束」时它们被再提交
    // 一次，重复正是清缓冲要避免的那个。
    //
    // ⚠️ 判据能成立靠的是**置位顺序**：设备路径上 `_initiateDeviceAudioStreaming()`
    // （置 `deviceRecord`）排在 `_ensureDeviceSocketConnection()` 之后，手机麦路径上
    // `changeAudioRecordProfile()` 也排在 `onRecording` 回调（置 `record`）之前。所以
    // 首次建连走到这里时状态还不是 record/deviceRecord，回填照做（那正是「App 冷启动后
    // 恢复转录」要的）；只有 keepalive 的中途重连会被挡掉。这与
    // `_startSegmentTimeout` 里不能用 `recordingState` 做判据是同一个顺序事实。
    if (segments.isEmpty && !_isMidRecordingSession) {
      await _loadInProgressConversation();
    }

    notifyListeners();
  }

  // Just incase the ble connection get loss
  void _watchVoiceCommands(String deviceId, DateTime session) {
    Timer.periodic(const Duration(seconds: 3), (t) async {
      debugPrint("voice command watch");
      if (session != _voiceCommandSession) {
        t.cancel();
        return;
      }
      var value = await _getBleButtonState(deviceId);
      var buttonState = ByteData.view(Uint8List.fromList(value.sublist(0, 4).reversed.toList()).buffer).getUint32(0);
      debugPrint("watch device button $buttonState");

      // Force process — BLE 断连恢复时也走 PTT 发送
      if (buttonState == 5 && session == _voiceCommandSession) {
        _voiceCommandSession = null;

        // 通过 PressToTalkService 结束会话并发送转写结果
        _endPttSession();
      }
    });
  }

  Future streamButton(String deviceId) async {
    debugPrint('streamButton in capture_provider');
    _bleButtonStream?.cancel();
    _bleButtonStream = await _getBleButtonListener(deviceId, onButtonReceived: (List<int> value) {
      final snapshot = List<int>.from(value);
      debugPrint("device button raw: $snapshot (len=${snapshot.length})");
      if (snapshot.isEmpty || snapshot.length < 4) return;
      var buttonState = ByteData.view(Uint8List.fromList(snapshot.sublist(0, 4).reversed.toList()).buffer).getUint32(0);
      debugPrint("device button $buttonState");

      // start long press — 长按开始语音指令
      if (buttonState == 3 && _voiceCommandSession == null) {
        _voiceCommandSession = DateTime.now();
        _watchVoiceCommands(deviceId, _voiceCommandSession!);
        _playSpeakerHaptic(deviceId, 1);

        // 启动 Press-to-Talk 会话（复用 Chat 页面的 Talk API 流程）
        _startPttSession();
      }

      // release — 松手结束语音指令
      if (buttonState == 5 && _voiceCommandSession != null) {
        _voiceCommandSession = null;

        // 结束 PTT 会话，转写结果自动发送到 Chat
        _endPttSession();
      }
    });
  }

  StreamSubscription? _pttTranscriptSub;
  StreamSubscription? _pttErrorSub;

  // 防止 onTranscript Stream 和 endSession 返回值在同一会话里重复发送
  String? _lastPttDispatched;

  /// 把 BLE 长按转写文本派发到 Chat。
  /// 投递到 Memorion Agent 的最新一次会话（复用 Chat 页面 `_sendMessageUtil`
  /// 的同一套 ChatSessionProvider + MessageProvider 路径）。
  void _dispatchPttTranscriptToChat(String? text) {
    if (text == null || text.isEmpty) return;
    if (text == _lastPttDispatched) return;

    _dispatchPttTranscriptToMemorionAgent(text);
  }

  /// 把 PTT 转写文本发送到 App 的共享会话。
  /// 等价于在 Chat 页面 Memorion Agent 模式下手动发一条消息。
  void _dispatchPttTranscriptToMemorionAgent(String text) async {
    final messages = messageProvider;
    if (messages == null) {
      debugPrint('[CaptureProvider] BLE PTT 转写但 Provider 未就绪，丢弃: $text');
      AppSnackbar.showSnackbarError(
        appT((s) => s.pttNoAgentConnected, 'Not connected — voice command not sent'),
      );
      return;
    }

    // 标记去重 token，避免 onTranscript Stream 与 endSession 返回值重复发送。
    _lastPttDispatched = text;

    // All app entry points use the server's default shared chat, including BLE PTT.
    try {
      await messages.ensureSharedHistory();
    } catch (_) {
      _lastPttDispatched = null;
      AppSnackbar.showSnackbarError(appT((s) => s.pttNoAgentConnected, 'Not connected — voice command not sent'));
      return;
    }
    if (messages.sendingMessage || messages.isClearingChat) {
      _lastPttDispatched = null;
      AppSnackbar.showSnackbarError(appT((s) => s.tryAgain, 'Please try again'));
      return;
    }
    messages.addMessageLocally(text);
    messages.sendMessageStreamToServer(text);
  }

  /// 启动 Press-to-Talk 会话（BLE 长按触发）
  /// 复用 PressToTalkService，通过 Talk API WebSocket 实时转写
  void _startPttSession() async {
    if (pttService == null) return;

    // 尽早启动后台音频保活：app 若在后台,iOS 会冻结 Dart isolate 导致收不到音频、
    // WebSocket 被挂起。begin() 用静音音频维持 `audio` background mode,使后台长按
    // 也能完成转写。非 iOS 平台为 no-op(Android 走前台服务)。
    unawaited(PttKeepAliveService.instance.begin());

    // 防止快速连按导致订阅泄漏：如果 Service 不在 idle 状态，先取消上次会话
    if (pttService!.state != PttSessionState.idle) {
      debugPrint('[CaptureProvider] PTT Service 不在 idle 状态 (${pttService!.state})，先取消上次会话');
      pttService!.cancelSession();
      _pttTranscriptSub?.cancel();
      _pttTranscriptSub = null;
      _pttErrorSub?.cancel();
      _pttErrorSub = null;
    }

    // 新会话开始，清掉上次的去重 token
    _lastPttDispatched = null;

    try {
      // 订阅转写结果 Stream — 收到文本派发到 Chat（仅 Relay 模式生效）
      _pttTranscriptSub?.cancel();
      _pttTranscriptSub = pttService!.onTranscript.listen((text) {
        _dispatchPttTranscriptToChat(text);
      });
      _pttErrorSub?.cancel();
      _pttErrorSub = pttService!.onPttError.listen((err) {
        debugPrint('[CaptureProvider] BLE PTT 错误: $err');
      });

      // 获取 BLE 设备实际音频编码，映射到 Talk API 支持的 codec 字符串
      String codecStr = 'pcm16';
      int sampleRate = 16000;
      if (_recordingDevice != null) {
        final bleCodec = await _getAudioCodec(_recordingDevice!.id);
        codecStr = mapCodecToName(bleCodec);
        sampleRate = mapCodecToSampleRate(bleCodec);
        debugPrint('[CaptureProvider] BLE 设备音频编码: $bleCodec → codec=$codecStr, sampleRate=$sampleRate');
      }

      await pttService!.startSession(
        language: await _getLanguageForTranscription(),
        sampleRate: sampleRate,
        codec: codecStr,
      );
    } catch (e) {
      debugPrint('[CaptureProvider] 启动 BLE PTT 会话失败: $e');
    }
  }

  /// 结束 Press-to-Talk 会话（BLE 按钮释放）
  void _endPttSession() async {
    if (pttService == null) return;
    try {
      final text = await pttService!.endSession();
      // 直接使用返回值派发，不依赖 Stream（避免 race condition）；
      // dispatch 内部带去重，和 onTranscript 路径不会重复发送
      _dispatchPttTranscriptToChat(text);
    } catch (e) {
      debugPrint('[CaptureProvider] 结束 BLE PTT 会话失败: $e');
    } finally {
      // 转写结束(成功或失败)后必须释放后台保活,避免长期占用音频焦点 / 耗电。
      unawaited(PttKeepAliveService.instance.end());
    }
    _pttTranscriptSub?.cancel();
    _pttTranscriptSub = null;
    _pttErrorSub?.cancel();
    _pttErrorSub = null;
    _lastPttDispatched = null;
  }

  Future streamAudioToWs(String deviceId, BleAudioCodec codec) async {
    debugPrint('streamAudioToWs in capture_provider');
    // ⚠️ **必须 await。** 不 await 的话「取消旧的」和下面「记住新的」之间隔着
    // `_getBleAudioBytesListener` 里的几个 await（ensureConnection / requestMtu /
    // setNotifyValue，几百毫秒），两次并发调用会各自建一个订阅、而这个字段只记得后写入
    // 的那个 —— 前一个再也没人能取消它，于是同一帧音频被发给服务器两遍。
    //
    // 但真正的不变式**不在这里**：经 `_initiateDeviceAudioStreaming` 到这儿的有三条路
    // （`_resetState`、BLE 心跳重连、`resumeDeviceRecording`），另外
    // `speech_profile_provider` 还会独立订阅同一个特征。只靠调用方自觉是拦不住的，
    // 「一台设备最多一个活着的音频订阅」钉在 `bleAudioSubscriptions`
    // （`services/devices/live_subscription_registry.dart`）那个咽喉点上。
    await _bleBytesStream?.cancel();

    // Store current codec for file upload mode buffer initialization
    _currentAudioCodec = codec;
    _currentSampleRate = mapCodecToSampleRate(codec);

    // Initialize local buffer for file upload mode
    if (_recordingMode == RecordingMode.fileUpload) {
      debugPrint('streamAudioToWs: File upload mode - initializing local buffer with codec: $codec');
      _localAudioBuffer = LocalAudioBuffer(codec: codec, sampleRate: mapCodecToSampleRate(codec));
      _startSilenceDetection();
    }

    _bleBytesStream = await _getBleAudioBytesListener(deviceId, onAudioBytesReceived: (List<int> value) {
      final snapshot = List<int>.from(value);
      if (snapshot.isEmpty || snapshot.length < 3) return;

      // BLE 长按语音指令：转发音频字节到 PressToTalkService 进行实时转写
      if (_voiceCommandSession != null) {
        pttService?.sendAudio(snapshot.sublist(3));
      }

      // Support: opus codec, 1m from the first device connects
      var deviceFirstConnectedAt = _deviceService.getFirstConnectedAt();
      var checkWalSupported = codec.isOpusSupported() &&
          (deviceFirstConnectedAt != null &&
              deviceFirstConnectedAt.isBefore(DateTime.now().subtract(const Duration(seconds: 15)))) &&
          SharedPreferencesUtil().localSyncEnabled;
      if (checkWalSupported != _isWalSupported) {
        setIsWalSupported(checkWalSupported);
      }
      if (_isWalSupported) {
        _wal.getSyncs().phone.onByteStream(snapshot);
      }

      final trimmedValue = value.sublist(3);

      // File upload mode: store locally instead of streaming
      if (_recordingMode == RecordingMode.fileUpload) {
        _addFrameToLocalBuffer(trimmedValue);
        _processAudioBytesForVisualization(trimmedValue);
        _processAudioForSilenceDetection(trimmedValue);
        return;
      }

      // Realtime mode: send to WebSocket
      if (_socket?.state == SocketServiceState.connected) {
        _socket?.send(trimmedValue);

        // Process audio bytes for waveform visualization
        _processAudioBytesForVisualization(trimmedValue);

        // synced
        if (_isWalSupported) {
          _wal.getSyncs().phone.onBytesSync(value);
        }
      }
    });
    notifyListeners();
  }

  Future<void> _resetState() async {
    debugPrint('resetState');
    await _cleanupCurrentState();

    // Always try to stream audio if a device is present
    await _ensureDeviceSocketConnection();
    await _initiateDeviceAudioStreaming();

    // Photo streaming is now manually controlled via startPhotoCapture() / stopPhotoCapture()
    // Do NOT auto-start photo streaming here

    await initiateStorageBytesStreaming();
    notifyListeners();
  }

  Future _cleanupCurrentState() async {
    await _closeBleStream();
    notifyListeners();
  }

  // TODO: use connection directly
  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return BleAudioCodec.pcm8;
    }
    return connection.getAudioCodec();
  }

  Future<bool> _playSpeakerHaptic(String deviceId, int level) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return false;
    }
    return connection.performPlayToSpeakerHaptic(level);
  }

  Future<StreamSubscription?> _getBleStorageBytesListener(
    String deviceId, {
    required void Function(List<int>) onStorageBytesReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleStorageBytesListener(onStorageBytesReceived: onStorageBytesReceived);
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

  Future<StreamSubscription?> _getBleButtonListener(
    String deviceId, {
    required void Function(List<int>) onButtonReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleButtonListener(onButtonReceived: onButtonReceived);
  }

  Future<List<int>> _getBleButtonState(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(<int>[]);
    }
    return connection.getBleButtonState();
  }

  Future<void> _ensureDeviceSocketConnection() async {
    if (_recordingDevice == null || _phoneOwnsAudio) {
      return;
    }
    BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
    var language = await _getLanguageForTranscription();
    if (language != _socket?.language || codec != _socket?.codec || _socket?.state != SocketServiceState.connected) {
      await _initiateWebsocket(audioCodec: codec, force: true);
    }
  }

  Future<void> _initiateDeviceAudioStreaming() async {
    if (_recordingDevice == null || _phoneOwnsAudio) {
      return;
    }
    final deviceId = _recordingDevice!.id;
    BleAudioCodec codec = await _getAudioCodec(deviceId);
    await _wal.getSyncs().phone.onAudioCodecChanged(codec);
    await streamButton(deviceId);
    await streamAudioToWs(deviceId, codec);
    _startBleHeartbeat();

    // Set recording state to deviceRecord when device streaming starts
    updateRecordingState(RecordingState.deviceRecord);
    notifyListeners();
  }

  Future<void> _initiateDevicePhotoStreaming() async {
    debugPrint('[CaptureProvider] _initiateDevicePhotoStreaming called');

    // Prevent duplicate initialization
    if (_blePhotoStream != null) {
      debugPrint('[CaptureProvider] Photo stream already active, skipping');
      return;
    }

    if (_recordingDevice == null) {
      debugPrint('[CaptureProvider] _recordingDevice is null');
      return;
    }
    final deviceId = _recordingDevice!.id;
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      debugPrint('[CaptureProvider] connection is null');
      return;
    }

    debugPrint('[CaptureProvider] calling performCameraStartPhotoController');
    try {
      await connection.performCameraStartPhotoController();
    } catch (e) {
      debugPrint('[CaptureProvider] ERROR: Failed to start camera controller: $e');
      _isPhotoCaptureActive = false;
      notifyListeners();
      return;
    }
    debugPrint('[CaptureProvider] setting up performGetImageListener');
    _blePhotoStream = await connection.performGetImageListener(onImageReceived: (photoBytes) async {
      debugPrint('[CaptureProvider] Image received! Size: ${photoBytes.length}');

      // Validate JPEG header (should start with FFD8)
      if (photoBytes.length < 2) {
        debugPrint('[CaptureProvider] ERROR: Image too small');
        return;
      }
      final isJpeg = photoBytes[0] == 0xFF && photoBytes[1] == 0xD8;
      debugPrint(
          '[CaptureProvider] First bytes: ${photoBytes[0].toRadixString(16)} ${photoBytes[1].toRadixString(16)}, isJpeg: $isJpeg');

      final String tempId = 'temp_img_${DateTime.now().millisecondsSinceEpoch}';
      final String base64Image = base64Encode(photoBytes);
      debugPrint(
          '[CaptureProvider] Base64 length: ${base64Image.length}, first 50 chars: ${base64Image.substring(0, base64Image.length > 50 ? 50 : base64Image.length)}');

      // Cache image locally (similar to audio file upload mode)
      final savedPath = await LocalImageStorage().saveImageFromBytes(tempId, photoBytes);
      debugPrint('[CaptureProvider] Image cached locally with id: $tempId at path: $savedPath');

      // Add placeholder to UI for immediate feedback
      photos.add(ConversationPhoto(id: tempId, base64: base64Image, createdAt: DateTime.now(), localPath: savedPath));
      debugPrint('[CaptureProvider] Photo added to list, total photos: ${photos.length}');
      photos = List.from(photos);
      notifyListeners();

      // 异步上传图片到云端（不阻塞 UI）
      unawaited(_uploadImageToCloud(tempId, base64Image));

      // Chunking Logic
      const int chunkSize = 8192; // 8KB chunks
      final totalChunks = (base64Image.length / chunkSize).ceil();

      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize > base64Image.length) ? base64Image.length : start + chunkSize;
        final chunk = base64Image.substring(start, end);

        final payload = jsonEncode({
          'type': 'image_chunk',
          'id': tempId,
          'index': i,
          'total': totalChunks,
          'data': chunk,
        });

        if (_socket?.state == SocketServiceState.connected) {
          _socket?.send(payload); // Send the JSON string
        }
        await Future.delayed(const Duration(milliseconds: 20)); // Small delay to prevent flooding
      }
    });
    notifyListeners();
  }

  /// Start independent photo capture (separate from audio recording)
  /// Call this when user taps the photo capture button
  Future<void> startPhotoCapture() async {
    debugPrint('[CaptureProvider] startPhotoCapture called');
    if (_recordingDevice == null) {
      debugPrint('[CaptureProvider] No recording device connected');
      return;
    }

    try {
      final connection = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
      if (connection == null) {
        debugPrint('[CaptureProvider] Failed to get device connection');
        return;
      }

      final hasCamera = await connection.hasPhotoStreamingCharacteristic();
      if (!hasCamera) {
        debugPrint('[CaptureProvider] Device does not support photo capture');
        return;
      }

      _isPhotoCaptureActive = true;
      notifyListeners();

      // Start the photo streaming
      await _initiateDevicePhotoStreaming();
      debugPrint('[CaptureProvider] Photo capture started');
    } catch (e) {
      debugPrint('[CaptureProvider] ERROR: Failed to start photo capture: $e');
      _isPhotoCaptureActive = false;
      notifyListeners();
    }
  }

  /// Stop independent photo capture
  Future<void> stopPhotoCapture() async {
    debugPrint('[CaptureProvider] stopPhotoCapture called');
    if (!_isPhotoCaptureActive) {
      debugPrint('[CaptureProvider] Photo capture is not active');
      return;
    }

    // Cancel the photo stream subscription
    await _blePhotoStream?.cancel();
    _blePhotoStream = null;

    // Stop the camera controller on device
    try {
      if (_recordingDevice != null) {
        final connection = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
        if (connection != null && await connection.hasPhotoStreamingCharacteristic()) {
          await connection.performCameraStopPhotoController();
        }
      }
    } catch (e) {
      debugPrint('[CaptureProvider] ERROR: Failed to stop camera controller: $e');
    }

    _isPhotoCaptureActive = false;
    notifyListeners();
    debugPrint('[CaptureProvider] Photo capture stopped');
  }

  /// 上传图片到云端，失败时加入重试队列
  Future<void> _uploadImageToCloud(String tempId, String base64Data) async {
    try {
      final currentConversationId = _conversation?.id;
      final result = await uploadImageBase64(
        base64Data: base64Data,
        conversationId: currentConversationId,
        generateDescription: true,
      );
      if (result != null) {
        debugPrint('[CaptureProvider] Image $tempId uploaded to cloud: ${result.id}');
        _pendingImageUploads.remove(tempId);
      } else {
        debugPrint('[CaptureProvider] Image $tempId cloud upload returned null, queued for retry');
        _pendingImageUploads[tempId] = base64Data;
      }
    } catch (e) {
      debugPrint('[CaptureProvider] Image $tempId cloud upload failed: $e, queued for retry');
      _pendingImageUploads[tempId] = base64Data;
    }
  }

  /// 重试上传失败的图片
  Future<void> _retryPendingImageUploads() async {
    if (_pendingImageUploads.isEmpty) return;
    debugPrint('[CaptureProvider] Retrying ${_pendingImageUploads.length} pending image uploads');
    final pending = Map<String, String>.from(_pendingImageUploads);
    for (final entry in pending.entries) {
      await _uploadImageToCloud(entry.key, entry.value);
    }
  }

  /// Check if the connected device has photo capture capability
  Future<bool> hasPhotoCaptureCapability() async {
    if (_recordingDevice == null) return false;
    final connection = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
    if (connection == null) return false;
    return await connection.hasPhotoStreamingCharacteristic();
  }

  /// Trigger a single photo capture via voice command
  Future<void> triggerVoicePhotoCapture() async {
    if (_recordingDevice == null) {
      debugPrint('[VoicePhotoTrigger] No recording device connected');
      return;
    }

    // Check cooldown to prevent rapid-fire triggers
    if (_lastVoicePhotoTrigger != null) {
      final elapsed = DateTime.now().difference(_lastVoicePhotoTrigger!);
      if (elapsed < _voicePhotoTriggerCooldown) {
        debugPrint(
            '[VoicePhotoTrigger] Cooldown active, skipping (${elapsed.inSeconds}s < ${_voicePhotoTriggerCooldown.inSeconds}s)');
        return;
      }
    }

    _lastVoicePhotoTrigger = DateTime.now();
    debugPrint('[VoicePhotoTrigger] Triggering photo capture');

    try {
      final connection = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
      if (connection == null) {
        debugPrint('[VoicePhotoTrigger] Failed to get device connection');
        return;
      }

      final hasCamera = await connection.hasPhotoStreamingCharacteristic();
      if (!hasCamera) {
        debugPrint('[VoicePhotoTrigger] Device does not support photo capture');
        return;
      }

      await connection.cameraTakePhoto();
      debugPrint('[VoicePhotoTrigger] Photo capture command sent');
    } catch (e) {
      debugPrint('[VoicePhotoTrigger] Error triggering photo: $e');
    }
  }

  /// Check if transcript text contains photo trigger keywords
  bool _checkForPhotoTriggerKeywords(String text) {
    final lowerText = text.toLowerCase();
    for (final keyword in _photoTriggerKeywords) {
      if (lowerText.contains(keyword.toLowerCase())) {
        debugPrint('[VoicePhotoTrigger] Detected keyword: "$keyword" in text: "$text"');
        return true;
      }
    }
    return false;
  }

  /// Process transcript segments for voice photo triggers
  void _checkSegmentsForPhotoTrigger(List<TranscriptSegment> newSegments) {
    // Only check if we have a camera-capable device
    if (_recordingDevice == null) return;

    for (final segment in newSegments) {
      if (segment.text.isNotEmpty && _checkForPhotoTriggerKeywords(segment.text)) {
        triggerVoicePhotoCapture();
        break; // Only trigger once per batch of segments
      }
    }
  }

  void clearTranscripts() {
    segments = [];
    hasTranscripts = false;
    notifyListeners();
  }

  Future _closeBleStream() async {
    _stopBleHeartbeat();
    await _bleBytesStream?.cancel();
    // 顺手把 registry 里的记录也清掉，否则 `liveCount` 会一直报 1 —— 这个字段是排查
    // 重复帧时唯一的现场证据，让它撒谎等于把诊断能力还回去。
    if (_recordingDevice != null) {
      await bleAudioSubscriptions.cancel(_recordingDevice!.id);
    }
    _bleBytesStream = null;
    await _blePhotoStream?.cancel();
    if (_recordingDevice != null) {
      var connection = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
      if (connection != null && await connection.hasPhotoStreamingCharacteristic()) {
        await connection.performCameraStopPhotoController();
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _bleBytesStream?.cancel();
    _blePhotoStream?.cancel();
    _socket?.unsubscribe(this);
    _keepAliveTimer?.cancel();
    _bleHeartbeatTimer?.cancel();
    _internetStatusListener?.cancel();
    _silenceCheckTimer?.cancel();

    super.dispose();
  }

  void updateRecordingState(RecordingState state) {
    recordingState = state;
    _trackSessionClock(state);
    notifyListeners();
  }

  Future<void> streamRecording({bool Function()? shouldStart}) async {
    try {
      await _startStreamRecording(shouldStart: shouldStart);
    } catch (_) {
      // Restore a retryable state for every caller, including the live page.
      // Native startup now confirms recording only after the mic has started.
      updateRecordingState(RecordingState.stop);
      try {
        await stopStreamRecording();
      } catch (cleanupError) {
        debugPrint('Phone recording startup cleanup failed: $cleanupError');
      }
      rethrow;
    }
  }

  Future<void> _startStreamRecording({bool Function()? shouldStart}) async {
    updateRecordingState(RecordingState.initialising);
    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      updateRecordingState(RecordingState.stop);
      throw PlatformException(code: 'microphone_permission');
    }
    void checkStart() {
      if (shouldStart != null && !shouldStart()) throw PlatformException(code: 'foreground_required');
    }

    checkStart();

    // prepare
    await changeAudioRecordProfile(audioCodec: BleAudioCodec.pcm16, sampleRate: 16000);
    checkStart();

    // Store codec info for file upload mode buffer initialization
    _currentAudioCodec = BleAudioCodec.pcm16;
    _currentSampleRate = 16000;

    // Initialize local buffer for file upload mode
    if (_recordingMode == RecordingMode.fileUpload) {
      debugPrint('streamRecording: File upload mode - initializing local buffer');
      _localAudioBuffer = LocalAudioBuffer(codec: BleAudioCodec.pcm16, sampleRate: 16000);
      _startSilenceDetection();
    }

    // 确保首选音频输入设备已设置（仅当有持久化偏好时才切换，否则使用系统默认）
    final preferredInputId = SharedPreferencesUtil().preferredAudioInputId;

    // record
    await ServiceManager.instance().mic.start(
        shouldStart: shouldStart,
        onByteReceived: (bytes) {
          // File upload mode: store locally instead of streaming
          if (_recordingMode == RecordingMode.fileUpload) {
            _addFrameToLocalBuffer(bytes);
            _processAudioBytesForVisualization(bytes);
            _processAudioForSilenceDetection(bytes);
            return;
          }

          // Realtime mode: send to WebSocket
          if (_socket?.state == SocketServiceState.connected) {
            _socket?.send(bytes);
          }
          // Process audio bytes for waveform visualization
          _processAudioBytesForVisualization(bytes);
        },
        onRecording: () {
          if (shouldStart != null && !shouldStart()) {
            ServiceManager.instance().mic.stop();
            updateRecordingState(RecordingState.stop);
            return;
          }
          updateRecordingState(RecordingState.record);
          // FlutterSoundRecorder.startRecorder() 会重置 AVAudioSession，
          // 所以必须在录音真正开始后再次设置首选输入设备
          if (preferredInputId.isNotEmpty) {
            AudioInputDeviceService().setPreferredInput(preferredInputId).then((ok) {
              debugPrint('streamRecording: re-applied preferred input after mic.start: $ok');
            });
          }
        },
        onStop: () {
          if (_isPaused) {
            updateRecordingState(RecordingState.pause);
          } else {
            updateRecordingState(RecordingState.stop);
          }
        },
        onInitializing: () {
          updateRecordingState(RecordingState.initialising);
        });
  }

  stopStreamRecording() async {
    _stopSilenceDetection();
    await _cleanupCurrentState();
    ServiceManager.instance().mic.stop();
    _isPaused = false;
    updateRecordingState(RecordingState.stop);
    await _socket?.stop(reason: 'stop stream recording');
    await restoreDeferredDeviceRecording();
  }

  /// Pause mic recording — stops mic but keeps WebSocket alive for resume.
  Future<void> pauseMicRecording() async {
    // Record max segment end time so we can offset new segments after resume
    for (final s in segments) {
      if (s.end > _maxSegmentEnd) _maxSegmentEnd = s.end;
    }
    _segmentTimeOffset = _maxSegmentEnd;
    _isPaused = true;
    ServiceManager.instance().mic.stop();
    // onStop callback will see _isPaused=true and set state to pause
  }

  /// Resume mic recording after pause — restarts mic and resumes streaming.
  Future<void> resumeMicRecording() async {
    _isPaused = false;
    final resumeInputId = SharedPreferencesUtil().preferredAudioInputId;
    await ServiceManager.instance().mic.start(onByteReceived: (bytes) {
      if (_recordingMode == RecordingMode.fileUpload) {
        _addFrameToLocalBuffer(bytes);
      } else {
        _socket?.send(bytes);
      }
      _processAudioBytesForVisualization(bytes);
    }, onRecording: () {
      updateRecordingState(RecordingState.record);
      // 恢复录音后重新设置首选输入设备
      if (resumeInputId.isNotEmpty) {
        AudioInputDeviceService().setPreferredInput(resumeInputId);
      }
    }, onStop: () {
      if (_isPaused) {
        updateRecordingState(RecordingState.pause);
      } else {
        updateRecordingState(RecordingState.stop);
      }
    }, onInitializing: () {
      updateRecordingState(RecordingState.initialising);
    });
  }

  /// Returns false when phone recording owns the audio path. Reconnection
  /// still updates the device, and concurrent device starts run in order.
  Future<bool> streamDeviceRecording({BtDevice? device}) async {
    if (device?.usesOfflineImport == true) return false;
    if (device != null) _updateRecordingDevice(device);
    if (_phoneOwnsAudio) {
      _deviceRecordingDeferred = true;
      return false;
    }
    _deviceRecordingDeferred = false;
    final pending = _deviceRecordingStartup;
    if (pending != null) {
      await pending;
      return streamDeviceRecording(device: device);
    }
    return _deviceRecordingStartup = (() async {
      debugPrint("streamDeviceRecording $device");
      await _resetStateVariables();
      await _resetState();
      return recordingState == RecordingState.deviceRecord;
    })().whenComplete(() => _deviceRecordingStartup = null);
  }

  /// A device connected during phone startup/recording must resume when the
  /// phone releases audio ownership, including denied or failed shortcuts.
  Future<void> restoreDeferredDeviceRecording() async {
    if (!_deviceRecordingDeferred ||
        _phoneOwnsAudio ||
        _isPaused ||
        (recordingState != RecordingState.stop && recordingState != RecordingState.error)) return;
    final device = _recordingDevice;
    _deviceRecordingDeferred = false;
    if (device == null) return;
    try {
      if (!await streamDeviceRecording(device: device)) {
        debugPrint('Deferred device recording did not start');
      }
    } catch (error) {
      debugPrint('Deferred device recording failed: $error');
    }
  }

  Future stopStreamDeviceRecording({bool cleanDevice = false}) async {
    _stopBleHeartbeat();
    _stopSilenceDetection();
    await _cleanupCurrentState();
    if (cleanDevice) {
      _updateRecordingDevice(null);
    }
    _isPaused = false;
    updateRecordingState(RecordingState.stop);
    await _socket?.stop(reason: 'stop stream device recording');
  }

  @override
  void onClosed([int? closeCode]) {
    _transcriptionServiceStatuses = [];
    _transcriptServiceReady = false;
    debugPrint('[Provider] Socket is closed with code: $closeCode');

    if (closeCode == 4002) {
      // Refresh subscription to get latest usage data which will reflect the out of credits status.
      usageProvider?.markAsOutOfCreditsAndRefresh();
    }

    // 录音中 socket 意外断开 —— **不在客户端结束会话，只把过期的会话缓冲丢掉，让
    // keepalive 重连出一条新 session 继续录**（2026-08-22 改）。
    //
    // 以前这里是「停掉录音 + POST /process + `return` 跳过 keepalive」，而且判据只认
    // `record`（手机麦），把 `deviceRecord` 漏在外面。三处都是错的：
    //
    // 1. **那个 `return` 会让录音彻底死掉。** `PureSocket` 的 `onDone` 只往上抛
    //    `onClosed`，**自己不重连**（内部 `_reconnect()` 只由网络状态变化触发），所以
    //    keepalive 是唯一的恢复途径。跳过它之后：手机麦仍在 `mic.start` 的回调里往一个
    //    已关闭的 socket 灌音频（`PureSocket.send` 在非 connected 时静默丢弃），BLE 那边
    //    同理。表现是「UI 显示在录，一个字都不出」，正是本仓库反复踩的那类静默故障。
    // 2. **那次 POST 是多余的，还会抢锁。** 后端 WS 的 `finally` 里
    //    `_locked_finalize()` 已经把剩余段落交给 `_auto_process_conversation` 归档
    //    （`developer_listen.py`，已核对），客户端再 POST 一次是跟 finalize 抢同一把
    //    Redis 锁 —— 而 `_do_process_conversation` 的 dedup 同时查
    //    `auto_processed_conversation_id`，抢到了也多半被挡回。归档归后端，与
    //    `_startSegmentTimeout` 那条 gate 是同一个分工。
    // 3. **缓冲必须清。** 重连拿到的是一条**新** session，后端每个 session 的时间戳都从
    //    0 归零（`stream_transcript`）。不清的话新段落会接在 `end=250` 的旧段落后面却带
    //    着 0 起的时间轴：每行的时间标签往回跳，`_elapsedSeconds` 也会卡在旧的最大值上。
    //    更要紧的是用户接着点「结束」时，`forceProcessingCurrentConversation()` 会把
    //    旧+新一起提交给**新** session_id —— 新 session 没有 marker，dedup 拦不住，于是
    //    旧那批内容会在第二条对话里重复出现（后端 finalize 已经为它建过一条了）。
    //
    // ⚠️ 判据里必须排掉「我们自己关的」。停止录音那两条路
    // （`stopStreamRecording` / `stopStreamDeviceRecording`）刻意在 `_socket.stop()`
    // **之前**就把状态置成 `stop`，靠 `recordingState` 就能分辨；但
    // `forceProcessingCurrentConversation()` 全程不改状态，只能靠它的 in-flight 标志
    // —— 漏掉它就会在用户点「结束」时把 `_conversation` 提前清成 null。
    // 暂停（`RecordingState.pause`）刻意不在内：`_isMidRecordingSession` 不含它，而暂停
    // 期间 socket 本来就留着不动。这与改动前一致（原判据只认 `record`），不是新引入的
    // 缺口 —— 真要处理得连 `_segmentTimeOffset` 的语义一起想，留到有实际反馈再说。
    if (_isMidRecordingSession && !_isProcessingConversation && closeCode != 4002) {
      debugPrint('[Provider] Socket closed unexpectedly while recording (${segments.length} segments); '
          'backend finalize owns them — clearing stale session buffer and letting keepalive reconnect');
      // 与新建会话同一套复位（segments / 时间轴偏移 / _conversation / hasTranscripts），
      // 只是不碰 photos —— 照片是独立生命周期，不属于这条 session 缓冲。
      //
      // ⚠️ 走同步版本：本方法是 `void`，await 不了，而复位**必须**排在下面
      // `_startKeepAliveServices()` 之前完成（理由见 `_resetSessionBufferSync` 的注释）。
      _resetSessionBufferSync();
    }

    // 🚨 **手机麦 + 我们自己关的 ⇒ 必须在这里收尾，不能让 keepalive 把它续起来。**
    //
    // 两条路径在「结束」之后的语义是相反的，这个不对称是刻意的：
    // - 设备录音是 always-on。用户按「结束」结的是这一段对话，设备还戴在身上，所以让
    //   keepalive 续一条新 session 继续录（改动前也是这个行为）。
    // - 手机麦是用户显式发起的一次录音，按「结束」就是要停。而 `LiveCapturePage._stop()`
    //   只调 `forceProcessingCurrentConversation()`，它全程不改 `recordingState` 也不停
    //   mic；`stopStreamRecording()` 在整个 lib 里**没有任何调用者**。也就是说旧代码
    //   `onClosed` 里那句 `updateRecordingState(stop)` + `return` 是手机麦唯一的收尾。
    //   去掉它之后：状态停在 `record`（mic 的 `onStop` 回调永不触发）、首页波纹继续红、
    //   15s 后 keepalive 按 `recordingState == record` 重建一条新 WS，mic 音频接着灌进去
    //   —— 用户点完「结束」还会静默录出第二条对话，而且没有任何界面能停它。
    //
    // 所以这里保留旧的收尾语义。判据用 `recordingState == record` 而不是
    // `!havingRecordingDevice`：BLE 连着但用户拨了「这次用手机录」时 `_recordingDevice`
    // 仍非空，而状态才如实反映当前在用哪个采集源。
    //
    // ⚠️ mic 本身仍在跑（`mic.stop()` 没被调），这是改动前就有的泄漏，没在本次一并动
    // —— 从 socket 回调里去停采集设备是另一回事，值得单独做。
    if (_isProcessingConversation && recordingState == RecordingState.record) {
      debugPrint('[Provider] Phone-mic recording finished by us — not reconnecting');
      updateRecordingState(RecordingState.stop);
      return;
    }

    notifyListeners();
    _startKeepAliveServices();
  }

  void _startBleHeartbeat() {
    _stopBleHeartbeat();
    debugPrint('[BLE Heartbeat] Starting watchdog (interval: 10s, data timeout: 20s)');
    _bleHeartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkBleHeartbeat();
    });
  }

  void _stopBleHeartbeat() {
    if (_bleHeartbeatTimer != null) {
      debugPrint('[BLE Heartbeat] Stopping watchdog');
    }
    _bleHeartbeatTimer?.cancel();
    _bleHeartbeatTimer = null;
    _bleHeartbeatFailCount = 0;
  }

  Future<void> _checkBleHeartbeat() async {
    if (_recordingDevice == null) {
      _stopBleHeartbeat();
      return;
    }

    var connection = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
    if (connection == null) {
      debugPrint('[BLE Heartbeat] No connection available, stopping heartbeat');
      _stopBleHeartbeat();
      return;
    }

    bool healthy = await connection.isHealthy();
    if (healthy) {
      if (_bleHeartbeatFailCount > 0) {
        debugPrint('[BLE Heartbeat] Recovered after $_bleHeartbeatFailCount failures');
      }
      _bleHeartbeatFailCount = 0;
      return;
    }

    _bleHeartbeatFailCount++;
    debugPrint('[BLE Heartbeat] Health check FAILED (consecutive: $_bleHeartbeatFailCount/2)');

    if (_bleHeartbeatFailCount >= 2) {
      debugPrint('[BLE Heartbeat] Max failures reached, initiating reconnection');
      _stopBleHeartbeat();
      await _handleBleConnectionLost();
    }
  }

  Future<void> _handleBleConnectionLost() async {
    if (_recordingDevice == null) return;

    final deviceId = _recordingDevice!.id;
    debugPrint('[BLE Heartbeat] Handling connection loss for device $deviceId');

    // Clean up stale BLE streams
    await _bleBytesStream?.cancel();
    await bleAudioSubscriptions.cancel(deviceId);
    _bleBytesStream = null;
    await _bleButtonStream?.cancel();

    // Force disconnect the stale connection
    await _deviceService.forceDisconnect(deviceId);

    // Attempt reconnection (up to 3 tries)
    for (int attempt = 1; attempt <= 3; attempt++) {
      if (_recordingDevice == null) {
        debugPrint('[BLE Heartbeat] Recording device cleared during reconnection, aborting');
        return;
      }

      debugPrint('[BLE Heartbeat] Reconnection attempt $attempt/3');

      // Rediscover and reconnect
      await _deviceService.discover(desirableDeviceId: deviceId, timeout: 5);
      var connection = await _deviceService.ensureConnection(deviceId, force: true);

      if (connection != null) {
        debugPrint('[BLE Heartbeat] Reconnected on attempt $attempt, resuming audio streaming');

        // Resume audio streaming
        await _initiateDeviceAudioStreaming();

        // Verify data flow resumes after a short delay
        await Future.delayed(const Duration(seconds: 3));
        if (connection.lastDataReceivedAt != null &&
            connection.lastDataReceivedAt!.isAfter(DateTime.now().subtract(const Duration(seconds: 5)))) {
          debugPrint('[BLE Heartbeat] Audio flow confirmed after reconnection');
          return;
        }
        debugPrint('[BLE Heartbeat] Audio flow not confirmed after reconnection, retrying...');
      }

      // Wait before retrying
      if (attempt < 3) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    // All attempts failed
    debugPrint('[BLE Heartbeat] All reconnection attempts failed, notifying user');
    // 「暂停提醒」开关 + 静默时段网关（P-30N）。
    if (!NotificationPrefs.shouldSendPauseReminder()) return;
    NotificationService.instance.createNotification(
      title: appT((s) => s.captureDeviceLostTitle, 'Device Connection Lost'),
      body: appT(
        (s) => s.captureDeviceLostBody,
        'Unable to reconnect to your device. Please check that it is nearby and powered on.',
      ),
    );
  }

  void _startKeepAliveServices() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer(Duration(seconds: _keepAliveBackoffSeconds), () async {
      debugPrint("[Provider] keep alive (backoff: ${_keepAliveBackoffSeconds}s)...");
      if (!recordingDeviceServiceReady || _socket?.state == SocketServiceState.connected) {
        _keepAliveBackoffSeconds = 15;
        return;
      }

      // 🚨 **重连的编码要看「当前采集源在产出什么」，不是「有没有 BLE 设备」。**
      //
      // 以前第一个判据是 `_recordingDevice != null`。BLE 连着但用户拨了「这次用手机麦
      // 克风录」时 `_recordingDevice` 仍非空（`DeviceProvider._onDeviceConnected` 无条件
      // 设它），于是这里会去读设备编码（opus）建新 session，而 mic 回调灌进去的是
      // pcm16 —— 后端按 opus 解码 pcm16，转录为空或乱码，**全链路零错误日志**，UI 还显示
      // 在录。以前这条路很难走到（`onClosed` 在手机麦录音时直接停掉录音、不启 keepalive），
      // 2026-08-22 改成「意外断开只清缓冲 + 无条件 keepalive」之后它就成了常规路径。
      //
      // ⚠️ **不要改用 `_currentAudioCodec` 做判据。** 试过，那是反向的同一个错：它由
      // `streamAudioToWs` / `streamRecording` 写入但**停止录音时从不清空**，所以它是「本进程
      // 上一次用过的编码」而不是「当前采集源」。同一进程里先用手机麦录过一次，之后设备连上
      // 而 `_initiateDeviceAudioStreaming()` 还卡在 BLE 上（ensureConnection +
      // setNotifyValue，链路不稳时能超过 15s、且它才是写这个字段的地方），keepalive 就会拿着
      // 陈旧的 pcm16 给一台 opus 设备建会话。
      //
      // ⚠️ 已知缺口：`RecordingState.pause` 落到设备分支。暂停前是手机麦录音而 BLE 又连着
      // 时，暂停期间断线重连会建成设备编码的会话，恢复后 mic 灌 pcm16。这与改动前一致（原
      // 判据只认 `record`），不是新引入的；要治得先有一个「本次采集源」的显式状态。
      bool success = false;
      if (recordingState == RecordingState.record) {
        // 手机麦在采集：与 `streamRecording` 里 `changeAudioRecordProfile` 配的一致。
        await _initiateWebsocket(audioCodec: BleAudioCodec.pcm16, sampleRate: 16000);
        success = _socket?.state == SocketServiceState.connected;
      } else if (_recordingDevice != null) {
        BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
        await _initiateWebsocket(audioCodec: codec);
        success = _socket?.state == SocketServiceState.connected;
      }

      if (success) {
        _keepAliveBackoffSeconds = 15;
      } else {
        // Exponential backoff: 15 -> 30 -> 60 -> 120 (max)
        _keepAliveBackoffSeconds = (_keepAliveBackoffSeconds * 2).clamp(15, 120);
        _startKeepAliveServices();
      }
    });
  }

  @override
  void onError(Object err) {
    _transcriptionServiceStatuses = [];
    _transcriptServiceReady = false;
    debugPrint('Socket error: $err');

    // Handle usage limit exceeded (HTTP 429 from session creation)
    if (err is UsageLimitExceededException) {
      debugPrint('Usage limit exceeded - triggering out-of-credits UI');
      usageProvider?.markAsOutOfCreditsAndRefresh();
      // Don't restart keepalive services - user needs to upgrade
      notifyListeners();
      return;
    }

    notifyListeners();
    _startKeepAliveServices();
  }

  @override
  void onConnected() {
    _transcriptServiceReady = true;
    _keepAliveBackoffSeconds = 15;
    debugPrint('Socket connected');
    notifyListeners();
  }

  /// 把后端 in-progress 会话里已有的转录并回本地缓冲。
  ///
  /// ⚠️ **当前没有调用者，而且录音中途不要调它。** 直播会话进行中后端并没有 in-progress
  /// 对话（`create_conversation` 只在归档时被调），所以这一刻查到的只可能是**上一条正在
  /// 归档的**会话，捞回来会污染当前 session 的缓冲 —— 详见 `LiveCapturePage.initState`
  /// 里那段说明。留着它是因为「App 冷启动后恢复一条真正未完成的对话」仍然是合理用途，
  /// [_initiateWebsocket] 里那个受 `!_isMidRecordingSession` 保护的调用点就是这个语义。
  ///
  /// ⚠️ 内部必须 `await`。以前是 fire-and-forget，`await` 它会在 `_conversation` /
  /// `segments` 还没落地时就返回——调用方紧接着读到的仍是空的。
  Future<void> refreshInProgressConversations() async {
    await _loadInProgressConversation();
  }

  Future _loadInProgressConversation() async {
    final int oldSegmentCount = segments.length;
    var convos = await getConversations(statuses: [ConversationStatus.in_progress], limit: 1);
    _conversation = convos.isNotEmpty ? convos.first : null;
    if (_conversation != null) {
      final serverSegments = _conversation!.transcriptSegments;

      // FIX: Merge server segments with local segments instead of overwriting
      // This prevents loss of real-time segments that haven't synced to backend yet
      if (segments.isNotEmpty) {
        // Use updateSegments to merge: updates existing by ID, returns new ones to add
        final newSegments = TranscriptSegment.updateSegments(segments, serverSegments);
        segments.addAll(newSegments);
        debugPrint(
            '[CaptureProvider] Merged segments: $oldSegmentCount local + ${serverSegments.length} server -> ${segments.length} total');
      } else {
        // Local is empty, use server data
        segments = serverSegments;
        debugPrint('[CaptureProvider] Loaded ${segments.length} segments from server');
      }

      // Merge server photos with local photos (keep locally captured photos)
      final serverPhotos = _conversation!.photos;
      final localOnlyPhotos = photos.where((p) => p.id.startsWith('temp_img_')).toList();
      photos = [...serverPhotos, ...localOnlyPhotos];
    } else {
      // FIX: Only clear segments when not actively recording
      // This prevents accidental data loss during recording
      if (recordingState == RecordingState.stop) {
        segments = [];
        debugPrint('[CaptureProvider] No in-progress conversation and not recording, cleared segments');
      } else {
        debugPrint(
            '[CaptureProvider] No in-progress conversation but recording active, keeping ${segments.length} local segments');
      }
      // Keep locally captured photos (those with temp_img_ prefix)
      photos = photos.where((p) => p.id.startsWith('temp_img_')).toList();
    }
    setHasTranscripts(segments.isNotEmpty);
    notifyListeners();
  }

  @override
  void onMessageEventReceived(MessageEvent event) {
    if (event is ConversationProcessingStartedEvent) {
      // FIX: Only reset state when not actively recording
      // This prevents segments from disappearing if backend sends this event unexpectedly
      if (recordingState == RecordingState.stop) {
        conversationProvider!.addProcessingConversation(event.memory);
        _resetStateVariables();
      } else {
        debugPrint(
            '[CaptureProvider] Ignoring ConversationProcessingStartedEvent during active recording (state: $recordingState)');
        // Still add to processing list but don't clear local segments
        conversationProvider!.addProcessingConversation(event.memory);
      }
      return;
    }

    if (event is ConversationEvent) {
      event.memory.isNew = true;
      conversationProvider!.removeProcessingConversation(event.memory.id);
      _processConversationCreated(event.memory, event.messages.cast<ServerMessage>());
      return;
    }

    if (event is LastConversationEvent) {
      _handleLastConvoEvent(event.memoryId);
      return;
    }

    if (event is SpeakerLabelSuggestionEvent) {
      _handleSpeakerLabelSuggestionEvent(event);
      return;
    }

    if (event is TranslationEvent) {
      _handleTranslationEvent(event.segments);
      return;
    }

    if (event is MessageServiceStatusEvent) {
      _transcriptionServiceStatuses.add(event);
      _transcriptionServiceStatuses = List.from(_transcriptionServiceStatuses);
      notifyListeners();
      return;
    }

    if (event is PhotoProcessingEvent) {
      final tempId = event.tempId;
      final permanentId = event.photoId;
      final photoIndex = photos.indexWhere((p) => p.id == tempId);
      if (photoIndex != -1) {
        photos[photoIndex].id = permanentId;
        notifyListeners();
      }
      return;
    }

    if (event is PhotoDescribedEvent) {
      final photoId = event.photoId;
      final description = event.description;
      final discarded = event.discarded;
      final photoIndex = photos.indexWhere((p) => p.id == photoId);
      if (photoIndex != -1) {
        photos[photoIndex].description = description;
        photos[photoIndex].discarded = discarded;
        notifyListeners();
      }
      return;
    }
  }

  Future<void> forceProcessingCurrentConversation() async {
    // in-flight 守卫：一次处理没跑完之前，后续触发直接忽略。
    //
    // ⚠️ 这里刻意**没有**时间窗防抖。曾经有过一个 5 秒的，但它以「函数入口时刻」
    // 为基准，而 in-flight 标志要到下面 whenComplete 才放开 —— 中间必经
    // _waitForSessionCompletion 的固定 2 秒加一次 process 请求（服务端 p50 约
    // 10 秒）。等标志放开时距入口早已远超 5 秒，那个窗口在正常时序下永远不会命中，
    // 而它能命中的场合（处理整体不到 5 秒）恰好是「用户停了又立刻录一段」，
    // 拦下去只会让第二段静默消失。要拦重复触发，靠的就是这个标志本身。
    if (_isProcessingConversation) {
      debugPrint('[ForceProcess] Already processing a conversation, ignoring duplicate trigger');
      return;
    }
    _isProcessingConversation = true;

    // 🚨 从这里到请求派发出去之间，**每一条**异常路径都必须复位标志。漏一条的后果
    // 不是「这一次录音没处理」，而是标志永久停在 true、之后每次录音都在上面那个 if
    // 里静默返回：用户点了停止却什么都不发生，日志之外毫无痕迹，重启 App 才恢复。
    // 曾经只有 socket.stop / 等音频那一段在保护内，紧随其后的
    // `conversationProvider!` 就在保护之外 —— 而它是可空的（本文件里搜
    // 「conversationProvider is null」就能看到那条告警分支），解引用抛出时标志就再
    // 也回不来了。不变式由 test/force_process_inflight_latch_test.dart 钉住。
    try {
      // Capture segments and session_id before resetting state
      final segmentsToProcess = List<TranscriptSegment>.from(segments);
      final languageCode = SharedPreferencesUtil().userPrimaryLanguage;
      final sessionId = _socket?.sessionId; // Get session_id for linking audio

      // Stop socket first and wait for backend to save audio
      // This ensures the audio is uploaded before we call process endpoint
      if (_socket != null) {
        debugPrint('[ForceProcess] Stopping socket and waiting for audio save...');
        await _socket!.stop(reason: 'force processing conversation'); // i18n-ignore

        // Wait for backend to complete audio processing
        // The backend needs time to upload audio to GCS after WebSocket closes
        await _waitForSessionCompletion(sessionId);
      }

      _resetStateVariables();
      conversationProvider!.addProcessingConversation(
        ServerConversation(
            id: '0', createdAt: DateTime.now(), structured: Structured('', ''), status: ConversationStatus.processing),
      );

      // Pass segments and session_id to the process endpoint
      processInProgressConversation(
        segments: segmentsToProcess,
        language: languageCode,
        sessionId: sessionId, // Link audio from listen session
      ).then((result) {
        if (result == null || result.conversation == null) {
          conversationProvider!.removeProcessingConversation('0');
          debugPrint('processInProgressConversation returned null');
          return;
        }
        conversationProvider!.removeProcessingConversation('0');
        result.conversation!.isNew = true;
        _processConversationCreated(result.conversation, result.messages);
      }).catchError((e) {
        conversationProvider!.removeProcessingConversation('0');
        debugPrint('[ForceProcess] processInProgressConversation error: $e');
      }).whenComplete(() {
        // 处理管线结束（成功 / 返回 null / 异常）后放开标志，允许下一次录音被处理。
        // 注册在 catchError 之后，所以无论前面哪一环出错这里都会跑到。
        _isProcessingConversation = false;
      });
    } catch (e) {
      _isProcessingConversation = false;
      debugPrint('[ForceProcess] Failed before dispatching process request: $e');
      rethrow;
    }

    return;
  }

  /// Wait for backend session to complete audio processing
  /// Backend needs time to save audio to GCS after WebSocket disconnects
  Future<void> _waitForSessionCompletion(String? sessionId) async {
    if (sessionId == null) {
      debugPrint('[ForceProcess] No session ID, skipping wait');
      return;
    }

    // Wait for backend to complete audio upload (typically 1-3 seconds)
    // Using fixed delay as a simple solution; could be enhanced with polling
    const waitDuration = Duration(seconds: 2);
    debugPrint('[ForceProcess] Waiting ${waitDuration.inSeconds}s for backend audio processing...');
    await Future.delayed(waitDuration);
    debugPrint('[ForceProcess] Wait complete, proceeding with conversation processing');
  }

  Future<void> _processConversationCreated(ServerConversation? conversation, List<ServerMessage> messages) async {
    if (conversation == null) return;
    conversationProvider?.upsertConversation(conversation);
    MixpanelManager().conversationCreated(conversation);
    // Speaker identification runs on the backend right after processing — it owns
    // the recording, the VAD time axis and the diarization labels, none of which
    // we have here. Results arrive with the next conversation refresh.
  }

  /// Ask the backend to run voiceprint identification on a conversation.
  ///
  /// The work itself is server-side: it holds the recording, the VAD time axis
  /// the recording was trimmed on, and the diarization labels, so it can pool
  /// each speaker's audio and compare it against the user's profile and every
  /// person the user has tagged. Locally we would have neither the labels nor the
  /// right time axis. On success the segments come back with the next refresh.
  Future<void> _requestSpeakerIdentification(String conversationId) async {
    if (!SharedPreferencesUtil().hasSpeakerProfile) {
      debugPrint('[SpeakerID] Skipping - no speech profile');
      return;
    }
    try {
      final outcome = await identifyConversationSpeakers(conversationId);
      if (outcome.updatedSegments > 0) {
        debugPrint('[SpeakerID] Backend updated ${outcome.updatedSegments} segments');
        await conversationProvider?.forceRefreshConversations();
      } else {
        debugPrint('[SpeakerID] Backend matched nothing for $conversationId');
      }
    } catch (e) {
      debugPrint('[SpeakerID] Error: $e');
      // Non-critical - don't throw
    }
  }

  Future<void> _handleLastConvoEvent(String memoryId) async {
    bool conversationExists =
        conversationProvider?.conversations.any((conversation) => conversation.id == memoryId) ?? false;
    if (conversationExists) {
      return;
    }
    ServerConversation? conversation = await getConversationById(memoryId);
    if (conversation != null) {
      debugPrint("Adding last conversation to conversations: $memoryId");
      conversationProvider?.upsertConversation(conversation);
    } else {
      debugPrint("Failed to fetch last conversation: $memoryId");
    }
  }

  void _handleTranslationEvent(List<TranscriptSegment> translatedSegments) {
    try {
      if (translatedSegments.isEmpty) return;

      debugPrint("Received ${translatedSegments.length} translated segments");

      // Update the segments with the translated ones
      var remainSegments = TranscriptSegment.updateSegments(segments, translatedSegments);
      if (remainSegments.isNotEmpty) {
        debugPrint("Adding ${remainSegments.length} new translated segments");
      }

      notifyListeners();
    } catch (e) {
      debugPrint("Error handling translation event: $e");
    }
  }

  void _handleSpeakerLabelSuggestionEvent(SpeakerLabelSuggestionEvent event) {
    // Tagging
    if (taggingSegmentIds.contains(event.segmentId)) {
      return;
    }
    // If segment already exists, check if it's assigned. If so, ignore suggestion.
    var segment = segments.firstWhereOrNull((s) => s.id == event.segmentId);
    if (segment != null && segment.id.isNotEmpty && (segment.personId != null || segment.isUser)) {
      return;
    }

    // Auto-accept if enabled for new person suggestions
    if (SharedPreferencesUtil().autoCreateSpeakersEnabled) {
      assignSpeakerToConversation(event.speakerId, event.personId, event.personName, [event.segmentId]);
    } else {
      // Otherwise, store suggestion to be displayed.
      suggestionsBySegmentId[event.segmentId] = event;
      notifyListeners();
    }
  }

  Future<void> assignSpeakerToConversation(
      int speakerId, String personId, String personName, List<String> segmentIds) async {
    if (segmentIds.isEmpty) return;

    taggingSegmentIds = List.from(segmentIds);
    notifyListeners();

    try {
      String finalPersonId = personId;

      // Create person if new
      if (finalPersonId == 'new' || finalPersonId.isEmpty) {
        Person? newPerson = await peopleProvider?.createPersonProvider(personName);
        if (newPerson != null) {
          finalPersonId = newPerson.id;
        }
      }

      // Find conversation id
      if (_conversation == null) return;

      final isAssigningToUser = finalPersonId == 'user';

      // Update local state for all segments with this speakerId
      for (var segment in segments) {
        if (segmentIds.contains(segment.id)) {
          segment.isUser = isAssigningToUser;
          segment.personId = isAssigningToUser ? null : finalPersonId;
        }
      }

      // Persist change
      await assignBulkConversationTranscriptSegments(
        _conversation!.id,
        segmentIds,
        isUser: isAssigningToUser,
        personId: isAssigningToUser ? null : finalPersonId,
      );

      // Notify backend session
      if (_socket?.state == SocketServiceState.connected) {
        final payload = jsonEncode({
          'type': 'speaker_assigned',
          'speaker_id': speakerId,
          'person_id': finalPersonId,
          'person_name': personName,
          'segment_ids': segmentIds,
        });
        _socket?.send(payload);
      }

      // Remove all suggestions for this speakerId
      suggestionsBySegmentId.removeWhere((key, value) => value.speakerId == speakerId);
    } finally {
      taggingSegmentIds = [];
      notifyListeners();
    }
  }

  @override
  void onSegmentReceived(List<TranscriptSegment> newSegments) {
    _processNewSegmentReceived(newSegments);
  }

  void _processNewSegmentReceived(List<TranscriptSegment> newSegments) async {
    if (newSegments.isEmpty) return;

    // Apply time offset for segments received after pause/resume
    if (_segmentTimeOffset > 0) {
      for (final s in newSegments) {
        s.start += _segmentTimeOffset;
        s.end += _segmentTimeOffset;
      }
    }

    // Track max segment end time for future pause offset
    for (final s in newSegments) {
      if (s.end > _maxSegmentEnd) _maxSegmentEnd = s.end;
    }

    // Reset segment timeout — new segments arrived
    _lastSegmentReceivedTime = DateTime.now();

    if (segments.isEmpty) {
      debugPrint('newSegments: ${newSegments.last}');
    }
    var remainSegments = TranscriptSegment.updateSegments(segments, newSegments);
    segments.addAll(remainSegments);

    // Check for voice photo trigger keywords in new segments
    _checkSegmentsForPhotoTrigger(newSegments);

    hasTranscripts = true;
    notifyListeners();
  }

  void onInternetSatusChanged(InternetStatus status) {
    debugPrint("[SocketService] Internet connection changed $status");
    _internetStatus = status;
    notifyListeners();
  }

  void setIsWalSupported(bool value) {
    _isWalSupported = value;
    notifyListeners();
  }

  /*
  *
  *
  *
  *
  *
  * */

  List<int> currentStorageFiles = <int>[];
  int sdCardFileNum = 1;

// To show the progress of the download in the UI
  int currentTotalBytesReceived = 0;
  double currentSdCardSecondsReceived = 0.0;
//--------------------------------------------

  int totalStorageFileBytes = 0; // how much in storage
  int totalBytesReceived = 0; // how much already received
  double sdCardSecondsTotal = 0.0; // time to send the next chunk
  double sdCardSecondsReceived = 0.0;
  bool sdCardDownloadDone = false;
  bool sdCardReady = false;
  bool sdCardIsDownloading = false;
  String btConnectedTime = "";
  Timer? sdCardReconnectionTimer;

  void setSdCardIsDownloading(bool value) {
    sdCardIsDownloading = value;
    notifyListeners();
  }

  Future<void> updateStorageList() async {
    currentStorageFiles = await _getStorageList(_recordingDevice!.id);
    if (currentStorageFiles.isEmpty) {
      debugPrint('No storage files found');
      SharedPreferencesUtil().deviceIsV2 = false;
      debugPrint('Device is not V2');
      return;
    }
    totalStorageFileBytes = currentStorageFiles[0];
    var storageOffset = currentStorageFiles.length < 2 ? 0 : currentStorageFiles[1];
    totalBytesReceived = storageOffset;
    notifyListeners();
  }

  Future<void> initiateStorageBytesStreaming() async {
    debugPrint('initiateStorageBytesStreaming');
    if (_recordingDevice == null) return;
    String deviceId = _recordingDevice!.id;
    var storageFiles = await _getStorageList(deviceId);
    if (storageFiles.isEmpty) {
      return;
    }
    var totalBytes = storageFiles[0];
    if (totalBytes <= 0) {
      return;
    }
    var storageOffset = storageFiles.length < 2 ? 0 : storageFiles[1];
    if (storageOffset > totalBytes) {
      // bad state?
      debugPrint("SDCard bad state, offset > total");
      storageOffset = 0;
    }

    // 80: frame length, 100: frame per seconds
    BleAudioCodec codec = await _getAudioCodec(deviceId);
    sdCardSecondsTotal = totalBytes / codec.getFramesLengthInBytes() / codec.getFramesPerSecond();
    sdCardSecondsReceived = storageOffset / codec.getFramesLengthInBytes() / codec.getFramesPerSecond();

    // > 10s
    if (totalBytes - storageOffset > 10 * codec.getFramesLengthInBytes() * codec.getFramesPerSecond()) {
      sdCardReady = true;
    }

    notifyListeners();
  }

  Future _getFileFromDevice(int fileNum, int offset) async {
    sdCardFileNum = fileNum;
    int command = 0;
    _writeToStorage(_recordingDevice!.id, sdCardFileNum, command, offset);
  }

  Future _clearFileFromDevice(int fileNum) async {
    sdCardFileNum = fileNum;
    int command = 1;
    _writeToStorage(_recordingDevice!.id, sdCardFileNum, command, 0);
  }

  Future _pauseFileFromDevice(int fileNum) async {
    sdCardFileNum = fileNum;
    int command = 3;
    _writeToStorage(_recordingDevice!.id, sdCardFileNum, command, 0);
  }

  Future<bool> _writeToStorage(String deviceId, int numFile, int command, int offset) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(false);
    }
    return connection.writeToStorage(numFile, command, offset);
  }

  Future<List<int>> _getStorageList(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return [];
    }
    return connection.getStorageList();
  }

  Future<void> pauseDeviceRecording() async {
    if (_recordingDevice == null) return;
    _stopBleHeartbeat();
    // Pause the BLE stream but keep the device connection
    await _bleBytesStream?.cancel();
    await _bleButtonStream?.cancel();
    _isPaused = true;
    updateRecordingState(RecordingState.pause);
    notifyListeners();
  }

  Future<void> resumeDeviceRecording() async {
    if (_recordingDevice == null) return;
    _isPaused = false;
    // Resume streaming from the device
    await _initiateDeviceAudioStreaming();
    updateRecordingState(RecordingState.deviceRecord);
    notifyListeners();
  }
}
