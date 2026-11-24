import 'package:memorion/backend/preferences.dart';

class Translation {
  String lang;
  String text;

  Translation({
    required this.lang,
    required this.text,
  });

  factory Translation.fromJson(Map<String, dynamic> json) {
    return Translation(
      lang: json['lang'] as String,
      text: json['text'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'lang': lang,
      'text': text,
    };
  }

  static List<Translation> fromJsonList(List<dynamic> jsonList) {
    return jsonList.map((e) => Translation.fromJson(e)).toList();
  }
}

class TranscriptSegment {
  String id;
  late int idx;

  String text;
  String? speaker;
  late int speakerId;
  bool isUser;
  String? personId;
  String? speakerStatus;
  String? speakerAssignmentSource;
  double start;
  double end;
  double? originalStart;
  double? originalEnd;
  String? timestampAxis;
  List<Translation> translations = [];
  bool speechProfileProcessed;

  TranscriptSegment({
    required this.id,
    required this.text,
    required this.speaker,
    required this.isUser,
    required this.personId,
    this.speakerStatus,
    this.speakerAssignmentSource,
    required this.start,
    required this.end,
    this.originalStart,
    this.originalEnd,
    this.timestampAxis,
    required this.translations,
    this.speechProfileProcessed = true,
  }) {
    if (speaker != null && speaker!.contains('_')) {
      speakerId = int.tryParse(speaker!.split('_').last) ?? 0;
    } else {
      speakerId = int.tryParse(speaker ?? '') ?? 0;
    }
  }

  @override
  String toString() {
    return 'TranscriptSegment: {id: $id text: $text, speaker: $speakerId, isUser: $isUser, start: $start, end: $end}';
  }

  String getTimestampString() {
    var start = Duration(seconds: this.start.toInt());
    var end = Duration(seconds: this.end.toInt());
    return '${start.inHours.toString().padLeft(2, '0')}:${(start.inMinutes % 60).toString().padLeft(2, '0')}:${(start.inSeconds % 60).toString().padLeft(2, '0')} - ${end.inHours.toString().padLeft(2, '0')}:${(end.inMinutes % 60).toString().padLeft(2, '0')}:${(end.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  // Factory constructor to create a new Message instance from a map
  factory TranscriptSegment.fromJson(Map<String, dynamic> json) {
    // Reconstruct speaker string from speaker_id if speaker field is missing.
    // The backend stores speaker_id (int) but not speaker (string like "SPEAKER_01").
    String speakerStr;
    if (json['speaker'] != null) {
      speakerStr = json['speaker'] as String;
    } else {
      final sid = json['speaker_id'] ?? 0;
      speakerStr = 'SPEAKER_${sid.toString().padLeft(2, '0')}';
    }
    return TranscriptSegment(
      id: (json['id'] ?? '') as String,
      text: json['text'] as String,
      speaker: speakerStr,
      isUser: (json['is_user'] ?? false) as bool,
      personId: json['person_id'],
      speakerStatus: json['speaker_status'] as String?,
      speakerAssignmentSource: json['speaker_assignment_source'] as String?,
      start: double.tryParse(json['start'].toString()) ?? 0.0,
      end: double.tryParse(json['end'].toString()) ?? 0.0,
      originalStart: double.tryParse(json['original_start'].toString()),
      originalEnd: double.tryParse(json['original_end'].toString()),
      timestampAxis: json['timestamp_axis'] as String?,
      translations: json['translations'] != null ? Translation.fromJsonList(json['translations'] as List<dynamic>) : [],
      speechProfileProcessed: (json['speech_profile_processed'] ?? true) as bool,
    );
  }

  // Method to convert a Message instance into a map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'speaker': speaker,
      'speaker_id': speakerId,
      'is_user': isUser,
      // person_id carries the user's manual speaker tag. fromJson reads it, so
      // toJson MUST write it — otherwise any serialize→deserialize round-trip
      // (local conversation cache in preferences) silently drops the tag and the
      // detail view falls back to "Speaker N".
      'person_id': personId,
      if (speakerStatus != null) 'speaker_status': speakerStatus,
      if (speakerAssignmentSource != null) 'speaker_assignment_source': speakerAssignmentSource,
      'start': start,
      'end': end,
      if (originalStart != null) 'original_start': originalStart,
      if (originalEnd != null) 'original_end': originalEnd,
      if (timestampAxis != null) 'timestamp_axis': timestampAxis,
      'translations': translations.map((t) => t.toJson()).toList(),
    };
  }

