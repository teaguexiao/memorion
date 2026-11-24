/// Speech sample from Developer API
class SpeechSample {
  final String sampleId;
  final String sampleUrl;
  final String? createdAt;
  final double? durationSeconds;

  SpeechSample({
    required this.sampleId,
    required this.sampleUrl,
    this.createdAt,
    this.durationSeconds,
  });

  factory SpeechSample.fromJson(Map<String, dynamic> json) {
    return SpeechSample(
      sampleId: json['sample_id'] ?? '',
      sampleUrl: json['sample_url'] ?? '',
      createdAt: json['created_at'],
      durationSeconds: json['duration_seconds']?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sample_id': sampleId,
      'sample_url': sampleUrl,
      'created_at': createdAt,
      'duration_seconds': durationSeconds,
    };
  }
}
