import 'package:flutter/material.dart';

enum AvatarEmotion {
  happy,
  angry,
  sad,
  surprised,
  calm;

  String get label {
    switch (this) {
      case AvatarEmotion.happy:
        return '开心';
      case AvatarEmotion.angry:
        return '生气';
      case AvatarEmotion.sad:
        return '悲伤';
      case AvatarEmotion.surprised:
        return '惊讶';
      case AvatarEmotion.calm:
        return '平静';
    }
  }

  /// English label, used where the UI supports both languages
  /// (e.g. the home "mood barometer").
  String get labelEn {
    switch (this) {
      case AvatarEmotion.happy:
        return 'Happy';
      case AvatarEmotion.angry:
        return 'Angry';
      case AvatarEmotion.sad:
        return 'Sad';
      case AvatarEmotion.surprised:
        return 'Surprised';
      case AvatarEmotion.calm:
        return 'Calm';
    }
  }

  /// Face icon for the mood, shown on the home "mood barometer" card.
  IconData get moodIcon {
    switch (this) {
      case AvatarEmotion.happy:
        return Icons.sentiment_very_satisfied_rounded;
      case AvatarEmotion.angry:
        return Icons.sentiment_very_dissatisfied_rounded;
      case AvatarEmotion.sad:
        return Icons.sentiment_dissatisfied_rounded;
      case AvatarEmotion.surprised:
        return Icons.sentiment_satisfied_alt_rounded;
      case AvatarEmotion.calm:
        return Icons.sentiment_satisfied_rounded;
    }
  }

  /// Vivid accent color readable on dark surfaces (home card background),
  /// distinct from [backgroundColor]/[textColor] which target light cards.
  Color get accentColor {
    switch (this) {
      case AvatarEmotion.happy:
        return const Color(0xFFF6C453);
      case AvatarEmotion.angry:
        return const Color(0xFFEF6B6B);
      case AvatarEmotion.sad:
        return const Color(0xFF60A5FA);
      case AvatarEmotion.surprised:
        return const Color(0xFFEC4899);
      case AvatarEmotion.calm:
        return const Color(0xFF10B981);
    }
  }

  String get phrase {
    switch (this) {
      case AvatarEmotion.happy:
        return '哇，主人好开心，我也超快乐～';
      case AvatarEmotion.angry:
        return '别气啦，我陪着你消消气～';
      case AvatarEmotion.sad:
        return '难过就歇会儿，我一直陪着你。';
      case AvatarEmotion.surprised:
        return '哇？好突然';
      case AvatarEmotion.calm:
        return '安安静静，陪主人悠闲度日。';
    }
  }

  /// English phrase, paired with [phrase] via revampText for bilingual UI.
  String get phraseEn {
    switch (this) {
      case AvatarEmotion.happy:
        return "Yay, you're so happy — I'm thrilled too!"; // i18n-ignore: bilingual pair for revampText
      case AvatarEmotion.angry:
        return "Don't be upset, I'm here to help you cool down."; // i18n-ignore: bilingual pair for revampText
      case AvatarEmotion.sad:
        return "Take a rest if you're feeling down — I'm always here with you."; // i18n-ignore: bilingual pair for revampText
      case AvatarEmotion.surprised:
        return 'Whoa? That was sudden!'; // i18n-ignore: bilingual pair for revampText
      case AvatarEmotion.calm:
        return 'Nice and quiet, just relaxing together.'; // i18n-ignore: bilingual pair for revampText
    }
  }

  Color get backgroundColor {
    switch (this) {
      case AvatarEmotion.happy:
        return const Color(0xFFFFF3D0);
      case AvatarEmotion.angry:
        return const Color(0xFFE8B4B8);
      case AvatarEmotion.sad:
        return const Color(0xFFB8C8D8);
      case AvatarEmotion.surprised:
        return const Color(0xFFD8F4E4);
      case AvatarEmotion.calm:
        return const Color(0xFFF5F0E6);
    }
  }

  Color get textColor {
    switch (this) {
      case AvatarEmotion.happy:
        return const Color(0xFF5C4A00);
      case AvatarEmotion.angry:
        return const Color(0xFF5C1A1A);
      case AvatarEmotion.sad:
        return const Color(0xFF2A3A4A);
      case AvatarEmotion.surprised:
        return const Color(0xFF1A4A2A);
      case AvatarEmotion.calm:
        return const Color(0xFF4A4540);
    }
  }

  static AvatarEmotion fromString(String? emotion) {
    switch (emotion?.toLowerCase()) {
      case 'happy':
        return AvatarEmotion.happy;
      case 'angry':
        return AvatarEmotion.angry;
      case 'sad':
        return AvatarEmotion.sad;
      case 'surprised':
        return AvatarEmotion.surprised;
      case 'calm':
      default:
        return AvatarEmotion.calm;
    }
  }
}
