import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/services/sockets/pure_socket.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `/v1/listen` 换来的 wss URL 是**一次性**的。
///
/// 后端 `active_sessions` 按 (developer_id, external_user_id) 只保留一条连接，
/// 每来一条新连接就 `old_cancel_event.set()` 顶掉旧的。所以拿已经用过的 session
/// URL 重连，会被判成「同一用户的新连接」——新连接把自己顶掉，日志里就是
/// `superseded by newer connection, closing` + `audio_buffer size: 0 bytes`：
/// 连接反复自杀，一个音频字节都没送出去，App 界面上却一直显示「正在录音」。
///
/// 这个坑在 `99bed9809`（会话抢占）之前是无害的：复用旧 session_id 只是脏，不会
/// 自杀。抢占上线后就变成了「实时转录整条链路出不来字」。所以这里钉住的性质是：
/// **重连必须先换一条新 session URL，绝不复用构造时那条。**
///
/// 用真的本地 WebSocket server 而不是 mock：这个 bug 恰恰是「两段各自正确的代码
/// 接起来是错的」——`_reconnect()` 正确地重试了，`url` 字段也正确地保存着原值，
/// 错在它们的组合。只断言 mock 上的方法调用逮不到这种问题。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late List<String> requestedPaths;
  late List<WebSocket> liveSockets;
  late List<dynamic> serverReceived;

  const connectivityMethod = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const connectivityEvents = EventChannel('dev.fluttercommunity.plus/connectivity_status');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    SharedPreferencesUtil().memorionApiKey = 'test_key';
    SharedPreferencesUtil().externalUserId = 'uid_test';

    // PureSocket 构造时就会订阅 connectivity_plus 的 EventChannel（经由
    // internet_connection_checker_plus）。测试环境没有原生侧，不打桩会在
    // `new PureSocket` 那一行就抛 "Binding has not yet been initialized"。
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(connectivityMethod, (call) async => <String>['wifi']);
    messenger.setMockStreamHandler(connectivityEvents, MockStreamHandler.inline(onListen: (_, __) {}));

    // flutter_test 的 binding 把 HttpOverrides.global 换成「所有请求都返回 400 空响应」
    // 的 mock，而 WebSocket.connect 走的正是 HttpClient —— 不清掉它连本地 server
    // 都握不上手。
    HttpOverrides.global = null;

    requestedPaths = [];
    liveSockets = [];
    serverReceived = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      requestedPaths.add(req.uri.path);
      final ws = await WebSocketTransformer.upgrade(req);
      liveSockets.add(ws);
      // 这里就把消息收下来。上层再 listen 一次会 "Stream has already been listened to"。
      ws.listen(serverReceived.add, onError: (_) {}, cancelOnError: true);
    });
  });

  tearDown(() async {
    for (final ws in liveSockets) {
      await ws.close().catchError((_) => null);
    }
    await server.close(force: true);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(connectivityMethod, null);
    messenger.setMockStreamHandler(connectivityEvents, null);
  });

  String urlFor(String path) => 'ws://${server.address.address}:${server.port}$path';

  /// 等 [check] 成立，最多 [timeout]。轮询而不是固定 sleep，免得测试又慢又飘。
  Future<bool> waitFor(bool Function() check, {Duration timeout = const Duration(seconds: 8)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (check()) return true;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return check();
  }

  test('重连换新 session URL，不复用已被后端消费掉的旧 URL', () async {
    var minted = 0;
    final socket = PureSocket(
      urlFor('/v1/listen/stream/session-1'),
      urlProvider: () async {
        minted++;
        return urlFor('/v1/listen/stream/session-${minted + 1}');
      },
    );

    expect(await socket.connect(), isTrue, reason: '首次连接应该成功');
    expect(requestedPaths, ['/v1/listen/stream/session-1']);
    expect(minted, 0, reason: '首次连接用的是 start() 里刚建好的 session，不该换发');

    // 模拟后端/网络把连接掀了（生产日志里是 1006 ABNORMAL_CLOSURE）。
    await liveSockets.first.close();
    expect(await waitFor(() => socket.status != PureSocketStatus.connected), isTrue,
        reason: '服务端关闭后 socket 应转为非 connected');

    // 网络恢复 → 触发重连。这是生产里 _reconnect() 的真实入口。
    socket.onInternetSatusChanged(InternetStatus.connected);

    expect(await waitFor(() => requestedPaths.length >= 2), isTrue, reason: '应该发起第二次连接');
    expect(minted, greaterThanOrEqualTo(1), reason: '重连前必须向后端换一条新 session');
    expect(requestedPaths[1], isNot('/v1/listen/stream/session-1'),
        reason: '复用旧 session URL 会让新连接把自己顶掉 —— 这正是 STT 出不来字的根因');
    expect(requestedPaths[1], startsWith('/v1/listen/stream/session-'));
    expect(await waitFor(() => socket.status == PureSocketStatus.connected), isTrue);

    await socket.stop();
  });

  test('换发失败时退避重试，绝不拿旧 URL 硬连', () async {
    final socket = PureSocket(
      urlFor('/v1/listen/stream/session-1'),
      urlProvider: () async => null, // 后端 429 / 网络抖动 / 无凭证
    );

    expect(await socket.connect(), isTrue);
    expect(requestedPaths, ['/v1/listen/stream/session-1']);

    await liveSockets.first.close();
    expect(await waitFor(() => socket.status != PureSocketStatus.connected), isTrue);

    socket.onInternetSatusChanged(InternetStatus.connected);

    // 给足一轮退避的时间（首轮 1s）。拿旧 URL 硬连的话这里会看到第二次请求。
    await Future.delayed(const Duration(milliseconds: 1800));
    expect(requestedPaths, hasLength(1),
        reason: '换不到新 session 就该等下一轮，连上一个必然收不到音频的死连接没有意义');

    await socket.stop();
  });

  test('stop() 之后不再重连、也不再换发 session', () async {
    var minted = 0;
    final socket = PureSocket(
      urlFor('/v1/listen/stream/session-1'),
      urlProvider: () async {
        minted++;
        return urlFor('/v1/listen/stream/session-${minted + 1}');
      },
    );

    expect(await socket.connect(), isTrue);
    await liveSockets.first.close();
    expect(await waitFor(() => socket.status != PureSocketStatus.connected), isTrue);

    // 触发重连后立刻停掉：模拟用户点「停止录音」正好卡在退避窗口里。
    socket.onInternetSatusChanged(InternetStatus.connected);
    await socket.stop();

    final pathsAtStop = requestedPaths.length;
    final mintedAtStop = minted;

    // 等过好几轮退避（1s、1s、1.5s…）。
    await Future.delayed(const Duration(seconds: 4));

    // 停掉的 socket 若继续重连，就会 POST /v1/listen 建会话，而后端每来一条新连接
    // 就顶掉旧的——于是它会把用户**下一次**录音掀掉。必须彻底停住。
    expect(requestedPaths.length, pathsAtStop, reason: 'stop() 之后不该再发起连接');
    expect(minted, mintedAtStop, reason: 'stop() 之后不该再换发 session，否则会顶掉下次录音');

    // 已 stop 的 socket 不接受再次 connect（避免被上层复用成僵尸连接）。
    expect(await socket.connect(), isFalse);
  });

  test('没有 urlProvider 时沿用原 URL（withSocket 等无 session 概念的场景不受影响）', () async {
    final socket = PureSocket(urlFor('/plain'));

    expect(await socket.connect(), isTrue);
    await liveSockets.first.close();
    expect(await waitFor(() => socket.status != PureSocketStatus.connected), isTrue);

    socket.onInternetSatusChanged(InternetStatus.connected);

    expect(await waitFor(() => requestedPaths.length >= 2), isTrue);
    expect(requestedPaths[1], '/plain');

    await socket.stop();
  });

  test('未连接时 send() 不抛异常，且把丢帧记进计数器', () async {
    final socket = PureSocket(urlFor('/never'));

    // 上一版这里是 `_channel?.sink.add(message)`：channel 为 null 就静默丢弃。
    // App 显示「正在录音」而后端 audio_buffer 是 0 字节，就是这么无声无息地发生的。
    expect(() => socket.send([1, 2, 3]), returnsNormally);
    expect(socket.droppedSends, 1);

    for (var i = 0; i < 5; i++) {
      socket.send([0]);
    }
    expect(socket.droppedSends, 6);
    expect(requestedPaths, isEmpty, reason: '没 connect 过就不该有任何连接');

    await socket.stop();
  });

  test('连上之后 send() 真的把字节推到服务端', () async {
    final socket = PureSocket(urlFor('/v1/listen/stream/s'));
    expect(await socket.connect(), isTrue);

    socket.send([1, 2, 3, 4]);

    expect(await waitFor(() => serverReceived.isNotEmpty), isTrue,
        reason: '连上后不该再丢帧；droppedSends=${socket.droppedSends}');
    expect(socket.droppedSends, 0);

    await socket.stop();
  });
}
