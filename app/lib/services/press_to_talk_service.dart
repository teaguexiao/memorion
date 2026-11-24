import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/http/api/talk_api.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Press-to-Talk 状态
enum PttSessionState {
  idle, // 空闲
  preparing, // 准备中：麦克风已启动但 WebSocket 尚未开始连接，音频会被缓冲
  connecting, // 正在连接 Talk API WebSocket
  recording, // 录音/接收音频中
  processing, // 松手后等待转写结果
}

/// 独立的 Press-to-Talk 服务
/// 不绑定 UI 和音频源，可被 BLE 按钮和 Chat UI 按钮共同使用
/// 核心流程：
///   1. startSession() → 连接 Talk API WebSocket
///   2. sendAudio(bytes) → 发送音频数据（来源可以是本地麦克风或 BLE 设备）
///   3. endSession() → 发送结束信号，等待转写结果
class PressToTalkService extends ChangeNotifier {
  PttSessionState _state = PttSessionState.idle;
  PttSessionState get state => _state;

  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;
  Completer<String?>? _cleanedTextCompleter;
  bool _wsReady = false;

  /// 音频缓冲区：WebSocket 未就绪时暂存音频，上限 500 个块防止内存泄漏
  static const int _maxBufferChunks = 500;
  final List<List<int>> _audioBuffer = [];

  /// 是否已收到音频数据
  bool _hasAudioData = false;
  bool get hasAudioData => _hasAudioData;

  /// 实时部分转写文本（partial transcript from STT）
  String _partialText = '';
  String get partialText => _partialText;

  /// Whether the global PTT overlay should be shown for the current session.
  /// Hardware-triggered sessions keep this enabled; chat composer sessions hide it.
  bool _showOverlay = true;
  bool get showOverlay => _showOverlay;

  /// 转写结果 Stream — 多个消费者（BLE、Chat UI）都可以监听
  final StreamController<String> _transcriptController = StreamController<String>.broadcast();
  Stream<String> get onTranscript => _transcriptController.stream;

  /// 错误 Stream
  final StreamController<String> _errorController = StreamController<String>.broadcast();
  Stream<String> get onPttError => _errorController.stream;

  /// 进入准备状态：麦克风可以先启动，音频会被缓冲
  /// 调用后再调用 startSession() 连接 WebSocket
  void prepareSession({bool showOverlay = true}) {
    if (_state != PttSessionState.idle) return;
    _cleanup();
    _showOverlay = showOverlay;
    _state = PttSessionState.preparing;
    _hasAudioData = false;
    _partialText = '';
    _audioBuffer.clear();
    notifyListeners();
  }

  /// 开始一个 Press-to-Talk 会话
  /// 连接 Talk API WebSocket，准备接收音频
  Future<bool> startSession({
    String language = 'zh',
    int sampleRate = 16000,
    String codec = 'pcm16',
    bool showOverlay = true,
  }) async {
    // 允许从 idle 或 preparing 状态开始连接
    if (_state != PttSessionState.idle && _state != PttSessionState.preparing) return false;

    _showOverlay = showOverlay;

    // 仅从 idle 进入时需要清理（preparing 已在 prepareSession 中清理过）
    if (_state == PttSessionState.idle) {
      _cleanup();
      _showOverlay = showOverlay;
      _hasAudioData = false;
      _partialText = '';
      _audioBuffer.clear();
    }

    _state = PttSessionState.connecting;
    notifyListeners();

    // 创建 Talk API session
    final session = await createTalkSession(
      language: language,
      sampleRate: sampleRate,
      codec: codec,
      cleaningLevel: 'standard',
      outputFormat: 'paragraph',
    );

    if (session == null) {
      debugPrint('[PTT Service] 创建 Talk session 失败');
      _state = PttSessionState.idle;
      notifyListeners();
      _errorController.add('Failed to create talk session');
      return false;
    }

    debugPrint('[PTT Service] Talk session 创建成功: ${session.sessionId}');

    // 连接 WebSocket
    try {
      _wsChannel = IOWebSocketChannel.connect(
        session.websocketUrl,
        headers: {'Authorization': ApiConfig().apiKey},
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 15),
      );
      await _wsChannel!.ready;
    } catch (e) {
      debugPrint('[PTT Service] WebSocket 连接失败: $e');
      _state = PttSessionState.idle;
      notifyListeners();
      _errorController.add('Failed to connect WebSocket');
      return false;
    }

