/// Fixed codes and numeric metadata only. Never include packet contents,
/// credentials, device identities or audio in copyable diagnostics.
enum SoundcoreProtocolIssue {
  checksum,
  duplicateHeader,
  audioBeforeHeader,
  incompleteFile,
  sliceLength,
  missingBeginning,
  sequenceGap,
  sequenceDuplicate,
  durationLimit,
}

class SoundcoreProtocolException extends FormatException {
  final SoundcoreProtocolIssue issue;
  final int? expected;
  final int? actual;
  final int? packetType;
  final int? packetId;
  final int? payloadBytes;

  const SoundcoreProtocolException(this.issue,
      {this.expected, this.actual, this.packetType, this.packetId, this.payloadBytes});

  String get diagnostic => 'protocol=${issue.name}'
      '${expected == null ? "" : " expected=$expected"}'
      '${actual == null ? "" : " actual=$actual"}'
      '${packetType == null ? "" : " type=$packetType"}'
      '${packetId == null ? "" : " id=$packetId"}'
      '${payloadBytes == null ? "" : " payloadBytes=$payloadBytes"}';

  @override
  String toString() => diagnostic;
}
