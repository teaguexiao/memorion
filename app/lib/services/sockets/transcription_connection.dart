import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/http/api/app_auth.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/backend/schema/message_event.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/services/notifications.dart';
import 'package:memorion/services/sockets/pure_socket.dart';
import 'package:memorion/services/sockets/usage_limit_exception.dart';
import 'package:memorion/utils/localization_helper.dart';
import 'package:memorion/utils/notification_prefs.dart';
import 'package:http/http.dart' as http;

abstract interface class ITransctipSegmentSocketServiceListener {
  void onMessageEventReceived(MessageEvent event);

  void onSegmentReceived(List<TranscriptSegment> segments);

  void onError(Object err);

  void onConnected();

  void onClosed([int? closeCode]);
}

class SpeechProfileTranscriptSegmentSocketService extends TranscriptSegmentSocketService {
  SpeechProfileTranscriptSegmentSocketService.create(super.sampleRate, super.codec, super.language)
      : super.create(includeSpeechProfile: false);
}

class ConversationTranscriptSegmentSocketService extends TranscriptSegmentSocketService {
  ConversationTranscriptSegmentSocketService.create(super.sampleRate, super.codec, super.language)
      : super.create(includeSpeechProfile: true);
}

/// A conversation socket service used as the secondary (backend) socket in custom STT mode.
/// Sends custom_stt=enabled so the backend skips cloud STT and waits for suggested_transcript.
class CustomSttTranscriptSegmentSocketService extends TranscriptSegmentSocketService {
  CustomSttTranscriptSegmentSocketService.create(super.sampleRate, super.codec, super.language)
      : super.create(includeSpeechProfile: true, customSttMode: true);
}

enum SocketServiceState {
  connected,
  disconnected,
}

class TranscriptSegmentSocketService implements IPureSocketListener {
  IPureSocket? _socket;
  final Map<Object, ITransctipSegmentSocketServiceListener> _listeners = {};

  SocketServiceState get state =>
      _socket?.status == PureSocketStatus.connected ? SocketServiceState.connected : SocketServiceState.disconnected;

  int sampleRate;
  BleAudioCodec codec;
  String language;
  bool includeSpeechProfile;
  bool customSttMode;

  String? _sessionId;
  String? _websocketUrl;
  String? _lastSessionId;  // Keep track of last session ID even after stop
  bool _lastCreateSessionWas429 = false;  // Track if last session creation failed due to usage limit

  /// Whether the last session creation attempt failed due to 429 (usage limit exceeded).
  bool get wasUsageLimitExceeded => _lastCreateSessionWas429;

  /// Get the current or last session ID (used for linking audio to conversations)
  /// Returns the active session ID, or the last one if socket was stopped
  String? get sessionId => _sessionId ?? _lastSessionId;

  /// Access the underlying socket (for composite service creation)
  IPureSocket? get socket => _socket;

  TranscriptSegmentSocketService.create(
    this.sampleRate,
    this.codec,
    this.language, {
    this.includeSpeechProfile = false,
    this.customSttMode = false,
  });

  /// Create a service with an externally-provided socket (e.g., CompositeTranscriptionSocket).
  TranscriptSegmentSocketService.withSocket(
    this.sampleRate,
    this.codec,
    this.language,
    IPureSocket socket, {
    this.includeSpeechProfile = false,
    this.customSttMode = false,
  }) {
    _socket = socket;
    _socket!.setListener(this);
  }

  void subscribe(Object context, ITransctipSegmentSocketServiceListener listener) {
    _listeners.remove(context.hashCode);
    _listeners.putIfAbsent(context.hashCode, () => listener);
  }

  void unsubscribe(Object context) {
    _listeners.remove(context.hashCode);
  }

