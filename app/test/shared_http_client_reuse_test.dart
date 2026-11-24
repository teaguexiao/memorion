import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 验证 `shared.dart` 的核心改动前提：`package:http` 的 Client 复用同一实例时会
/// 复用底层 TCP 连接，每次新建实例则每次都要重新建连。
///
/// 这是「关于我」页加载慢的三个成因之一（每请求一次 TLS 握手 ≈0.9s）。这里用本地
/// HttpServer 数**实际建立了几条连接**，不依赖网络，也不测时间，所以结果稳定。
void main() {
  late HttpServer server;
  late Set<int> connectionPorts;
  late String baseUrl;

  setUp(() async {
    // 每条 TCP 连接的客户端源端口唯一，用它数连接数。
    connectionPorts = {};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://${server.address.host}:${server.port}';
    server.listen((req) {
      connectionPorts.add(req.connectionInfo!.remotePort);
      req.response
        ..statusCode = 200
        ..write('ok');
      req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('复用同一个 Client：10 个请求只建 1 条连接', () async {
    final client = http.Client();
    try {
      for (var i = 0; i < 10; i++) {
        final res = await client.get(Uri.parse('$baseUrl/ping'));
        expect(res.statusCode, 200);
      }
    } finally {
      client.close();
    }

    expect(
      connectionPorts.length,
      1,
      reason: '共享 Client 应该复用连接池里的同一条连接，实际建了 ${connectionPorts.length} 条',
    );
  });

  test('每次新建 Client（改动前的写法）：10 个请求建 10 条连接', () async {
    for (var i = 0; i < 10; i++) {
      // 复刻改动前 makeApiCall 的行为：新建且不 close。
      final client = http.Client();
      final res = await client.get(Uri.parse('$baseUrl/ping'));
      expect(res.statusCode, 200);
    }

    expect(
      connectionPorts.length,
      10,
      reason: '每请求新建 Client 时连接池无法复用，每次都要重新握手',
    );
  });

  test('共享 Client 并发安全：20 个并发请求全部正确返回', () async {
    final client = http.Client();
    try {
      final responses = await Future.wait(
        List.generate(20, (i) => client.get(Uri.parse('$baseUrl/ping?i=$i'))),
      );
      expect(responses.length, 20);
      for (final r in responses) {
        expect(r.statusCode, 200);
        expect(r.body, 'ok');
      }
    } finally {
      client.close();
    }
  });

  test('并发爆发后，连接留在池里给后续请求复用', () async {
    final client = http.Client();
    try {
      // HTTP/1.1 一条连接同时只能跑一个请求，所以并发 5 个必然建 5 条连接——
      // 这也意味着启动时 loadAll() 那批并行请求各自都要握手一次，共享 Client
      // 救不了它们。共享的收益在**之后**：这 5 条连接会留在池里。
      await Future.wait(
        List.generate(5, (i) => client.get(Uri.parse('$baseUrl/burst?i=$i'))),
      );
      final afterBurst = connectionPorts.length;
      expect(afterBurst, 5);

      // 后续串行请求复用池里的连接，不再新建 → 这是「关于我」页省掉握手的机制。
      for (var i = 0; i < 10; i++) {
        await client.get(Uri.parse('$baseUrl/later?i=$i'));
      }
      expect(
        connectionPorts.length,
        afterBurst,
        reason: '后续请求应复用池中连接，实际新增了 ${connectionPorts.length - afterBurst} 条',
      );
    } finally {
      client.close();
    }
  });
}
