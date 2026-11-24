import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/env/env.dart';
import 'package:http/http.dart' as http;

class CreateTalkSessionResponse {
  final String sessionId;
  final String websocketUrl;
  final String sttService;
  final String language;

  CreateTalkSessionResponse({
    required this.sessionId,
    required this.websocketUrl,
    required this.sttService,
    required this.language,
  });

  factory CreateTalkSessionResponse.fromJson(Map<String, dynamic> json) {
    return CreateTalkSessionResponse(
      sessionId: json['session_id'],
      websocketUrl: json['websocket_url'],
      sttService: json['stt_service'],
      language: json['language'],
    );
  }
}

/// Create a talk session via POST /v1/talk
/// Returns session_id and websocket_url for real-time audio streaming
Future<CreateTalkSessionResponse?> createTalkSession({
  String language = 'zh',
  int sampleRate = 16000,
  String codec = 'pcm16',
  String cleaningLevel = 'standard',
  String outputFormat = 'paragraph',
}) async {
  try {
    final apiKey = ApiConfig().apiKey;
    final externalUserId = ApiConfig().externalUserId;

    final url = '${Env.apiBaseUrl}v1/talk?external_user_id=$externalUserId&api_key=$apiKey';

    final response = await http.post(
      Uri.parse(url),
      headers: {
        'Authorization': apiKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'language': language,
        'sample_rate': sampleRate,
        'codec': codec,
        'cleaning_level': cleaningLevel,
        'output_format': outputFormat,
      }),
    );

    debugPrint('createTalkSession response: ${response.statusCode} - ${response.body}');

    if (response.statusCode == 200 || response.statusCode == 201) {
      return CreateTalkSessionResponse.fromJson(jsonDecode(response.body));
    }

    debugPrint('createTalkSession failed: ${response.statusCode}');
    return null;
  } catch (e) {
    debugPrint('createTalkSession exception: $e');
    return null;
  }
}
