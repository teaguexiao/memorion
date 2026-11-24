import 'package:flutter/widgets.dart';
import 'package:memorion/l10n/app_localizations.dart';

/// 将后端返回的 conversation/memory category 英文枚举值
/// 转换为当前 locale 下的展示名。
///
/// 后端 enum 来源：backend/models/conversation.py CategoryEnum
String localizeCategory(BuildContext context, String? raw) {
  final s = S.of(context);
  if (raw == null || raw.isEmpty) return s.categoryOther;
  final key = raw.trim().toLowerCase();
  switch (key) {
    case 'personal':
      return s.categoryPersonal;
    case 'education':
      return s.categoryEducation;
    case 'health':
      return s.categoryHealth;
    case 'finance':
      return s.categoryFinance;
    case 'legal':
      return s.categoryLegal;
    case 'philosophy':
      return s.categoryPhilosophy;
    case 'spiritual':
      return s.categorySpiritual;
    case 'science':
      return s.categoryScience;
    case 'entrepreneurship':
      return s.categoryEntrepreneurship;
    case 'parenting':
      return s.categoryParenting;
    case 'romantic':
    case 'romance':
      return s.categoryRomantic;
    case 'travel':
      return s.categoryTravel;
    case 'inspiration':
      return s.categoryInspiration;
    case 'technology':
      return s.categoryTechnology;
    case 'business':
      return s.categoryBusiness;
    case 'social':
      return s.categorySocial;
    case 'work':
      return s.categoryWork;
    case 'sports':
      return s.categorySports;
    case 'politics':
      return s.categoryPolitics;
    case 'literature':
      return s.categoryLiterature;
    case 'history':
      return s.categoryHistory;
    case 'architecture':
      return s.categoryArchitecture;
    case 'music':
      return s.categoryMusic;
    case 'weather':
      return s.categoryWeather;
    case 'news':
      return s.categoryNews;
    case 'entertainment':
      return s.categoryEntertainment;
    case 'psychology':
      return s.categoryPsychology;
    case 'real':
      return s.categoryReal;
    case 'design':
      return s.categoryDesign;
    case 'family':
      return s.categoryFamily;
    case 'economics':
      return s.categoryEconomics;
    case 'environment':
      return s.categoryEnvironment;
    case 'various':
      return s.categoryVarious;
    case 'other':
    default:
      return s.categoryOther;
  }
}
