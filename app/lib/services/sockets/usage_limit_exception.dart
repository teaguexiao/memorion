/// Thrown when the backend returns 429 (usage limit exceeded) during session creation.
class UsageLimitExceededException implements Exception {
  final String message;
  const UsageLimitExceededException([this.message = 'Usage limit exceeded. Please upgrade your plan.']);

  @override
  String toString() => 'UsageLimitExceededException: $message';
}
