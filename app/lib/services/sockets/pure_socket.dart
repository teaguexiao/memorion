import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as socket_channel_status;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/utils/platform/platform_manager.dart';

enum PureSocketStatus { notConnected, connecting, connected, disconnected }

abstract class IPureSocketListener {
  void onConnected();
  void onMessage(dynamic message);
  void onClosed([int? closeCode]);
  void onError(Object err, StackTrace trace);

  void onInternetConnectionFailed() {}

  void onMaxRetriesReach() {}
}

abstract class IPureSocket {
  PureSocketStatus get status;
  void setListener(IPureSocketListener listener);
  Future<bool> connect();
  Future disconnect();

  /// 终态关闭：断开 + 释放资源 + 禁止后续自动重连。
  ///
  /// 必须与 [disconnect] 区分开。`disconnect()` 只是断开这一条连接，重连逻辑仍然
  /// 活着；上层「停止录音」用的却是终态语义。以前 `TranscriptSegmentSocketService.stop()`
  /// 调的是 `disconnect()`，于是录音停了之后网络一抖动 `_reconnect()` 还会跑——而
  /// 重连现在要 `POST /v1/listen` 建会话，会把用户下一次录音顶掉。
  Future stop();

  void send(dynamic message);

  void onInternetSatusChanged(InternetStatus status);

  void onMessage(dynamic message);
  void onConnected();
  void onClosed();
  void onError(Object err, StackTrace trace);
}

class PureSocketMessage {
  String? raw;
}

class PureCore {
  late InternetConnection internetConnection;

  factory PureCore() => _instance;

  /// The singleton instance of [PureCore].
  static final _instance = PureCore.createInstance();

  PureCore.createInstance() {
    internetConnection = InternetConnection.createInstance(
      useDefaultOptions: false,
      customCheckOptions: [
        InternetCheckOption(
          uri: Uri.parse('https://one.one.one.one'),
          timeout: const Duration(seconds: 12),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://icanhazip.com/'),
          timeout: const Duration(seconds: 12),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://jsonplaceholder.typicode.com/todos/1'),
          timeout: const Duration(seconds: 12),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://reqres.in/api/users/1'),
          timeout: const Duration(seconds: 12),
        ),
      ],
    );
  }
}

class PureSocket implements IPureSocket {
  StreamSubscription<InternetStatus>? _internetStatusListener;
  InternetStatus? _internetStatus;
  Timer? _internetLostDelayTimer;

  WebSocketChannel? _channel;
  WebSocketChannel get channel {
    if (_channel == null) {
      throw Exception('Socket is not connected');
    }
    return _channel!;
  }

  PureSocketStatus _status = PureSocketStatus.notConnected;
  PureSocketStatus get status => _status;

  IPureSocketListener? _listener;

  int _retries = 0;

  String url;

  /// 重连前用来换一条**新的** session URL。
  ///
  /// `/v1/listen` 换来的 URL 是一次性的：后端 `active_sessions` 按
  /// (developer_id, external_user_id) 只保留一条连接，拿旧 URL 重连会被判成
  /// 「同一用户的新连接」，于是刚建好的连接立刻被自己顶掉——日志里的
  /// `superseded by newer connection, closing` + `audio_buffer size: 0 bytes`
  /// 就是这么来的：连接反复自杀，一个音频字节都送不出去。所以重连必须先换
  /// session，不能复用构造时那条 URL。
  ///
  /// 为 null 时沿用原 URL（withSocket 等没有 session 概念的场景）。
  final Future<String?> Function()? _urlProvider;

  /// 持有 stream 订阅，好在主动换连接前取消它。
  /// 不取消的话旧 channel 关闭时会冒出 onDone → onClosed，被上层
  /// capture_provider 当成「录音意外中断」而停掉本次录音。
  StreamSubscription? _channelSub;

  /// `stop()` 之后置位，用来掐掉在飞的重连循环。
  ///
  /// 少了它，`stop()` 之后排在退避里的那一轮还会继续 `_reconnect()`，而重连现在
  /// 要 `POST /v1/listen` 换新 session——于是一个已经停掉的 socket 会去建会话，
  /// 把用户**下一次**录音的连接顶掉。跟本次修的是同一类 bug，只是晚一拍发作。
  bool _stopped = false;