  static List<TranscriptSegment> fromJsonList(List<dynamic> jsonList) {
    final List<TranscriptSegment> segments = [];
    for (int i = 0; i < jsonList.length; i++) {
      final segment = TranscriptSegment.fromJson(jsonList[i]);
      segment.idx = i;
      segments.add(segment);
    }
    return segments;
  }

  static List<TranscriptSegment> updateSegments(
      List<TranscriptSegment> segments, List<TranscriptSegment> updateSegments) {
    if (updateSegments.isEmpty) return [];

    if (segments.isEmpty) return updateSegments;

    // Replace existing segments with the same ID
    Map<String, TranscriptSegment> updateSegmentMap = {};
    for (var segment in updateSegments) {
      updateSegmentMap[segment.id] = segment;
    }
    for (int i = 0; i < segments.length; i++) {
      String segmentId = segments[i].id;
      if (updateSegmentMap.containsKey(segmentId)) {
        segments[i] = updateSegmentMap[segmentId]!;
        updateSegmentMap.remove(segmentId);
      }
    }

    // remaining
    return updateSegments.where((segment) => updateSegmentMap.containsKey(segment.id)).toList();
  }

  static combineSegments(
    List<TranscriptSegment> segments,
    List<TranscriptSegment> newSegments, {
    int toAddSeconds = 0,
    double toRemoveSeconds = 0,
  }) {
    if (newSegments.isEmpty) return;

    // Apply time adjustments to new segments
    for (var segment in newSegments) {
      segment.start -= toRemoveSeconds;
      segment.end -= toRemoveSeconds;

      segment.start += toAddSeconds;
      segment.end += toAddSeconds;
    }

    // Keep fine-grained segments from backend without merging
    // This preserves accurate speaker diarization from Soniox STT
    segments.addAll(newSegments);
  }

  static String segmentsAsString(
    List<TranscriptSegment> segments, {
    bool includeTimestamps = false,
  }) {
    String transcript = '';
    var userName = SharedPreferencesUtil().givenName;
    var people = SharedPreferencesUtil().cachedPeople;
    var peopleMap = {for (var p in people) p.id: p.name};

    includeTimestamps = includeTimestamps && TranscriptSegment.canDisplaySeconds(segments);
    for (var segment in segments) {
      var segmentText = segment.text.trim();
      var timestampStr = includeTimestamps ? '[${segment.getTimestampString()}]' : '';
      if (segment.isUser) {
        transcript += '$timestampStr ${userName.isEmpty ? 'User' : userName}: $segmentText ';
      } else {
        String speakerName;
        if (segment.personId != null && peopleMap.containsKey(segment.personId)) {
          speakerName = peopleMap[segment.personId]!;
        } else {
          speakerName = 'Speaker ${segment.speakerId}';
        }
        transcript += '$timestampStr $speakerName: $segmentText ';
      }
      transcript += '\n\n';
    }
    return transcript.trim();
  }

  static bool canDisplaySeconds(List<TranscriptSegment> segments) {
    for (var i = 0; i < segments.length; i++) {
      for (var j = i + 1; j < segments.length; j++) {
        if (segments[i].start > segments[j].end || segments[i].end > segments[j].start) {
          return false;
        }
      }
    }
    return true;
  }
}
