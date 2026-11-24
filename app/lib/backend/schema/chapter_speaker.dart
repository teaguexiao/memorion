/// Compact attribution metadata. Transcript/audio evidence is fetched on demand.
class ChapterSpeaker {
  final String id;
  final String? personId;
  final String? name;
  final bool isUser;
  final String status;
  final int number;
  final List<String> evidenceIds;
  const ChapterSpeaker(
      {required this.id,
      this.personId,
      this.name,
      this.isUser = false,
      this.status = 'unknown',
      this.number = 1,
      this.evidenceIds = const []});

  bool get confirmed => status == 'confirmed';
  bool get identified => isUser || (name?.trim().isNotEmpty ?? false);
  String label({bool chinese = true}) {
    if (isUser) return chinese ? '你' : 'You';
    if (name?.trim().isNotEmpty ?? false) return name!.trim();
    var n = number < 1 ? 1 : number;
    var letters = '';
    while (n > 0) {
      n--;
      letters = String.fromCharCode(65 + n % 26) + letters;
      n ~/= 26;
    }
    return '${chinese ? '说话人' : 'Speaker'} $letters';
  }

  String get identityKey => isUser
      ? 'user'
      : personId != null
          ? 'person:$personId'
          : id;
  factory ChapterSpeaker.fromJson(Map<String, dynamic> j) => ChapterSpeaker(
      id: j['id'] as String,
      personId: j['person_id'] as String?,
      name: j['name'] as String?,
      isUser: j['is_user'] == true,
      status: j['status'] as String? ?? 'unknown',
      number: (j['number'] as num?)?.toInt() ?? 1,
      evidenceIds: (j['evidence_ids'] as List?)?.whereType<String>().toList() ?? []);
  Map<String, dynamic> toJson() => {
        'id': id,
        'person_id': personId,
        'name': name,
        'is_user': isUser,
        'status': status,
        'number': number,
        'evidence_ids': evidenceIds
      };
}

class ChapterSpeakerDisplay {
  static final token = RegExp(r'\[\[speaker:(e[a-f0-9]{16})\]\]');
  final List<ChapterSpeaker> speakers;
  final Map<String, String> mentions;
  const ChapterSpeakerDisplay({required this.speakers, required this.mentions});
  factory ChapterSpeakerDisplay.fromJson(Map<String, dynamic> j) => ChapterSpeakerDisplay(
      speakers: (j['speakers'] as List? ?? [])
          .whereType<Map>()
          .map((s) => ChapterSpeaker.fromJson(Map<String, dynamic>.from(s)))
          .toList(),
      mentions: Map<String, String>.from(j['mentions'] as Map? ?? {}));
  Map<String, dynamic> toJson() =>
      {'version': 1, 'speakers': speakers.map((s) => s.toJson()).toList(), 'mentions': mentions};
  ChapterSpeaker? forEvidence(String id) {
    for (final s in speakers) {
      if (s.id == mentions[id]) return s;
    }
    return null;
  }

  List<ChapterSpeaker> usedIn(String raw) {
    final ids = token.allMatches(raw).map((m) => mentions[m[1]]).toSet();
    return speakers.where((s) => ids.contains(s.id)).toList();
  }

  String render(String raw, {bool chinese = true, bool links = false}) => raw.replaceAllMapped(token, (m) {
        final speaker = forEvidence(m[1]!);
        final name = speaker?.label(chinese: chinese) ?? (chinese ? '有人' : 'Someone');
        if (!links || speaker == null) return name;
        final escaped = name.replaceAllMapped(RegExp(r'([\\\[\]*_`])'), (m) => '\\${m[0]}');
        return '[$escaped](speaker:${m[1]} "${speaker.confirmed ? 'confirmed' : 'unconfirmed'}")';
      });

  /// Editor preserves evidence targets, irrespective of names changing meanwhile.
  static String restoreTokens(String markdown) => markdown.replaceAllMapped(
      RegExp(r'\[(?:\\.|[^\]])*\]\(speaker:(e[a-f0-9]{16})(?: "(?:confirmed|unconfirmed)")?\)'),
      (m) => '[[speaker:${m[1]}]]');
}

class ChapterSpeakerEvidence {
  final String id, conversationId, text;
  final double? audioStart, audioEnd;
  final String? learningBlockedReason;
  const ChapterSpeakerEvidence(
      {required this.id,
      required this.conversationId,
      required this.text,
      this.audioStart,
      this.audioEnd,
      this.learningBlockedReason});
  bool get playable =>
      audioStart != null &&
      audioEnd != null &&
      audioStart!.isFinite &&
      audioEnd!.isFinite &&
      audioStart! >= 0 &&
      audioEnd! > audioStart!;
  double get duration => playable ? audioEnd! - audioStart! : 0;
  bool get learningCandidate => playable && duration >= 10 && learningBlockedReason == null;
  factory ChapterSpeakerEvidence.fromJson(Map<String, dynamic> j) => ChapterSpeakerEvidence(
      id: j['id'] as String,
      conversationId: j['conversation_id'] as String,
      text: j['text'] as String,
      audioStart: (j['audio']?['start'] as num?)?.toDouble(),
      audioEnd: (j['audio']?['end'] as num?)?.toDouble(),
      learningBlockedReason: j['audio']?['learning_blocked_reason'] as String?);
}
