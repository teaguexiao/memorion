import 'package:flutter/material.dart';

/// 与后端 backend/models/mood_quote.py 的 DailyMoodQuote schema 一一对应。
/// 情绪页「每日一语 / 今日情绪寄语」：基于当日真实情绪数据生成的安抚寄语。
///
/// 注意：[bgColor] / [textColor] 是后端按情绪映射算好的 hex 字符串，前端直接用，
/// **不要** 在前端再做 emotion -> color 映射。
class DailyMoodQuote {
  final String date; // YYYY-MM-DD
  final String dominantEmotion; // happy / angry / sad / surprised / calm
  final Map<String, int> emotionDistribution; // {happy:5, sad:2, ...}
  final String bgColorHex; // 后端下发，如 "#FFF3D0"
  final String textColorHex; // 后端下发，如 "#5C4A00"
  final String title; // LLM 生成的短标题
  final String body; // LLM 生成的寄语正文（含 \n 换行）
  final String language; // 'zh' | 'en'
  final bool isFallback; // 是否兜底文案
  final String? createdAt;

  DailyMoodQuote({
    required this.date,
    required this.dominantEmotion,
    required this.emotionDistribution,
    required this.bgColorHex,
    required this.textColorHex,
    required this.title,
    required this.body,
    required this.language,
    required this.isFallback,
    this.createdAt,
  });

  /// 后端 bg_color 直接解析为 Color（含 alpha 补全）。
  Color get bgColor => colorFromHex(bgColorHex, fallback: const Color(0xFFF5F0E6));

  /// 后端 text_color 直接解析为 Color（含 alpha 补全）。
  Color get textColor => colorFromHex(textColorHex, fallback: const Color(0xFF4A4540));

  factory DailyMoodQuote.fromJson(Map<String, dynamic> json) {
    final rawDist = json['emotion_distribution'];
    final dist = <String, int>{};
    if (rawDist is Map) {
      rawDist.forEach((key, value) {
        if (key is String) {
          dist[key] = (value as num?)?.toInt() ?? 0;
        }
      });
    }
    return DailyMoodQuote(
      date: json['date'] as String? ?? '',
      dominantEmotion: json['dominant_emotion'] as String? ?? 'calm',
      emotionDistribution: dist,
      bgColorHex: json['bg_color'] as String? ?? '#F5F0E6',
      textColorHex: json['text_color'] as String? ?? '#4A4540',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      language: json['language'] as String? ?? 'zh',
      isFallback: json['is_fallback'] as bool? ?? false,
      createdAt: json['created_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'date': date,
        'dominant_emotion': dominantEmotion,
        'emotion_distribution': emotionDistribution,
        'bg_color': bgColorHex,
        'text_color': textColorHex,
        'title': title,
        'body': body,
        'language': language,
        'is_fallback': isFallback,
        'created_at': createdAt,
      };
}

/// 把 hex 字符串（如 "#FFF3D0" / "FFF3D0" / "#FFFFF3D0"）转成 [Color]。
/// 6 位（RGB）自动补 0xFF alpha；解析失败时返回 [fallback]。
Color colorFromHex(String? hex, {Color fallback = const Color(0xFFF5F0E6)}) {
  if (hex == null || hex.isEmpty) return fallback;
  var value = hex.trim().replaceFirst('#', '').toUpperCase();
  if (value.length == 6) {
    value = 'FF$value'; // 补全 alpha -> 0xFFRRGGBB
  }
  if (value.length != 8) return fallback;
  final parsed = int.tryParse(value, radix: 16);
  if (parsed == null) return fallback;
  return Color(parsed);
}
