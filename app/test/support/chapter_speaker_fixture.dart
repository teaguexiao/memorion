// Deterministic demo data for widget tests and the opt-in simulator entrypoint.
// No production storage, recognition model, or account is used here.
import 'package:memorion/backend/http/api/chapter_speakers.dart';
import 'package:memorion/backend/schema/chapter_speaker.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';

const speakerEvidenceIds = [
  'e0000000000000001',
  'e0000000000000002',
  'e0000000000000003',
  'e0000000000000004',
  'e0000000000000005'
];
const speakerQuotes = [
  '固件还有两个兼容问题没修完，按原计划发布风险太大。',
  '推迟会影响已经约好的媒体评测。',
  '先跟媒体说一声，评测改到下周。',
  '延期后也要留出回归测试的时间。',
  '我周三前给出修复结果。'
];
TimelineChapter speakerFixture({int count = 3}) {
  final speakers = List.generate(
      count,
      (i) => ChapterSpeaker(
          id: 's$i',
          isUser: i == 2,
          personId: i == 0 ? 'demo-tao' : null,
          name: i == 0 ? '涛哥' : null,
          status: i == 0 || i == 2 ? 'confirmed' : 'unknown',
          number: i == 1 ? 1 : i - 1,
          evidenceIds: [speakerEvidenceIds[i]]));
  final raw = count == 0
      ? '这段记录围绕发布时间展开，兼容问题尚未修复，媒体评测也需要重新安排。'
      : List.generate(
          count,
          (i) => '[[speaker:${speakerEvidenceIds[i]}]]${[
                '说固件还有两个兼容问题没修完，按原计划发布风险太大。',
                '担心推迟会影响已经约好的媒体评测。',
                '提议先跟媒体沟通，把评测改到下周，负责联系媒体。',
                '提醒延期后也要留出回归测试的时间。',
                '表示周三前给出修复结果。'
              ][i]}').join(' ');
  return TimelineChapter(
      date: '2026-10-24',
      start: DateTime(2026, 10, 24, 9, 30),
      end: DateTime(2026, 10, 24, 9, 50),
      durationSeconds: 1200,
      speechSeconds: 1050,
      sourceConversationIds: const ['speaker-preview-source'],
      title: '发布日期往后挪一周',
      overview: raw,
      emoji: '🗓️',
      firstPersonObservation: '',
      rolledUp: true,
      speakerRevision: 'fixture-0',
      speakerDisplay: ChapterSpeakerDisplay(
          speakers: speakers, mentions: {for (var i = 0; i < count; i++) speakerEvidenceIds[i]: 's$i'}));
}

ServerConversation speakerSource() => ServerConversation(
    id: 'speaker-preview-source',
    createdAt: DateTime(2026, 10, 24, 9, 30),
    startedAt: DateTime(2026, 10, 24, 9, 30),
    finishedAt: DateTime(2026, 10, 24, 9, 50),
    structured: Structured('演示录音', '仅用于界面测试的合成内容。', highlights: const ['先跟媒体说一声，评测改到下周。'])
      ..actionItems = [ActionItem('联系媒体，把评测改到下周')]);

class FixtureSpeakerApi extends ChapterSpeakerApi {
  int corrections = 0, enrollments = 0, undos = 0, evidenceCalls = 0;
  bool failEvidence = false, failCorrection = false, failEnrollment = false, playable = false;
  List<ChapterSpeakerEvidence>? evidenceOverride;
  String? enrolledEvidenceId, createdName;
  TimelineChapter? previous;
  Future<void>? undoGate;
  String? requiredEvidenceRevision, correctionRevision;
  bool alwaysStaleEvidence = false;
  final evidenceRevisions = <String?>[];
  @override
  Future<List<Person>> people() async =>
      [Person(id: 'demo-tao', name: '涛哥', createdAt: DateTime(2026), updatedAt: DateTime(2026))];
  @override
  Future<List<ChapterSpeakerEvidence>> evidence(TimelineChapter chapter, String speakerId) async {
    evidenceCalls++;
    evidenceRevisions.add(chapter.speakerRevision);
    if (alwaysStaleEvidence ||
        (requiredEvidenceRevision != null && chapter.speakerRevision != requiredEvidenceRevision)) {
      throw const ChapterSpeakerFailure(stale: true);
    }
    if (failEvidence) throw const ChapterSpeakerFailure();
    if (evidenceOverride != null) return evidenceOverride!;
    return chapter.speakerDisplay!.speakers
        .firstWhere((s) => s.id == speakerId)
        .evidenceIds
        .map((id) => ChapterSpeakerEvidence(
            id: id,
            conversationId: 'preview-${speakerEvidenceIds.indexOf(id)}',
            text: speakerQuotes[speakerEvidenceIds.indexOf(id)],
            audioStart: playable ? 0 : null,
            audioEnd: playable ? [5.827, 3.417, 3.660, 3.371, 2.639][speakerEvidenceIds.indexOf(id)] : null))
        .toList();
  }

  @override
  Future<String?> audioUrl(String id) async => 'http://127.0.0.1:18761/$id.wav';
  @override
  Future<TimelineChapter> correct(TimelineChapter chapter, String speakerId, String operationId,
      {String? personId, String? name, String? newPersonName, bool isUser = false, bool undo = false}) async {
    if (failCorrection) throw const ChapterSpeakerFailure();
    if (undo) {
      undos++;
      await undoGate;
      return previous!;
    }
    corrections++;
    correctionRevision = chapter.speakerRevision;
    if (newPersonName != null) {
      createdName = newPersonName;
      personId = 'created-person';
      name = newPersonName;
    }
    previous = chapter;
    return TimelineChapter.fromJson({
      ...chapter.toJson(),
      'speaker_revision': 'fixture-$corrections',
      'speaker_display': {
        ...chapter.speakerDisplay!.toJson(),
        'speakers': chapter.speakerDisplay!.speakers
            .map((s) => s.id != speakerId
                ? s.toJson()
                : {
                    ...s.toJson(),
                    'person_id': personId,
                    'name': personId == 'demo-tao' ? '涛哥' : name,
                    'is_user': isUser,
                    'status': isUser || personId != null || name != null ? 'confirmed' : 'unknown'
                  })
            .toList()
      }
    })!;
  }

  @override
  Future<String> enroll(TimelineChapter chapter, String speakerId, String operationId, String evidenceId) async {
    enrolledEvidenceId = evidenceId;
    enrollments++;
    if (failEnrollment) throw const ChapterSpeakerFailure();
    return 'enrolled';
  }
}