    // 监听 WebSocket 消息
    _wsSubscription = _wsChannel!.stream.listen(
      (message) {
        debugPrint('[PTT Service] 收到消息: $message');
        try {
          final data = jsonDecode(message);
          final type = data['type'];

          if (type == 'ready') {
            debugPrint('[PTT Service] 服务端就绪，刷入 ${_audioBuffer.length} 个缓冲块');
            _wsReady = true;
            // 刷入缓冲的音频
            for (final chunk in _audioBuffer) {
              try {
                _wsChannel?.sink.add(chunk);
              } catch (e) {
                debugPrint('[PTT Service] 刷入缓冲音频失败: $e');
              }
            }
            _audioBuffer.clear();
          } else if (type == 'partial') {
            _partialText = data['text'] as String? ?? '';
            notifyListeners();
          } else if (type == 'sentence') {
            // Final segment — update partial text with stable result
            final segments = data['segments'] as List<dynamic>?;
            if (segments != null && segments.isNotEmpty) {
              _partialText = segments.map((s) => s['text'] ?? '').join(' ').trim();
              notifyListeners();
            }
          } else if (type == 'cleaned') {
            final cleanedText = data['text'] as String? ?? '';
            debugPrint('[PTT Service] 转写结果: $cleanedText');
            _cleanedTextCompleter?.complete(cleanedText);
          } else if (type == 'complete') {
            if (_cleanedTextCompleter != null && !_cleanedTextCompleter!.isCompleted) {
              final cleanedText = data['cleaned_text'] as String? ?? '';
              _cleanedTextCompleter?.complete(cleanedText);
            }
          } else if (type == 'error') {
            debugPrint('[PTT Service] 错误: ${data['message']}');
            if (_cleanedTextCompleter != null && !_cleanedTextCompleter!.isCompleted) {
              _cleanedTextCompleter?.completeError(Exception(data['message']));
            }
          }
        } catch (e) {
          debugPrint('[PTT Service] 解析消息失败: $e');
        }
      },
      onError: (err) {
        debugPrint('[PTT Service] Stream 错误: $err');
        if (_cleanedTextCompleter != null && !_cleanedTextCompleter!.isCompleted) {
          _cleanedTextCompleter?.completeError(err);
        }
      },
      onDone: () {
        debugPrint('[PTT Service] Stream 关闭');
        if (_cleanedTextCompleter != null && !_cleanedTextCompleter!.isCompleted) {
          _cleanedTextCompleter?.completeError(Exception('WebSocket closed'));
        }
      },
    );

    _state = PttSessionState.recording;
    notifyListeners();
    return true;
  }

  /// 发送音频数据到 Talk API
  /// 可以是本地麦克风字节，也可以是 BLE 设备传来的字节
  /// preparing/connecting 状态下音频会被缓冲，recording 状态下直接发送
  void sendAudio(List<int> bytes) {
    // 允许 preparing、connecting、recording 三种状态接收音频
    if (_state != PttSessionState.recording &&
        _state != PttSessionState.connecting &&
        _state != PttSessionState.preparing) {
      return;
    }

    _hasAudioData = true;

    if (_wsReady && _wsChannel != null) {
      try {
        _wsChannel?.sink.add(bytes);
      } catch (e) {
        debugPrint('[PTT Service] 发送音频失败: $e');
      }
    } else {
      // WebSocket 未就绪，暂存；超出上限时丢弃最早的块
      _audioBuffer.add(bytes);
      if (_audioBuffer.length > _maxBufferChunks) {
        _audioBuffer.removeAt(0);
      }
    }
  }

  /// 结束会话，等待转写结果
  /// 返回转写文本，如果没有音频数据返回 null
  Future<String?> endSession() async {
    // 允许从 preparing/connecting/recording 状态结束会话
    if (_state != PttSessionState.recording &&
        _state != PttSessionState.connecting &&
        _state != PttSessionState.preparing) {
      return null;
    }

    if (!_hasAudioData) {
      debugPrint('[PTT Service] 没有音频数据，直接关闭');
      _cleanup();
      _state = PttSessionState.idle;
      notifyListeners();
      return null;
    }

    _state = PttSessionState.processing;
    notifyListeners();

    _cleanedTextCompleter = Completer<String?>();

    // 发送结束信号
    try {
      _wsChannel?.sink.add(jsonEncode({"type": "end"}));
    } catch (e) {
      debugPrint('[PTT Service] 发送结束信号失败: $e');
    }

    // 等待转写结果
    try {
      final cleanedText = await _cleanedTextCompleter!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('[PTT Service] 等待转写超时');
          return null;
        },
      );

      _cleanup();
      _state = PttSessionState.idle;
      notifyListeners();

      if (cleanedText != null && cleanedText.isNotEmpty) {
        _transcriptController.add(cleanedText);
      }
      return cleanedText;
    } catch (e) {
      debugPrint('[PTT Service] 等待转写失败: $e');
      _cleanup();
      _state = PttSessionState.idle;
      notifyListeners();
      _errorController.add('Failed to transcribe');
      return null;
    }
  }

  /// 取消当前会话
  void cancelSession() {
    debugPrint('[PTT Service] 取消会话');
    _cleanup();
    _state = PttSessionState.idle;
    notifyListeners();
  }

  void _cleanup() {
    _wsSubscription?.cancel();
    _wsSubscription = null;
    try {
      _wsChannel?.sink.close();
    } catch (e) {
      debugPrint('[PTT Service] 关闭 WebSocket 异常: $e');
    }
    _wsChannel = null;
    _wsReady = false;
    _partialText = '';
    _showOverlay = true;
    _audioBuffer.clear();
    // 先完成未完成的 Completer，避免 Future 永远挂起
    if (_cleanedTextCompleter != null && !_cleanedTextCompleter!.isCompleted) {
      _cleanedTextCompleter!.complete(null);
    }
    _cleanedTextCompleter = null;
  }

  @override
  void dispose() {
    _cleanup();
    _transcriptController.close();
    _errorController.close();
    super.dispose();
  }
}
