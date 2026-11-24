import 'dart:convert';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/backend/schema/chapter_speaker.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/env/env.dart';

class ChapterSpeakerFailure implements Exception {
  final bool stale;
  const ChapterSpeakerFailure({this.stale = false});
}

/// Separate endpoints keep chapter-only corrections independent of enrollment.
class ChapterSpeakerApi {
  const ChapterSpeakerApi();
  Future<List<Person>> people() => getAllPeople();
  Future<String?> audioUrl(String conversationId) => getConversationAudioSignedUrl(conversationId);
  Future<Map<String, dynamic>> request(
      TimelineChapter chapter, String speakerId, String suffix, String method, Map<String, dynamic> fields) async {
    final date = chapter.date ?? timelineDayKey(chapter.start);
    final response = await makeApiCall(
        url: '${Env.apiBaseUrl}v1/timeline/$date/chapters/speakers$suffix',
        headers: {},
        method: method,
        body: jsonEncode({
          'start': chapter.start.toUtc().toIso8601String(),
          'end': chapter.end.toUtc().toIso8601String(),
          'source_conversation_ids': chapter.sourceConversationIds,
          'revision': chapter.speakerRevision,
          'speaker_id': speakerId,
          ...fields,
        }));
    if (response == null || response.statusCode != 200) {
      throw ChapterSpeakerFailure(stale: response?.statusCode == 409);
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(response.bodyBytes)));
  }

  Future<List<ChapterSpeakerEvidence>> evidence(TimelineChapter chapter, String speakerId) async {
    final data = await request(chapter, speakerId, '/evidence', 'POST', {});
    return (data['evidence'] as List)
        .map((e) => ChapterSpeakerEvidence.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<TimelineChapter> correct(TimelineChapter chapter, String speakerId, String operationId,
      {String? personId, String? name, String? newPersonName, bool isUser = false, bool undo = false}) async {
    final data = await request(chapter, speakerId, '', 'PATCH', {
      'operation_id': operationId,
      if (personId != null) 'person_id': personId,
      if (name != null) 'name': name,
      if (newPersonName != null) 'new_person_name': newPersonName,
      'is_user': isUser,
      'undo': undo,
    });
    final result = TimelineChapter.fromJson(Map<String, dynamic>.from(data['chapter']), date: data['date'] as String?);
    if (result == null) throw const ChapterSpeakerFailure();
    return result;
  }

  Future<String> enroll(TimelineChapter chapter, String speakerId, String operationId, String evidenceId) async {
    final data = await request(chapter, speakerId, '/enroll', 'POST',
        {'operation_id': operationId, 'evidence_id': evidenceId, 'reviewed': true});
    return data['status'] as String;
  }
}
