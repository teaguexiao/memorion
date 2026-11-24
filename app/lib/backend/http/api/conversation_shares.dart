import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:memorion/env/env.dart';

class ConversationShare {
  final String id;
  final String expiryMode;
  final DateTime? expiresAt;
  final bool active;
  final String? url;

  const ConversationShare({required this.id, required this.expiryMode, required this.active, this.expiresAt, this.url});

  factory ConversationShare.fromJson(Map<String, dynamic> json) => ConversationShare(
        id: json['id'] as String,
        expiryMode: json['expiry_mode'] as String,
        active: json['active'] == true,
        expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
        url: json['url'] as String?,
      );
}

class ShareFailure implements Exception {
  final int status;
  const ShareFailure(this.status);
}

abstract class ConversationSharingApi {
  Future<ConversationShare?> load(String conversationId);
  Future<ConversationShare> create(String conversationId, String expiryMode, String requestId);
  Future<ConversationShare> rotate(String id, String requestId);
  Future<void> revoke(String id);
  void close() {}
}

/// Separate transport: never use makeApiCall's embedded-key fallback or logging.
/// The raw share URL lives only in the open sheet, not preferences or telemetry.
class HttpConversationSharingApi extends ConversationSharingApi {
  final http.Client _client;
  final String _base;
  final Future<String?> Function()? _testToken;
  HttpConversationSharingApi({http.Client? client, String? baseUrl, Future<String?> Function()? tokenProvider})
      : _client = client ?? http.Client(),
        _base = (baseUrl ?? Env.apiBaseUrl ?? '').replaceAll(RegExp(r'/$'), ''),
        _testToken = tokenProvider;

  Future<http.Response> _request(String method, String path, [Map<String, dynamic>? body]) async {
    final user = _testToken == null ? FirebaseAuth.instance.currentUser : null;
    final token =
        await (_testToken?.call() ?? user?.getIdToken() ?? Future.value(null)).timeout(const Duration(seconds: 10));
    if (token == null || token.isEmpty) throw const ShareFailure(401);
    if (_testToken == null && FirebaseAuth.instance.currentUser?.uid != user?.uid) throw const ShareFailure(401);
    final request = http.Request(method, Uri.parse('$_base$path'));
    request.headers.addAll({'Authorization': 'Bearer $token', 'Content-Type': 'application/json'});
    if (body != null) request.body = jsonEncode(body);
    try {
      final response = await (() async => http.Response.fromStream(await _client.send(request)))()
          .timeout(const Duration(seconds: 20));
      if (_testToken == null && FirebaseAuth.instance.currentUser?.uid != user?.uid) throw const ShareFailure(401);
      if (response.statusCode < 200 || response.statusCode >= 300) throw ShareFailure(response.statusCode);
      return response;
    } on ShareFailure {
      rethrow;
    } catch (_) {
      throw const ShareFailure(0);
    }
  }

  @override
  Future<ConversationShare?> load(String conversationId) async {
    final response = await _request('GET', '/v1/shares?conversation_id=${Uri.encodeQueryComponent(conversationId)}');
    final rows = jsonDecode(utf8.decode(response.bodyBytes)) as List;
    return rows.isEmpty ? null : ConversationShare.fromJson(Map<String, dynamic>.from(rows.first as Map));
  }

  @override
  Future<ConversationShare> create(String conversationId, String expiryMode, String requestId) async {
    final response = await _request(
        'POST', '/v1/shares', {'conversation_id': conversationId, 'expiry_mode': expiryMode, 'request_id': requestId});
    return ConversationShare.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  }

  @override
  Future<ConversationShare> rotate(String id, String requestId) async {
    final response = await _request('POST', '/v1/shares/$id/rotate', {'request_id': requestId});
    return ConversationShare.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  }

  @override
  Future<void> revoke(String id) async {
    await _request('DELETE', '/v1/shares/$id');
  }

  @override
  void close() => _client.close();
}
