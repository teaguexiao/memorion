import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/pages/today_chapters/widgets/audio_scrubber.dart';

/// 回听进度条的手感约定（完整原文页底部）。
///
/// 轨道 200pt、录音 55 分钟（上传/手表录音的中位数）：贴着条拖每 1pt 是 16.5 秒。
/// 以前的实现每帧都 seek、手势区只有 20pt 高、没有精细档，「拖到第 10 分钟」做不到。
const double _track = 200;
const Duration _duration = Duration(minutes: 55);
const double _coarse = 3300 / _track; // 16.5 s/pt

class _Harness {
  final seeks = <Duration>[];
  final scrubs = <Duration?>[];
  final haptics = <String>[];
  final position = ValueNotifier<Duration>(Duration.zero);
}

Future<_Harness> _pump(WidgetTester tester, {bool enabled = true, Duration position = Duration.zero}) async {
  final h = _Harness()..position.value = position;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') h.haptics.add('${call.arguments}');
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: _track + 2 * kScrubberInset,
          height: 60,
          child: ValueListenableBuilder<Duration>(
            valueListenable: h.position,
            builder: (context, position, _) => AudioScrubber(
              position: position,
              duration: _duration,
              enabled: enabled,
              onSeek: h.seeks.add,
              onScrub: h.scrubs.add,
              previewAt: (at) => at.inSeconds >= 540 && at.inSeconds < 660 ? '小王：那就十点开始吧' : null,
            ),
          ),
        ),
      ),
    ),
  ));
  return h;
}

/// 轨道上距左端 [x] pt、竖直方向在条上 [y]（负数 = 条的上方）的全局坐标。
Offset _at(WidgetTester tester, double x, [double y = 30]) =>
    tester.getTopLeft(find.byType(AudioScrubber)) + Offset(kScrubberInset + x, y);

double _seconds(Duration d) => d.inMilliseconds / 1000;

void main() {
  testWidgets('seeks once, on release — never while the finger is moving', (tester) async {
    final h = await _pump(tester);
    final gesture = await tester.startGesture(_at(tester, 100)); // 27:30
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-10, 0));
      await tester.pump();
    }
    expect(h.seeks, isEmpty);
    expect(_seconds(h.scrubs.last!), closeTo(1650 - 60 * _coarse, 0.01), reason: 'thumb follows the finger');
    await gesture.up();
    await tester.pump();
    expect(h.seeks.length, 1);
    expect(_seconds(h.seeks.single), closeTo(660, 0.01));
    expect(h.scrubs.last, isNull, reason: 'host label goes back to the player position');
  });

  testWidgets('lifting the finger above the bar scrubs at one second per point', (tester) async {
    final h = await _pump(tester);
    final gesture = await tester.startGesture(_at(tester, 0)); // grab the thumb at 0:00
    await gesture.moveBy(const Offset(0, -170)); // 140pt above the bar: finest
    await tester.pump();
    expect(find.text('Fine scrubbing'), findsOneWidget);
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(_seconds(h.seeks.single), closeTo(60, 0.01), reason: 'on the bar the same 60pt would be 16.5 minutes');
    expect(h.haptics, contains('HapticFeedbackType.lightImpact'), reason: 'entering a finer level is felt');
  });

  testWidgets('the middle level sits between coarse and fine', (tester) async {
    final h = await _pump(tester);
    final gesture = await tester.startGesture(_at(tester, 0));
    await gesture.moveBy(const Offset(0, -110)); // 80pt above the bar
    await tester.pump();
    expect(find.text('Slow scrubbing'), findsOneWidget);
    await gesture.moveBy(const Offset(50, 0));
    await gesture.up();
    await tester.pump();
    final rate = _seconds(h.seeks.single) / 50;
    expect(rate, lessThan(_coarse));
    expect(rate, greaterThan(1.0));
  });

  testWidgets('player progress during a drag does not pull the thumb back', (tester) async {
    final h = await _pump(tester);
    final gesture = await tester.startGesture(_at(tester, 100));
    await gesture.moveBy(const Offset(-10, 0));
    await tester.pump();
    h.position.value = const Duration(minutes: 50); // playing on while the user drags
    await tester.pump();
    await gesture.moveBy(const Offset(-10, 0));
    await gesture.up();
    await tester.pump();
    expect(_seconds(h.seeks.single), closeTo(1650 - 20 * _coarse, 0.01));
  });

  testWidgets('tap jumps to the tapped point; a tap on the thumb stays put', (tester) async {
    final h = await _pump(tester, position: const Duration(minutes: 10));
    await tester.tapAt(_at(tester, 150)); // far from the 10:00 thumb (at 36pt)
    expect(_seconds(h.seeks.single), closeTo(2475, 0.01));

    h.seeks.clear();
    h.position.value = const Duration(minutes: 10);
    await tester.pump();
    await tester.tapAt(_at(tester, 600 / _coarse + 3)); // just beside the 10:00 thumb
    expect(h.seeks, isEmpty);
  });

  testWidgets('the whole 60pt bar height is touchable', (tester) async {
    final h = await _pump(tester);
    await tester.tapAt(_at(tester, 100, 3)); // top edge, 27pt above the 4pt track
    expect(_seconds(h.seeks.single), closeTo(1650, 0.01));
  });

  testWidgets('bubble shows the time and what is being said there', (tester) async {
    final h = await _pump(tester);
    final gesture = await tester.startGesture(_at(tester, 600 / _coarse + 30));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    expect(find.textContaining('10:00', findRichText: true), findsOneWidget);
    expect(find.text('小王：那就十点开始吧'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(find.text('小王：那就十点开始吧'), findsNothing, reason: 'bubble goes away on release');
    expect(h.seeks, hasLength(1));
  });

  testWidgets('crossing five-minute marks ticks while scrubbing coarsely', (tester) async {
    final h = await _pump(tester);
    final gesture = await tester.startGesture(_at(tester, 0));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(10, 0)); // 100pt = 27.5 min → crosses 5 marks
    }
    await gesture.up();
    expect(h.haptics.where((k) => k == 'HapticFeedbackType.selectionClick').length, 5);
  });

  testWidgets('disabled (no audio yet) ignores touches', (tester) async {
    final h = await _pump(tester, enabled: false);
    await tester.tapAt(_at(tester, 100));
    final gesture = await tester.startGesture(_at(tester, 50));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.up();
    expect(h.seeks, isEmpty);
    expect(h.scrubs, isEmpty);
  });
}