  /// Step 1: Create session via HTTP POST to get WebSocket URL
  Future<bool> _createSession() async {
    _lastCreateSessionWas429 = false;  // Reset on each attempt
    try {
      final body = jsonEncode({
        'language': language,
        'sample_rate': sampleRate,
        'codec': codec.toString(),
        'include_speech_profile': includeSpeechProfile,
        'stt_service': SharedPreferencesUtil().transcriptionModel,
        if (customSttMode) 'custom_stt': 'enabled',
      });

      // 这一发用的哪把 key（`_postCreateSession` 内部同步重读同一个值，中间没有 await）。
      // 401 之后 `recoverFromUnauthorized` 要靠它判断凭据换没换，见那边的表。
      final sentKey = ApiConfig().apiKey;
      var response = await _postCreateSession(body);

      // ⚠️ 这条路**不走 makeApiCall**（api_key 在 query 里，不在 header），所以 401
      // 自愈得在这儿单独接一次。漏掉它的后果是全 App 最重的一种：key 被另一台设备的
      // 登录顶掉之后，录音会每 2 分钟静默重试一次、全部 401，用户既看不到提示也录不上音
      // ——2026-08-11 实测 111 次。
      // ⚠️ 两级自愈，不能只调 `apiKeyRecovery.recover()`：换发拿不到 Firebase ID token 时
      // 一次 HTTP 都不会发出去，那一级过不去就永远录不上音（2026-08-25 实测，每 2 分钟
      // 401 一次、整小时零换发请求）。第二级会丢掉作废的 bound key 退回内嵌 key。
      if (response.statusCode == 401 && await recoverFromUnauthorized(rejectedKey: sentKey)) {
        response = await _postCreateSession(body);
      }

      debugPrint('Create session response: ${response.statusCode} - ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        _sessionId = data['session_id'];
        _websocketUrl = data['websocket_url'];
        debugPrint('Session created: $_sessionId, WebSocket URL: $_websocketUrl');
        return _websocketUrl != null && _websocketUrl!.isNotEmpty;
      }

      if (response.statusCode == 429) {
        debugPrint('Usage limit exceeded (429) - notifying listeners');
        _lastCreateSessionWas429 = true;
        // Notify listeners with a typed exception so capture_provider can trigger UI
        final error = const UsageLimitExceededException();
        _listeners.forEach((k, v) {
          v.onError(error);
        });
        // Also send a local notification for background awareness
        NotificationService.instance.clearNotification(4);
        NotificationService.instance.createNotification(
          notificationId: 4,
          title: appT((s) => s.pushSubscriptionLimitTitle, 'Subscription Limit Reached'),
          body: appT(
            (s) => s.pushSubscriptionLimitBody,
            "You've reached your monthly usage limit. Please upgrade your plan or contact support.",
          ),
        );
        return false;
      }

      debugPrint('Failed to create session: ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('Error creating session: $e');
      return false;
    }
  }

  /// 发一次建会话请求。**每次都重新读 [ApiConfig.apiKey]** —— 401 自愈之后本地那把已经
  /// 换了，把 key 提前存进变量再重试等于拿作废的 key 又打一遍。
  Future<http.Response> _postCreateSession(String body) {
    final apiKey = ApiConfig().apiKey;
    final externalUserId = ApiConfig().externalUserId;
    return http.post(
      Uri.parse('${Env.apiBaseUrl}v1/listen?external_user_id=$externalUserId&api_key=$apiKey'),
      headers: {
        'Authorization': apiKey,
        'Content-Type': 'application/json',
      },
      body: body,
    );
  }

  /// Create the backend session via HTTP (to get WebSocket URL) without connecting.
  /// Returns the WebSocket URL, or null on failure.
  Future<String?> createSessionOnly() async {
    if (!await _createSession()) return null;
    return _websocketUrl;
  }

  /// 返回是否真的连上了。调用方据此判断成败——以前失败只打日志、静默返回，
  /// 上层拿到一个「非 null 但没连上」的 service 就继续往里灌音频。
  Future<bool> start() async {
    // If socket was provided via withSocket constructor, just connect it
    if (_socket != null) {
      bool ok = await _socket!.connect();
      if (!ok) {
        debugPrint("Can not connect to pre-configured socket");
      }
      return ok;
    }

    // Clear last session ID when starting new session
    _lastSessionId = null;

    // Create session first to get WebSocket URL
    if (!await _createSession()) {
      debugPrint("Failed to create listening session");
      return false;
    }

    // 重连时用 createSessionOnly() 换一条新 session URL——`/v1/listen` 换来的
    // URL 是一次性的，复用旧的会被后端判成「同一用户的新连接」而把自己顶掉。
    _socket = PureSocket(_websocketUrl!, urlProvider: createSessionOnly);
    _socket!.setListener(this);

    bool ok = await _socket!.connect();
    if (!ok) {
      debugPrint("Can not connect to websocket");
    }
    return ok;
  }

  Future stop({String? reason}) async {
    // 用 stop() 而不是 disconnect()：后者只断开这一条连接，PureSocket 的重连循环
    // 和 internet 监听都还活着。录音已经停了却还在自动重连，而重连要 POST /v1/listen
    // 建新会话——后端每来一条新连接就顶掉旧的，于是它会把用户下一次录音掀掉。
    await _socket?.stop();
    _listeners.clear();
    // Save session ID before clearing (for linking audio to conversations)
    if (_sessionId != null) {
      _lastSessionId = _sessionId;
    }
    _sessionId = null;
    _websocketUrl = null;

    if (reason != null) {
      debugPrint(reason);
    }
  }

  Future send(dynamic message) async {
    _socket?.send(message);
    return;
  }

  @override
  void onClosed([int? closeCode]) {
    _listeners.forEach((k, v) {
      v.onClosed(closeCode);
    });
  }

  @override
  void onError(Object err, StackTrace trace) {
    _listeners.forEach((k, v) {
      v.onError(err);
    });
  }

  @override
  void onMessage(event) {
    // Decode json
    dynamic jsonEvent;
    try {
      jsonEvent = jsonDecode(event);
    } on FormatException catch (e) {
      debugPrint(e.toString());
    }
    if (jsonEvent == null) {
      debugPrint("Can not decode message event json $event");
      return;
    }

    // Handle new format: {"type": "transcript", "segments": [...]}
    if (jsonEvent is Map && jsonEvent.containsKey("type")) {
      final type = jsonEvent["type"];

      if (type == "transcript" && jsonEvent.containsKey("segments")) {
        var segments = jsonEvent["segments"] as List;
        if (segments.isEmpty) {
          return;
        }
        _listeners.forEach((k, v) {
          v.onSegmentReceived(segments.map((e) => TranscriptSegment.fromJson(e)).toList());
        });
        return;
      }

      // Other message events
      var messageEvent = MessageEvent.fromJson(Map<String, dynamic>.from(jsonEvent));
      _listeners.forEach((k, v) {
        v.onMessageEventReceived(messageEvent);
      });
      return;
    }

    // Legacy format: Direct array of transcript segments
    if (jsonEvent is List) {
      var segments = jsonEvent;
      if (segments.isEmpty) {
        return;
      }
      _listeners.forEach((k, v) {
        v.onSegmentReceived(segments.map((e) => TranscriptSegment.fromJson(e)).toList());
      });
      return;
    }

    debugPrint(event.toString());
  }

  @override
  void onInternetConnectionFailed() {
    debugPrint("onInternetConnectionFailed");

    // 「暂停提醒」开关 + 静默时段网关（P-30N）。
    if (!NotificationPrefs.shouldSendPauseReminder()) return;
    // Send notification
    NotificationService.instance.clearNotification(3);
    NotificationService.instance.createNotification(
      notificationId: 3,
      title: appT((s) => s.pushInternetLostTitle, 'Internet Connection Lost'),
      body: appT(
        (s) => s.pushInternetLostBody,
        'Your device is offline. Transcription is paused until connection is restored.',
      ),
    );
  }

  @override
  void onMaxRetriesReach() {
    debugPrint("onMaxRetriesReach");

    // 「暂停提醒」开关 + 静默时段网关（P-30N）。
    if (!NotificationPrefs.shouldSendPauseReminder()) return;
    // Send notification
    NotificationService.instance.clearNotification(2);
    NotificationService.instance.createNotification(
      notificationId: 2,
      title: appT((s) => s.pushConnectionIssueTitle, 'Connection Issue'),
      body: appT(
        (s) => s.pushConnectionIssueBody,
        'Unable to connect to the transcript service.'
            ' Please restart the app or contact support if the problem persists.',
      ),
    );
  }

  @override
  void onConnected() {
    _listeners.forEach((k, v) {
      v.onConnected();
    });
  }
}
