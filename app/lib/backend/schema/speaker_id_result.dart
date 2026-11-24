/// Speaker identification result from Developer API
class SpeakerIdResult {
  final bool isUser;
  final double confidence;
  final String? personId;

  SpeakerIdResult({
    required this.isUser,
    this.confidence = 0.0,
    this.personId,
  });

  factory SpeakerIdResult.fromJson(Map<String, dynamic> json) {
    return SpeakerIdResult(
      isUser: json['is_user'] ?? false,
      confidence: (json['confidence'] ?? 0.0).toDouble(),
      personId: json['person_id'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'is_user': isUser,
      'confidence': confidence,
      'person_id': personId,
    };
  }
}