  PureSocket(this.url, {Future<String?> Function()? urlProvider}) : _urlProvider = urlProvider {
    _internetStatusListener = PureCore().internetConnection.onStatusChange.listen((InternetStatus status) {
      onInternetSatusChanged(status);
    });
  }

  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() async {
    return await _connect();
  }

  Future<bool> _connect() async {
    if (_stopped) {
      debugPrint("[Socket] Can not connect, socket is stopped");
      return false;
    }
    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      return false;
    }

    // 丢掉上一条 channel 再开新的。先取消订阅：不取消的话旧 channel 关闭时
    // 会触发 onDone → onClosed，上层会把它当成「录音意外中断」而结束本次录音。
    await _discardChannel();

    debugPrint("request wss ${url}");
    _channel = IOWebSocketChannel.connect(
      url,
      headers: {
        'Authorization': ApiConfig().apiKey,
      },
      pingInterval: const Duration(seconds: 20),
      connectTimeout: const Duration(seconds: 15),
    );
    if (_channel?.ready == null) {
      return false;
    }

    _status = PureSocketStatus.connecting;
    dynamic err;
    try {
      await channel.ready;
    } on TimeoutException catch (e) {
      err = e;
    } on SocketException catch (e) {
      err = e;
    } on WebSocketChannelException catch (e) {
      err = e;
    }
    if (err != null) {
      print("Error: $err");
      _status = PureSocketStatus.notConnected;
      return false;
    }
    _status = PureSocketStatus.connected;
    _retries = 0;
    onConnected();

    final that = this;

    _channelSub = _channel?.stream.listen(
      (message) {
        if (message == "ping") {
          debugPrint(message);
          // Pong frame added manually https://www.rfc-editor.org/rfc/rfc6455#section-5.5.2
          _channel?.sink.add([0x8A, 0x00]);
          return;
        }
        that.onMessage(message);
      },
      onError: (err, trace) {
        that.onError(err, trace);
      },
      onDone: () {
        debugPrint("onDone with close code: ${_channel?.closeCode}");
        that.onClosed(_channel?.closeCode);
      },
      cancelOnError: true,
    );

