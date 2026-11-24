import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:url_launcher/url_launcher.dart';

class CreateConversationResponse {
  final List<ServerMessage> messages;
  final ServerConversation? conversation;

  CreateConversationResponse({required this.messages, required this.conversation});

  factory CreateConversationResponse.fromJson(Map<String, dynamic> json) {
    // Backend may return conversation wrapped in 'memory' key (legacy) or as
    // a flat dict with 'id' at top level (new /v1/conversations/process).
    ServerConversation? conversation;
    if (json['memory'] != null) {
      conversation = ServerConversation.fromJson(json['memory']);
    } else if (json['id'] != null) {
      conversation = ServerConversation.fromJson(json);
    }
    return CreateConversationResponse(
      messages: ((json['messages'] ?? []) as List<dynamic>).map((message) => ServerMessage.fromJson(message)).toList(),
      conversation: conversation,
    );
  }
}

enum ConversationSource { friend, omi, workflow, openglass, screenpipe, sdcard, audio_upload }

class ConversationExternalData {
  final String text;

  ConversationExternalData({required this.text});

  factory ConversationExternalData.fromJson(Map<String, dynamic> json) => ConversationExternalData(text: json['text'] ?? '');

  Map<String, dynamic> toJson() => {'text': text};
}

enum ConversationPostProcessingStatus { not_started, in_progress, completed, canceled, failed }

enum ConversationPostProcessingModel { fal_whisperx, custom_whisperx }

enum ConversationStatus { in_progress, processing, completed, failed }

class ConversationPostProcessing {
  final ConversationPostProcessingStatus status;
  final ConversationPostProcessingModel? model;
  final String? failReason;

  ConversationPostProcessing({required this.status, required this.model, this.failReason});

  factory ConversationPostProcessing.fromJson(Map<String, dynamic> json) {
    return ConversationPostProcessing(
      status: ConversationPostProcessingStatus.values.asNameMap()[json['status']] ?? ConversationPostProcessingStatus.in_progress,
      model: ConversationPostProcessingModel.values.asNameMap()[json['model']] ?? ConversationPostProcessingModel.fal_whisperx,
      failReason: json['fail_reason'],
    );
  }

  toJson() => {'status': status.toString().split('.').last, 'model': model.toString().split('.').last};
}

enum ServerProcessingConversationStatus {
  capturing('capturing'),
  processing('processing'),
  done('done'),
  unknown('unknown'),
  ;

  final String value;

  const ServerProcessingConversationStatus(this.value);

  static ServerProcessingConversationStatus valuesFromString(String value) {
    return ServerProcessingConversationStatus.values.firstWhereOrNull((e) => e.value == value) ?? ServerProcessingConversationStatus.unknown;
  }
}

enum CaptureMode {
  manual,
  voice,
  auto,
  context;

  static CaptureMode fromString(String? value) {
    switch (value) {
      case 'manual':
        return CaptureMode.manual;
      case 'voice':
        return CaptureMode.voice;
      case 'auto':
        return CaptureMode.auto;
      case 'context':
        return CaptureMode.context;
      default:
        return CaptureMode.manual;
    }
  }

  String get value {
    switch (this) {
      case CaptureMode.manual:
        return 'manual';
      case CaptureMode.voice:
        return 'voice';
      case CaptureMode.auto:
        return 'auto';
      case CaptureMode.context:
        return 'context';
    }
  }
}

enum PhotoSource {
  realtime,
  sdCard;

  static PhotoSource fromString(String? value) {
    switch (value) {
      case 'realtime':
        return PhotoSource.realtime;
      case 'sd_card':
        return PhotoSource.sdCard;
      default:
        return PhotoSource.realtime;
    }
  }

  String get value {
    switch (this) {
      case PhotoSource.realtime:
        return 'realtime';
      case PhotoSource.sdCard:
        return 'sd_card';
    }
  }
}

class ConversationPhoto {
  String id;
  final String base64;
  String? description;
  final DateTime createdAt;
  bool discarded;
  // New fields for enhanced photo metadata
  final CaptureMode captureMode;
  final String? resolution;
  final PhotoSource source;
  final DateTime? localTimestamp;
  // Local file path for lazy loading from persistent storage
  final String? localPath;

  ConversationPhoto({
    required this.id,
    required this.base64,
    this.description,
    required this.createdAt,
    this.discarded = false,
    this.captureMode = CaptureMode.manual,
    this.resolution,
    this.source = PhotoSource.realtime,
    this.localTimestamp,
    this.localPath,
  });

