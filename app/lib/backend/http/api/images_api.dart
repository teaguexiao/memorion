import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/env/env.dart';
import 'package:http/http.dart' as http;

/// 云端图片上传 API 响应
class ImageUploadResponse {
  final String id;
  final String gcsPath;
  final String contentType;
  final int sizeBytes;
  final String? description;
  final String? conversationId;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;
  final DateTime updatedAt;

  ImageUploadResponse({
    required this.id,
    required this.gcsPath,
    required this.contentType,
    required this.sizeBytes,
    this.description,
    this.conversationId,
    required this.metadata,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ImageUploadResponse.fromJson(Map<String, dynamic> json) {
    return ImageUploadResponse(
      id: json['id'],
      gcsPath: json['gcs_path'],
      contentType: json['content_type'],
      sizeBytes: json['size_bytes'],
      description: json['description'],
      conversationId: json['conversation_id'],
      metadata: Map<String, dynamic>.from(json['metadata'] ?? {}),
      createdAt: DateTime.parse(json['created_at']),
      updatedAt: DateTime.parse(json['updated_at']),
    );
  }
}

/// 上传 base64 编码的图片到云端
/// 调用 POST /v1/images/base64
Future<ImageUploadResponse?> uploadImageBase64({
  required String base64Data,
  String? conversationId,
  bool generateDescription = true,
  Map<String, dynamic> metadata = const {},
}) async {
  try {
    final apiKey = ApiConfig().apiKey;
    final externalUserId = ApiConfig().externalUserId;

    if (apiKey.isEmpty || externalUserId.isEmpty) {
      debugPrint('[ImagesAPI] API credentials not configured, skipping upload');
      return null;
    }

    final url = '${Env.apiBaseUrl}v1/images/base64';

    final response = await http.post(
      Uri.parse(url),
      headers: {
        'Authorization': apiKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'external_user_id': externalUserId,
        'base64_data': base64Data,
        if (conversationId != null) 'conversation_id': conversationId,
        'generate_description': generateDescription,
        'metadata': metadata,
      }),
    );

    debugPrint('[ImagesAPI] uploadImageBase64 response: ${response.statusCode}');

    if (response.statusCode == 200 || response.statusCode == 201) {
      return ImageUploadResponse.fromJson(jsonDecode(response.body));
    }

    debugPrint('[ImagesAPI] uploadImageBase64 failed: ${response.statusCode} - ${response.body}');
    return null;
  } catch (e) {
    debugPrint('[ImagesAPI] uploadImageBase64 exception: $e');
    return null;
  }
}
