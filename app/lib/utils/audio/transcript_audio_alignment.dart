/// 一段转写在音频文件时间轴上的位置（秒）。
class AudioSpan {
  final String segmentId;
  final double start;
  final double end;

  /// false = 这句的声音被 VAD 当成静音整段裁掉了，文件里没有它。
  final bool hasAudio;

  const AudioSpan(this.segmentId, this.start, this.end, {required this.hasAudio});
}

/// 转写段落 ↔ 音频位置的双向查找。
///
/// 段落上显示的时间（`TranscriptSegment.start`）不是音频里的位置，不能拿来 seek：
/// 实时录音的音频是整场 WS 会话裁掉静音后的 wav，一条对话可能从文件第 20 分钟才开始，
/// 被 VAD 判成静音的句子在文件里根本没有声音。映射由后端
/// `GET /v1/conversations/{id}/audio-alignment` 算好（声纹切片用的是同一个函数），
/// 这里只做查找；对不齐的老录音拿到的是 null，界面上就不提供按句播放。
class TranscriptAudioAlignment {
  final Map<String, AudioSpan> _byId;

  /// 有声音的段落，按开始时间排序，供「播放到哪一句」二分查找。
  final List<AudioSpan> _playable;

  /// 句子结束后多久内仍算「正在播这一句」，避免句间短停顿里高亮闪烁。
  static const double trailingGraceSeconds = 1.5;

  TranscriptAudioAlignment(Iterable<AudioSpan> spans)
      : _byId = {for (final s in spans) s.segmentId: s},
        _playable = spans.where((s) => s.hasAudio).toList()..sort((a, b) => a.start.compareTo(b.start));

  /// `aligned != true`（老录音没有时间来源）或格式不对时返回 null。
  static TranscriptAudioAlignment? fromJson(Map<String, dynamic> json) {
    if (json['aligned'] != true || json['segments'] is! List) return null;
    final spans = <AudioSpan>[];
    for (final raw in json['segments'] as List) {
      if (raw is! Map) continue;
      final id = raw['id'];
      final start = raw['start'];
      final end = raw['end'];
      if (id is! String || start is! num || end is! num) continue;
      spans.add(AudioSpan(id, start.toDouble(), end.toDouble(), hasAudio: raw['has_audio'] != false));
    }
    return TranscriptAudioAlignment(spans);
  }

  AudioSpan? spanOf(String segmentId) => _byId[segmentId];

  /// 播放到 [seconds] 时正在说的那一句；不在任何一句里（会话里别的对话、长停顿）返回 null。
  String? segmentAt(double seconds) {
    // 开始时间不晚于 seconds 的最后一句。
    var lo = 0, hi = _playable.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_playable[mid].start <= seconds) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    // 往回多看两句：说话人重叠时，后开始的那句可能先结束。
    for (var i = found; i >= 0 && i > found - 3; i--) {
      if (seconds <= _playable[i].end + trailingGraceSeconds) return _playable[i].segmentId;
    }
    return null;
  }
}