    return true;
  }

  @override
  Future disconnect() async {
    if (_status == PureSocketStatus.connected) {
      // Send end message to notify backend before closing
      try {
        _channel?.sink.add(jsonEncode({"type": "end"}));
        // Give backend a moment to process the end message
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (e) {
        debugPrint("Error sending close message: $e");
      }

      // Close channel and wait for completion with timeout
      try {
        await _channel?.sink.close(socket_channel_status.normalClosure).timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            debugPrint("Channel close timed out");
          },
        );
      } catch (e) {
        debugPrint("Error closing channel: $e");
      }
    }
    final closeCode = _channel?.closeCode;
    _status = PureSocketStatus.disconnected;
    debugPrint("disconnect");

    // 主动断开后取消订阅，避免旧 channel 的 onDone 再补一次 onClosed。
    final sub = _channelSub;
    _channelSub = null;
    await sub?.cancel();

    onClosed(closeCode);
  }

  Future _cleanUp() async {
    _internetLostDelayTimer?.cancel();
    _internetStatusListener?.cancel();
  }

  /// 静默丢弃当前 channel：先取消订阅（避免 onDone 冒泡成「意外断开」），再关闭 sink。
  Future _discardChannel() async {
    final sub = _channelSub;
    _channelSub = null;
    await sub?.cancel();

    final old = _channel;
    _channel = null;
    if (old == null) return;
    try {
      await old.sink.close(socket_channel_status.normalClosure).timeout(
        const Duration(seconds: 2),
        onTimeout: () => debugPrint("[Socket] discard channel close timed out"),
      );
    } catch (e) {
      debugPrint("[Socket] Error discarding channel: $e");
    }
  }

  @override
  Future stop() async {
    // 先置位再断开：`_stopped` 是给在飞的重连循环看的，晚置位就会漏掉正好排在
    // 退避末尾的那一轮（它会去 POST /v1/listen 建一条会话，顶掉下次录音）。
    _stopped = true;
    await disconnect();
    await _cleanUp();
  }

  @override
  void onClosed([int? closeCode]) {
    _status = PureSocketStatus.disconnected;
    debugPrint("Socket closed with code: $closeCode");
    _listener?.onClosed(closeCode);
  }

  @override
  void onError(Object err, StackTrace trace) {
    _status = PureSocketStatus.disconnected;
    print("Error: ${err}");
    debugPrintStack(stackTrace: trace);

    _listener?.onError(err, trace);
    PlatformManager.instance.instabug.reportCrash(err, trace);
  }

  @override
  void onMessage(dynamic message) {
    debugPrint("[Socket] Message $message");
    _listener?.onMessage(message);
  }

  @override
  void onConnected() {
    _listener?.onConnected();
  }

  @override
  void send(message) {
    final channel = _channel;
    if (channel == null || _status != PureSocketStatus.connected) {
      // 静默丢弃是上一版最难查的地方：App 显示「正在录音」，后端却收到 0 字节。
      // 计数 + 采样打印，让丢帧在日志里留下痕迹。
      _droppedSends++;
      if (_droppedSends == 1 || _droppedSends % 100 == 0) {
        debugPrint("[Socket] Dropped $_droppedSends outbound message(s), status=$_status channel=${channel != null}");
      }
      return;
    }
    channel.sink.add(message);
  }

  /// 因 socket 未就绪而被丢掉的发送次数（音频帧居多）。
  int _droppedSends = 0;
  int get droppedSends => _droppedSends;

  void _reconnect() async {
    debugPrint("[Socket] reconnect...${_retries + 1}...");
    const int initialBackoffTimeMs = 1000; // 1 second
    const double multiplier = 1.5;
    const int maxRetries = 8;

    if (_stopped) {
      debugPrint("[Socket] Can not reconnect, socket is stopped");
      return;
    }

    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      debugPrint("[Socket] Can not reconnect, because socket is $_status");
      return;
    }

    // 换一条新 session URL 再连。旧 URL 已被后端消费掉，复用它等于让新连接
    // 顶掉自己（见 _urlProvider 的说明）。换发失败就退避重试，不拿旧 URL 硬连
    // ——那样只会连上一个必然收不到音频的死连接。
    if (!await _refreshUrl()) {
      _scheduleRetry(initialBackoffTimeMs, multiplier, maxRetries);
      return;
    }

    var ok = await _connect();
    if (ok) {
      return;
    }

    _scheduleRetry(initialBackoffTimeMs, multiplier, maxRetries);
  }

  /// 换一条新的 session URL。没有 provider 时保留原 URL（返回 true 表示可以继续连）。
  Future<bool> _refreshUrl() async {
    final provider = _urlProvider;
    if (provider == null) return true;

    try {
      final fresh = await provider();
      if (fresh == null || fresh.isEmpty) {
        debugPrint("[Socket] Can not refresh session url, will retry");
        return false;
      }
      url = fresh;
      return true;
    } catch (e) {
      debugPrint("[Socket] Error refreshing session url: $e");
      return false;
    }
  }

  void _scheduleRetry(int initialBackoffTimeMs, double multiplier, int maxRetries) async {
    int waitInMilliseconds = pow(multiplier, _retries).toInt() * initialBackoffTimeMs;
    await Future.delayed(Duration(milliseconds: waitInMilliseconds));
    // 退避期间可能被 stop() —— 再检查一次，别让已停的 socket 去建新会话。
    if (_stopped) return;
    _retries++;
    if (_retries > maxRetries) {
      debugPrint("[Socket] Reach max retries $maxRetries");
      _listener?.onMaxRetriesReach();
      return;
    }
    _reconnect();
  }

  @override
  void onInternetSatusChanged(InternetStatus status) {
    debugPrint("[Socket] Internet connection changed $status socket $_status");
    _internetStatus = status;
    switch (status) {
      case InternetStatus.connected:
        if (_status == PureSocketStatus.connected || _status == PureSocketStatus.connecting) {
          return;
        }
        _reconnect();
        break;
      case InternetStatus.disconnected:
        var that = this;
        _internetLostDelayTimer?.cancel();
        _internetLostDelayTimer = Timer(const Duration(seconds: 60), () async {
          if (_internetStatus != InternetStatus.disconnected) {
            return;
          }

          await that.disconnect();
          _listener?.onInternetConnectionFailed();
        });

        break;
    }
  }
}