  /// Factory constructor for creating a ConversationPhoto from local storage
  /// Used when restoring persisted photos after app restart
  factory ConversationPhoto.fromLocalStorage({
    required String id,
    required String localPath,
    required DateTime createdAt,
  }) {
    return ConversationPhoto(
      id: id,
      base64: '', // Empty - will be lazily loaded from localPath
      createdAt: createdAt,
      localPath: localPath,
      source: PhotoSource.realtime,
    );
  }

  factory ConversationPhoto.fromJson(Map<String, dynamic> json) {
    return ConversationPhoto(
      id: json['id'] ?? '',
      base64: json['base64'] ?? '',
      description: json['description'],
      createdAt: json['created_at'] != null ? DateTime.parse(json['created_at']).toLocal() : DateTime.now(),
      discarded: json['discarded'] ?? false,
      captureMode: CaptureMode.fromString(json['capture_mode']),
      resolution: json['resolution'],
      source: PhotoSource.fromString(json['source']),
      localTimestamp: json['local_timestamp'] != null ? DateTime.parse(json['local_timestamp']).toLocal() : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'base64': base64,
        'description': description,
        'created_at': createdAt.toUtc().toIso8601String(),
        'discarded': discarded,
        'capture_mode': captureMode.value,
        'resolution': resolution,
        'source': source.value,
        'local_timestamp': localTimestamp?.toUtc().toIso8601String(),
      };
}

class ServerConversation {
  final String id;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  final Structured structured;
  final List<TranscriptSegment> transcriptSegments;
  final List<ConversationPhoto> photos;

  final List<AppResponse> appResults;
  final ConversationSource? source;
  final String? language; // applies to device capture only

  final ConversationExternalData? externalIntegration;

  ConversationStatus status;
  bool discarded;
  final bool deleted;
  bool pinned;

  // URL to audio recording in cloud storage (for playback when local audio is unavailable)
  // Deprecated: Use audioPath with getAudioSignedUrl API instead
  final String? audioUrl;

  // GCS path to audio recording (use with /audio-url endpoint to get signed URL)
  final String? audioPath;

  // local label
  bool isNew = false;

  ServerConversation({
    required this.id,
    required this.createdAt,
    required this.structured,
    this.startedAt,
    this.finishedAt,
    this.transcriptSegments = const [],
    this.appResults = const [],
    this.photos = const [],
    this.discarded = false,
    this.deleted = false,
    this.pinned = false,
    this.source,
    this.language,
    this.externalIntegration,
    this.status = ConversationStatus.completed,
    this.audioUrl,
    this.audioPath,
  });

