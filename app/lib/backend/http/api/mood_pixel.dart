import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/models/mood_pixel_state.dart';

Future<MoodPixelState?> getMoodPixelState() async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/mood/pixel-state',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  if (response.statusCode == 200) {
    return MoodPixelState.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  }
  debugPrint('getMoodPixelState error ${response.statusCode}');
  return null;
}

Future<MoodPixelState?> updateMoodPixelState(MoodPixelState state) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/mood/pixel-state',
    headers: {},
    method: 'PUT',
    body: jsonEncode(state.toUpdatePayload()),
  );
  if (response == null) return null;
  if (response.statusCode == 200) {
    return MoodPixelState.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  }
  debugPrint('updateMoodPixelState error ${response.statusCode}');
  return null;
}

Future<List<MoodPixelState>> getAllMoodPixelStates() async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/mood/pixel-states/all',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return [];
  if (response.statusCode == 200) {
    final List<dynamic> jsonList = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    return jsonList.map((json) => MoodPixelState.fromJson(json as Map<String, dynamic>)).toList();
  }
  debugPrint('getAllMoodPixelStates error ${response.statusCode}');
  return [];
}
