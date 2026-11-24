import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/utils/audio/transcript_audio_alignment.dart';

/// 点一句从这句开始播：只信后端给的音频位置。
///
/// 实时录音的音频是整场会话裁掉静音后的 wav，段落上显示的 0:00 可能在文件的第 22 分钟
/// （生产实测 `16733526`：显示 0:00，音频 1368.21s），被裁掉的句子文件里根本没有声音。
void main() {
  test('unaligned recordings get no alignment instead of a guess from displayed times', () {
    expect(TranscriptAudioAlignment.fromJson({'aligned': false, 'reason': 'legacy', 'segments': []}), isNull);
    expect(TranscriptAudioAlignment.fromJson({'segments': []}), isNull);
    expect(TranscriptAudioAlignment.fromJson({'aligned': true}), isNull);
  });

  test('spanOf is the position in the audio file, and cut lines are marked', () {
    final alignment = TranscriptAudioAlignment.fromJson({
      'aligned': true,
      'segments': [
        {'id': 'first', 'start': 1368.21, 'end': 1371.5, 'has_audio': true},
        {'id': 'cut', 'start': 1371.5, 'end': 1371.5, 'has_audio': false},
        {'id': 'zero-length', 'start': 1380, 'end': 1380, 'has_audio': true},
        {'id': 7, 'start': 1, 'end': 2}, // malformed rows are skipped, not fatal
      ],
    })!;
    expect(alignment.spanOf('first')!.start, 1368.21);
    expect(alignment.spanOf('cut')!.hasAudio, isFalse);
    expect(alignment.spanOf('zero-length')!.hasAudio, isTrue, reason: 'start == end is not "cut"');
    expect(alignment.spanOf('missing'), isNull);
  });

  test('segmentAt follows playback, holds through short pauses and never lands on a cut line', () {
    final alignment = TranscriptAudioAlignment(const [
      AudioSpan('s1', 10, 12, hasAudio: true),
      AudioSpan('cut', 12, 12, hasAudio: false),
      AudioSpan('s2', 20, 25, hasAudio: true),
    ]);
    expect(alignment.segmentAt(5), isNull, reason: 'another conversation of the same session');
    expect(alignment.segmentAt(11), 's1');
    expect(alignment.segmentAt(12), 's1');
    expect(alignment.segmentAt(13), 's1', reason: 'short pause keeps the line highlighted');
    expect(alignment.segmentAt(16), isNull, reason: 'long pause: nobody is speaking');
    expect(alignment.segmentAt(21), 's2');
    expect(alignment.segmentAt(40), isNull);
  });

  test('with overlapping speakers a longer earlier line stays current', () {
    final alignment = TranscriptAudioAlignment(const [
      AudioSpan('long', 10, 30, hasAudio: true),
      AudioSpan('short', 12, 14, hasAudio: true),
    ]);
    expect(alignment.segmentAt(13), 'short');
    expect(alignment.segmentAt(20), 'long');
  });
}
