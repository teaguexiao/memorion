import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/models/pdp_snapshot.dart';

Future<PdpSnapshot?> getLatestPdpSnapshot({String? date, String? language}) async {
  final query = <String, String>{};
  if (date != null && date.isNotEmpty) query['date'] = date;
  if (language != null && language.isNotEmpty) query['language'] = language;
  final qs =
      query.isEmpty ? '' : '?${query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';

  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/pdp/latest$qs',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  if (response.statusCode == 200) {
    return PdpSnapshot.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  }
  debugPrint('getLatestPdpSnapshot error ${response.statusCode}');
  return null;
}

Future<PdpHistoryResponse> getPdpHistory({int limit = 10, int offset = 0, String? language}) async {
  final query = <String, String>{
    'limit': '$limit',
    'offset': '$offset',
  };
  if (language != null && language.isNotEmpty) query['language'] = language;
  final qs = '?${query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';

  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/pdp/history$qs',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return const PdpHistoryResponse(items: [], hasMore: false);
  if (response.statusCode == 200) {
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final items = (json['items'] as List<dynamic>? ?? const [])
        .map((e) => PdpSnapshot.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return PdpHistoryResponse(items: items, hasMore: json['has_more'] as bool? ?? false);
  }
  debugPrint('getPdpHistory error ${response.statusCode}');
  return const PdpHistoryResponse(items: [], hasMore: false);
}

class PdpHistoryResponse {
  final List<PdpSnapshot> items;
  final bool hasMore;

  const PdpHistoryResponse({required this.items, required this.hasMore});
}
