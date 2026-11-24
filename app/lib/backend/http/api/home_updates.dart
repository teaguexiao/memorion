import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/models/home_module_update.dart';

Future<List<HomeModuleUpdate>> getHomeModuleUpdates() async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/home/updates',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return const [];
  if (response.statusCode == 200) {
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return (json['items'] as List<dynamic>? ?? const [])
        .map((e) => HomeModuleUpdate.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
  debugPrint('getHomeModuleUpdates error ${response.statusCode}');
  return const [];
}
