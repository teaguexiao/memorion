import 'package:flutter/material.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/providers/home_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/alerts/app_snackbar.dart';
import 'package:provider/provider.dart';


const Map<String, String> _langFlags = {
  'en': '🇺🇸', 'zh': '🇨🇳', 'ja': '🇯🇵', 'ko': '🇰🇷',
  'fr': '🇫🇷', 'de': '🇩🇪', 'es': '🇪🇸', 'pt': '🇵🇹',
  'ru': '🇷🇺', 'ar': '🇸🇦', 'hi': '🇮🇳', 'th': '🇹🇭',
  'vi': '🇻🇳', 'it': '🇮🇹', 'nl': '🇳🇱', 'pl': '🇵🇱',
  'tr': '🇹🇷', 'uk': '🇺🇦', 'sv': '🇸🇪', 'da': '🇩🇰',
  'no': '🇳🇴', 'fi': '🇫🇮', 'el': '🇬🇷', 'he': '🇮🇱',
  'id': '🇮🇩', 'ms': '🇲🇾', 'cs': '🇨🇿', 'ro': '🇷🇴',
  'hu': '🇭🇺', 'bg': '🇧🇬', 'hr': '🇭🇷', 'sk': '🇸🇰',
  'ca': '🇪🇸', 'ta': '🇮🇳', 'te': '🇮🇳', 'bn': '🇧🇩',
  'ur': '🇵🇰', 'fa': '🇮🇷', 'sw': '🇰🇪', 'af': '🇿🇦',
};

String _flagForCode(String code) {
  // Try exact match first, then first 2 chars
  if (_langFlags.containsKey(code)) return _langFlags[code]!;
  final short = code.length >= 2 ? code.substring(0, 2) : code;
  return _langFlags[short] ?? '🌐';
}

class LanguageSelectionDialog {
  static Future<void> show(BuildContext context, {bool isRequired = false, bool forceShow = false}) async {
    final homeProvider = Provider.of<HomeProvider>(context, listen: false);

    if (homeProvider.hasSetPrimaryLanguage && !isRequired && !forceShow) {
      return;
    }

    if (homeProvider.userPrimaryLanguage.isEmpty) {
      isRequired = true;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: !isRequired,
      enableDrag: !isRequired,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => _LanguageSheet(
        homeProvider: homeProvider,
        isRequired: isRequired,
      ),
    );
  }
}

class _LanguageSheet extends StatefulWidget {
  final HomeProvider homeProvider;
  final bool isRequired;

  const _LanguageSheet({required this.homeProvider, required this.isRequired});

  @override
  State<_LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends State<_LanguageSheet> {
  late List<MapEntry<String, String>> _allLanguages;
  late List<MapEntry<String, String>> _filteredLanguages;
  String? _selected;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _allLanguages = widget.homeProvider.availableLanguages.entries.toList();
    _filteredLanguages = List.from(_allLanguages);
    _selected = widget.homeProvider.userPrimaryLanguage.isNotEmpty
        ? widget.homeProvider.userPrimaryLanguage
        : null;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filter(String query) {
    final q = query.toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filteredLanguages = List.from(_allLanguages);
      } else {
        _filteredLanguages = _allLanguages.where((lang) {
          return lang.key.toLowerCase().contains(q) || lang.value.toLowerCase().contains(q);
        }).toList();
      }
    });
  }

  Future<void> _select(MapEntry<String, String> lang) async {
    setState(() => _selected = lang.value);
    final success = await widget.homeProvider.updateUserPrimaryLanguage(lang.value);
    if (success && mounted) {
      Provider.of<CaptureProvider>(context, listen: false).onRecordProfileSettingChanged();
      AppSnackbar.showSnackbarSuccess('✓ ${S.of(context).languageUpdated}');
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) Navigator.of(context).pop();
    } else {
      AppSnackbar.showSnackbarError(S.of(context).failedToSetLanguage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.85;

    // 配色对齐账号页的浅色时区 sheet（同形态：搜索 + 列表 + 打勾）。
    // 这里原是深色（#1C1C1E 底 + 白字 + kRedesignPrimary），靠旧深色壳的全局主题；
    // 而它的唯一触发点是「新用户首次进入 / 后端没有语言设置」——弹在浅色 App 上。
    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: const BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 36, height: 4,
            margin: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(2)),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(S.of(context).languageTitle,
                    style: const TextStyle(
                        fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                // isRequired 时不给关闭键（首次必须选一个语言）。
                if (!widget.isRequired)
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 30, height: 30, alignment: Alignment.center,
                      decoration: const BoxDecoration(color: Color(0x14808594), shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded, size: 16, color: JXB.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
          // Search
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _filter,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPrimary),
              decoration: InputDecoration(
                filled: true,
                fillColor: JXB.bgApp,
                hintText: S.of(context).searchLanguage,
                hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPlaceholder),
                prefixIcon: const Icon(Icons.search_rounded, size: 20, color: JXB.textPlaceholder),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
          ),
          // List
          Expanded(
            child: _filteredLanguages.isEmpty
                ? Center(
                    child: Text(S.of(context).noLanguagesFound,
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 40),
                    itemCount: _filteredLanguages.length,
                    itemBuilder: (context, index) {
                      final lang = _filteredLanguages[index];
                      final isSelected = _selected == lang.value;
                      final flag = _flagForCode(lang.value);

                      return GestureDetector(
                        onTap: () => _select(lang),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                          margin: const EdgeInsets.symmetric(vertical: 1),
                          decoration: BoxDecoration(
                            color: isSelected ? JXB.brandTint : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 28,
                                child: Text(flag, style: const TextStyle(fontSize: 22), textAlign: TextAlign.center),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      lang.key,
                                      style: const TextStyle(
                                          fontFamily: JXB.fontSans,
                                          color: JXB.textPrimary,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      lang.value,
                                      style: const TextStyle(
                                          fontFamily: JXB.fontSans, color: JXB.textPlaceholder, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              AnimatedOpacity(
                                duration: const Duration(milliseconds: 200),
                                opacity: isSelected ? 1.0 : 0.0,
                                child: AnimatedScale(
                                  duration: const Duration(milliseconds: 200),
                                  scale: isSelected ? 1.0 : 0.5,
                                  child: const Icon(Icons.check_rounded, size: 20, color: JXB.brandPrimary),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