  factory ServerConversation.fromJson(Map<String, dynamic> json) {
    return ServerConversation(
      id: json['id'],
      createdAt: DateTime.parse(json['created_at']).toLocal(),
      structured: Structured.fromJson(json['structured']),
      startedAt: json['started_at'] != null ? DateTime.parse(json['started_at']).toLocal() : null,
      finishedAt: json['finished_at'] != null ? DateTime.parse(json['finished_at']).toLocal() : null,
      transcriptSegments: ((json['transcript_segments'] ?? []) as List<dynamic>).map((segment) => TranscriptSegment.fromJson(segment)).toList(),
      appResults: ((json['apps_results'] ?? []) as List<dynamic>).map((result) => AppResponse.fromJson(result)).toList(),
      photos: json['photos'] != null ? ((json['photos'] ?? []) as List<dynamic>).map((photo) => ConversationPhoto.fromJson(photo)).toList() : [],
      discarded: json['discarded'] ?? false,
      pinned: json['pinned'] ?? false,
      source: json['source'] != null ? ConversationSource.values.asNameMap()[json['source']] : ConversationSource.omi,
      language: json['language'],
      deleted: json['deleted'] ?? false,
      externalIntegration: json['external_data'] != null ? ConversationExternalData.fromJson(json['external_data']) : null,
      status: json['status'] != null ? ConversationStatus.values.asNameMap()[json['status']] ?? ConversationStatus.completed : ConversationStatus.completed,
      audioUrl: json['audio_url'],
      audioPath: json['audio_path'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'created_at': createdAt.toUtc().toIso8601String(),
      'structured': structured.toJson(),
      'started_at': startedAt?.toUtc().toIso8601String(),
      'finished_at': finishedAt?.toUtc().toIso8601String(),
      'transcript_segments': transcriptSegments.map((segment) => segment.toJson()).toList(),
      'plugins_results': appResults.map((result) => result.toJson()).toList(),
      'photos': photos.map((photo) => photo.toJson()).toList(),
      'discarded': discarded,
      'deleted': deleted,
      'source': source?.toString(),
      'language': language,
      'external_data': externalIntegration?.toJson(),
      'status': status.toString().split('.').last,
      'audio_url': audioUrl,
      'audio_path': audioPath,
    };
  }

  int unassignedSegmentsLength() {
    return transcriptSegments.where((element) => (element.personId == null && !element.isUser)).length;
  }

  int speakerWithMostUnassignedSegments() {
    var speakers = transcriptSegments.where((element) => element.personId == null && !element.isUser).map((e) => e.speakerId).toList();
    if (speakers.isEmpty) return -1;
    var segmentsBySpeakers = groupBy(speakers, (e) => e).entries.reduce((a, b) => a.value.length > b.value.length ? a : b).key;
    return segmentsBySpeakers;
  }

  int firstSegmentIndexForSpeaker(int speakerId) {
    return transcriptSegments.indexWhere((element) => element.speakerId == speakerId);
  }

  String getTag() {
    if (source == ConversationSource.screenpipe) return 'Screenpipe';
    if (source == ConversationSource.openglass) return 'Memorion Earpod';
    if (source == ConversationSource.sdcard) return 'SD Card';
    if (discarded) return 'Discarded';
    return structured.category.substring(0, 1).toUpperCase() + structured.category.substring(1);
  }

  Color getTagTextColor() {
    if (source == ConversationSource.screenpipe) return Colors.deepPurple;
    return Colors.white;
  }

  Color getTagColor() {
    if (source == ConversationSource.screenpipe) return Colors.white;
    return const Color(0xFF35343B);
  }

  VoidCallback? onTagPressed(BuildContext context) {
    if (source == ConversationSource.screenpipe) return () => launchUrl(Uri.parse('https://screenpi.pe/'));
    return null;
  }

  String getTranscript({int? maxCount, bool generate = false}) {
    var transcript = TranscriptSegment.segmentsAsString(transcriptSegments, includeTimestamps: true);
    if (maxCount != null) transcript = transcript.substring(0, min(maxCount, transcript.length));
    try {
      return utf8.decode(transcript.codeUnits);
    } catch (e) {
      return transcript;
    }
  }

  /// Calculates the conversation duration in seconds based on transcript segments
  ///
  /// Returns the span from the earliest segment start to the latest segment end.
  /// This handles cases where backend timestamp normalization may not start exactly at 0.
  int getDurationInSeconds() {
    if (transcriptSegments.isEmpty) return 0;

    double minStart = double.infinity;
    double maxEnd = double.negativeInfinity;

    for (var segment in transcriptSegments) {
      if (segment.start < minStart) minStart = segment.start;
      if (segment.end > maxEnd) maxEnd = segment.end;
    }

    // If no valid segments found, return 0
    if (minStart == double.infinity || maxEnd == double.negativeInfinity) {
      return 0;
    }

    // Return the actual speech span (end - start)
    final duration = (maxEnd - minStart).toInt();
    return duration > 0 ? duration : 0;
  }
}

class SyncLocalFilesResponse {
  List<String> newConversationIds = [];
  List<String> updatedConversationIds = [];

  SyncLocalFilesResponse({
    required this.newConversationIds,
    required this.updatedConversationIds,
  });

  factory SyncLocalFilesResponse.fromJson(Map<String, dynamic> json) {
    return SyncLocalFilesResponse(
      newConversationIds: ((json['new_memories'] ?? []) as List<dynamic>).map((val) => val.toString()).toList(),
      updatedConversationIds: ((json['updated_memories'] ?? []) as List<dynamic>).map((val) => val.toString()).toList(),
    );
  }
}

enum SyncedConversationType { newConversation, updatedConversation }

class SyncedConversationPointer {
  final SyncedConversationType type;
  final int index;
  final DateTime key;
  final ServerConversation conversation;

  SyncedConversationPointer({required this.type, required this.index, required this.key, required this.conversation});

  factory SyncedConversationPointer.fromJson(Map<String, dynamic> json) {
    return SyncedConversationPointer(
      type: SyncedConversationType.values.asNameMap()[json['type']] ?? SyncedConversationType.newConversation,
      index: json['index'],
      key: DateTime.parse(json['key']).toLocal(),
      conversation: ServerConversation.fromJson(json['memory']),
    );
  }

  SyncedConversationPointer copyWith({SyncedConversationType? type, int? index, DateTime? key, ServerConversation? conversation}) {
    return SyncedConversationPointer(
      type: type ?? this.type,
      index: index ?? this.index,
      key: key ?? this.key,
      conversation: conversation ?? this.conversation,
    );
  }
}
