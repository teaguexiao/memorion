import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/pages/today_chapters/transcript_page.dart';
import 'package:memorion/pages/today_chapters/widgets/transcript_common.dart';
import 'package:memorion/providers/conversation_audio_provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/utils/audio/transcript_audio_alignment.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 完整原文页：点一句从这句开始播。
///
/// 播放位置只认后端给的对齐（按段落 id），不用段落上显示的时间；对不齐的老录音不提供可点样式，
/// 被 VAD 裁掉声音的那句要说清楚，而不是点了没反应。
class _Audio extends ChangeNotifier implements ConversationAudioProvider {
  _Audio(this._alignment);
  final TranscriptAudioAlignment? _alignment;
  final played = <String>[];
  @override
  final ValueNotifier<String?> currentSegmentId = ValueNotifier<String?>(null);

  @override
  TranscriptAudioAlignment? get alignment => _alignment;
  @override
  bool get canPlaySegments => _alignment != null;
  @override
  Future<SegmentPlayback> playSegment(String segmentId) async {
    played.add(segmentId);
    final span = _alignment?.spanOf(segmentId);
    if (span == null) return SegmentPlayback.unavailable;
    return span.hasAudio ? SegmentPlayback.started : SegmentPlayback.noAudio;
  }

  @override
  Future<void> loadConversation(String conversationId) async {}
  @override
  void clear({bool notify = true}) {}
  @override
  bool get hasAudio => true;
  @override
  bool get isPlaying => false;
  @override
  bool get isLoading => false;
  @override
  bool get isDownloadable => false;
  @override
  bool get isDownloading => false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => const Duration(minutes: 55);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TranscriptSegment _segment(String id, String text, double start) => TranscriptSegment(
      id: id,
      text: text,
      speaker: 'SPEAKER_00',
      isUser: false,
      personId: null,
      start: start,
      end: start + 5,
      translations: const [],
    );

ServerConversation _conversation() => ServerConversation(
      id: 'conv',
      createdAt: DateTime(2026, 10, 27, 14),
      startedAt: DateTime(2026, 10, 27, 14),
      finishedAt: DateTime(2026, 10, 27, 14, 15),
      structured: Structured('标题', ''),
      transcriptSegments: [
        _segment('a', 'First line', 0),
        _segment('b', 'Second line', 60),
        _segment('cut', 'Line whose audio was trimmed', 120),
      ],
    );

// 显示时间是 0:00 / 1:00 / 2:00，而音频里它们在第 22 分钟之后——实时录音整场会话裁掉静音的真实形态。
final _aligned = TranscriptAudioAlignment(const [
  AudioSpan('a', 1368.2, 1373.2, hasAudio: true),
  AudioSpan('b', 1401.0, 1406.0, hasAudio: true),
  AudioSpan('cut', 1406.0, 1406.0, hasAudio: false),
]);

Future<_Audio> _pump(WidgetTester tester, TranscriptAudioAlignment? alignment) async {
  final audio = _Audio(alignment);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => ChangeNotifierProvider(
      create: (_) => UndoDeleteController(),
      child: UndoDeleteHost(child: child!),
    ),
    home: ChangeNotifierProvider<ConversationAudioProvider>.value(
      value: audio,
      child: TranscriptPage(conversation: _conversation()),
    ),
  ));
  await tester.pump();
  return audio;
}

TranscriptSegmentRow _row(WidgetTester tester, String text) =>
    tester.widget(find.ancestor(of: find.text(text), matching: find.byType(TranscriptSegmentRow)));

Finder _rowPlayIcons() =>
    find.descendant(of: find.byType(TranscriptSegmentRow), matching: find.byIcon(Icons.play_arrow_rounded));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  testWidgets('tapping a line plays that segment by id', (tester) async {
    final audio = await _pump(tester, _aligned);
    await tester.tap(find.text('Second line'));
    await tester.pump();
    expect(audio.played, ['b']);
    expect(_rowPlayIcons(), findsNWidgets(2), reason: 'the trimmed line gets no ▶');
  });

  testWidgets('a line whose audio VAD removed says so instead of doing nothing', (tester) async {
    final audio = await _pump(tester, _aligned);
    await tester.tap(find.text('Line whose audio was trimmed'));
    await tester.pump();
    expect(audio.played, ['cut']);
    expect(find.text('No audio was kept for this line'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the line being played is highlighted, and only that one', (tester) async {
    final audio = await _pump(tester, _aligned);
    expect(_row(tester, 'Second line').highlighted, isFalse);
    audio.currentSegmentId.value = 'b';
    await tester.pump();
    expect(_row(tester, 'Second line').highlighted, isTrue);
    expect(_row(tester, 'First line').highlighted, isFalse);
  });

  testWidgets('recordings that cannot be aligned offer no tap-to-play', (tester) async {
    final audio = await _pump(tester, null);
    await tester.tap(find.text('Second line'));
    await tester.pump();
    expect(audio.played, isEmpty);
    expect(_rowPlayIcons(), findsNothing);
  });
}
