/// Speech profile information from Developer API
class SpeechProfileInfo {
  final bool hasProfile;
  final String? profileUrl;
  final String? createdAt;
  final double? durationSeconds;
  final int samplesCount;

  SpeechProfileInfo({
    required this.hasProfile,
    this.profileUrl,
    this.createdAt,
    this.durationSeconds,
    this.samplesCount = 0,
  });

  factory SpeechProfileInfo.fromJson(Map<String, dynamic> json) {
    return SpeechProfileInfo(
      hasProfile: json['has_profile'] ?? false,
      profileUrl: json['profile_url'],
      createdAt: json['created_at'],
      durationSeconds: json['duration_seconds']?.toDouble(),
      samplesCount: json['samples_count'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'has_profile': hasProfile,
      'profile_url': profileUrl,
      'created_at': createdAt,
      'duration_seconds': durationSeconds,
      'samples_count': samplesCount,
    };
  }
}
