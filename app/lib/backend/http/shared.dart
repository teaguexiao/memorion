import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/http/api/app_auth.dart';
import 'package:memorion/env/env.dart';
import 'package:http/http.dart' as http;
import 'package:memorion/utils/platform/platform_manager.dart';

/// Returns raw API key (NO Bearer prefix) for Memorion Platform API
String getAuthHeader() {
  return ApiConfig().apiKey;
}

/// Returns external_user_id for query parameters
String getExternalUserId() {
  return ApiConfig().externalUserId;
}

/// Appends external_user_id to URL
String appendExternalUserId(String url) {
  final separator = url.contains('?') ? '&' : '?';
  return '$url${separator}external_user_id=${getExternalUserId()}';
}

/// 全 App 共用一个 client，让底层 HTTP 连接池能复用 TCP + TLS 连接。
///
/// 原先每次调用都 `http.Client()` 新建且从不 close，于是每个请求都要重做一次
/// 完整握手。实测生产域名：新连接 ttfb≈1.18s（其中 TLS 握手就占 0.9s），
/// 复用连接 ttfb≈0.27s——握手是绝大多数接口的主要耗时来源。
///
/// 进程生命周期内长驻，不 close：close 掉会连带废掉连接池，下一个请求又得重新握手。
final http.Client _sharedClient = http.Client();

Future<http.Response?> makeApiCall({
  required String url,
  required Map<String, String> headers,
  required String body,
  required String method,
}) async {
  try {
    final isOwnApi = url.contains(Env.apiBaseUrl!);
    if (isOwnApi) {
      headers['Authorization'] = getAuthHeader();
      url = appendExternalUserId(url);
    }

    // 发出这一发用的到底是哪把 key —— 401 之后要靠它判断「凭据换没换」，所以必须在这里
    // 捕获：重试那一步会把 headers['Authorization'] 覆盖成新的。
    final sentKey = headers['Authorization'] ?? '';

    http.Response? response = await _performRequest(_sharedClient, url, headers, body, method);

    // 401 = 服务端不认识这把 key。可能只是它被另一台设备的登录顶掉了（换发是硬删除），
    // 换一把再打一次就好；不这么做的话本机会一直 401 到用户手动登出重登。
    //
    // ⚠️ 走 `recoverFromUnauthorized()` 而不是直接 `apiKeyRecovery.recover()`：换发本身
    // 有可能一次 HTTP 都发不出去（拿不到 Firebase ID token），只靠换发那一级等于没有自愈。
    // 见 app_auth.dart 里那个函数的注释。
    //
    // 重发对 POST/PATCH 也是安全的：401 由鉴权依赖抛出，**在业务逻辑之前**，所以第一次
    // 请求什么副作用都没留下，不存在写两遍的风险。
    //
    // 403 刻意不在这里：那是 bound key 拿去打别人的 external_user_id，换发不解决，
    // 重试只会再被拒一次。
    if (isOwnApi && response.statusCode == 401 && await recoverFromUnauthorized(rejectedKey: sentKey)) {
      headers['Authorization'] = getAuthHeader();
      response = await _performRequest(_sharedClient, url, headers, body, method);
    }
    return response;
  } catch (e, stackTrace) {
    debugPrint('HTTP request failed: $e, $stackTrace');
    PlatformManager.instance.instabug.reportCrash(e, stackTrace, userAttributes: {'url': url, 'method': method});
    return null;
  }
}

Future<http.Response> _performRequest(
  http.Client client,
  String url,
  Map<String, String> headers,
  String body,
  String method,
) async {
  switch (method) {
    case 'POST':
      headers['Content-Type'] = 'application/json';
      return await client.post(Uri.parse(url), headers: headers, body: body);
    case 'GET':
      return await client.get(Uri.parse(url), headers: headers);
    case 'DELETE':
      headers['Content-Type'] = 'application/json';
      return await client.delete(Uri.parse(url), headers: headers, body: body);
    case 'PATCH':
      headers['Content-Type'] = 'application/json';
      return await client.patch(Uri.parse(url), headers: headers, body: body);
    case 'PUT':
      headers['Content-Type'] = 'application/json';
      return await client.put(Uri.parse(url), headers: headers, body: body);
    default:
      throw Exception('Unsupported HTTP method: $method');
  }
}

// Function to extract content from the API response.
dynamic extractContentFromResponse(
  http.Response? response, {
  bool isEmbedding = false,
  bool isFunctionCalling = false,
}) {
  if (response != null && response.statusCode == 200) {
    var data = jsonDecode(response.body);
    if (isEmbedding) {
      var embedding = data['data'][0]['embedding'];
      return embedding;
    }
    var message = data['choices'][0]['message'];
    if (isFunctionCalling && message['tool_calls'] != null) {
      debugPrint('message $message');
      debugPrint('message ${message['tool_calls'].runtimeType}');
      return message['tool_calls'];
    }
    return data['choices'][0]['message']['content'];
  } else {
    debugPrint('Error fetching data: ${response?.statusCode}');
    // TODO: handle error, better specially for script migration
    PlatformManager.instance.instabug
        .reportCrash(Exception('Error fetching data: ${response?.statusCode}'), StackTrace.current, userAttributes: {
      'response_null': (response == null).toString(),
      'response_status_code': response?.statusCode.toString() ?? '',
      'is_embedding': isEmbedding.toString(),
      'is_function_calling': isFunctionCalling.toString(),
    });
    return null;
  }
}
