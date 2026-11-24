import 'package:flutter/material.dart';

final List<Color> speakerColors = [
  Colors.white
  // Colors.red,
  // Colors.blue,
  // Colors.green,
  // Colors.yellow,
  // Colors.purple,
  // Colors.orange,
  // Colors.pink,
  // Colors.teal,
  // Colors.cyan,
  // Colors.amber,
];

final List<String> speakerImagePath = [
  'assets/images/speaker_1_icon.png',
  // 'assets/images/speaker_1_red.png',
  // 'assets/images/speaker_1_blue.png',
  // 'assets/images/speaker_1_green.png',
  // 'assets/images/speaker_1_yellow.png',
  // 'assets/images/speaker_1_purple.png',
  // 'assets/images/speaker_1_orange.png',
  // 'assets/images/speaker_1_pink.png',
  // 'assets/images/speaker_1_teal.png',
  // 'assets/images/speaker_1_cyan.png',
  // 'assets/images/speaker_1_amber.png',
];

class Person {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  /// 样本的**签名 URL**。列表接口刻意不返回它（每人一次 GCS 列举 + 逐 blob 签名，
  /// 833 人实测 15.65s vs 2.38s），所以列表页拿到的 Person 这里是空的 —— 要判断
  /// 「这个人有几段样本」用 [speechSamplesCount]，别用 `speechSamples!.length`。
  /// 真正的 URL 由 `PeopleProvider.loadPersonSamples` 在打开详情时按人拉。
  final List<String>? speechSamples;

  /// 样本条数。**与 [speechSamples] 是否已加载无关**，列表接口总会返回。
  final int speechSamplesCount;
  final double speechSamplesDuration;
  final int? colorIdx;

  Person({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.speechSamples,
    int? speechSamplesCount,
    this.speechSamplesDuration = 0.0,
    this.colorIdx,
  }) : speechSamplesCount = speechSamplesCount ?? (speechSamples?.length ?? 0);

  factory Person.fromJson(Map<String, dynamic> json) {
    final samples = json['speech_samples'] != null ? List<String>.from(json['speech_samples']) : <String>[];
    return Person(
      id: json['id'],
      name: json['name'],
      createdAt: DateTime.parse(json['created_at']).toLocal(),
      updatedAt: DateTime.parse(json['updated_at']).toLocal(),
      speechSamples: samples,
      // 后端没给（旧版本后端、或 SharedPreferences 里 2026-08-12 之前写的缓存）就退回
      // 数已有的 URL —— 那时候列表是带样本拉的，长度就是条数。
      speechSamplesCount: json['speech_samples_count'] ?? samples.length,
      speechSamplesDuration: (json['speech_samples_duration'] ?? 0.0).toDouble(),
      colorIdx: json['color_idx'] ?? json['id'].hashCode % speakerColors.length,
    );
  }

  /// 只用来改条数。URL 刻意不在这里换：签名 URL 只活 60 分钟，混进 `cachedPeople`
  /// 落盘后冷启动拿到的是一批过期链接。URL 由 `PeopleProvider.samplesUrl` 单独持有。
  Person withSampleCount(int count) => Person(
        id: id,
        name: name,
        createdAt: createdAt,
        updatedAt: updatedAt,
        speechSamples: const [],
        speechSamplesCount: count,
        speechSamplesDuration: speechSamplesDuration,
        colorIdx: colorIdx,
      );

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'speech_samples': speechSamples ?? [],
      // 必须落盘：缓存里只有 speech_samples（列表版为空）的话，冷启动整页会显示
      // 「暂无样本」。
      'speech_samples_count': speechSamplesCount,
      'speech_samples_duration': speechSamplesDuration,
      'color_idx': colorIdx,
    };
  }

  /// Returns a human-readable voice profile status string.
  String get voiceProfileStatus {
    if (speechSamplesDuration <= 0) return 'No voice data';
    if (speechSamplesDuration < 30) return '${speechSamplesDuration.toInt()}s / 30s recommended';
    return '${speechSamplesDuration.toInt()}s collected';
  }
}
