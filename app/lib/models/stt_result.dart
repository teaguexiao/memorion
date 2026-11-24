/// Result model for on-device STT transcription.
class SttSegment {
  final String? id;
  final String text;
  final double start;
  final double end;
  final int speakerId;

  SttSegment({
    this.id,
    required this.text,
    required this.start,
    required this.end,
    this.speakerId = 0,
  });
}

class SttTranscriptionResult {
  final List<SttSegment> segments;
  final String rawText;

  SttTranscriptionResult({
    required this.segments,
    required this.rawText,
  });

  bool get isNotEmpty => segments.isNotEmpty && rawText.isNotEmpty;
}
