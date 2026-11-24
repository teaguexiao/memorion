import 'package:flutter/material.dart';
import 'package:memorion/backend/auth.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/pages/onboarding/onboarding_lang.dart';
import 'package:memorion/providers/home_provider.dart';
import 'package:memorion/providers/locale_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:provider/provider.dart';

/// O-03 个性化 · 让我认识你（记小宝 1.0 浅色改版，Figma node 731:3060）。
///
/// 昵称 + 记录语言 + 时区 + 记录内容偏好标签。
/// 语言/时区/昵称写入复用旧壳逻辑；「记录内容偏好」本地存
/// `SharedPreferencesUtil().memorionCategories`（离线可用 + 立即回显），
/// 同时同步到服务端 user profile 的 `recording_categories`
/// （`PATCH /v1/user/preferences`），供后续消费（如转成 facts / 记忆）。
class PersonalizationPage extends StatefulWidget {
  final VoidCallback goNext;

  const PersonalizationPage({super.key, required this.goNext});

  @override
  State<PersonalizationPage> createState() => _PersonalizationPageState();
}

class _PersonalizationPageState extends State<PersonalizationPage> {
  late TextEditingController _nameController;
  final Set<String> _selectedCategories = {};
  String? _selectedLanguage;
  String? _selectedLanguageName;
  String? _selectedTimezone;
  String? _selectedTimezoneName;

  /// 记录内容偏好标签。key=稳定 id（英文，用于本地存储与服务端字段），
  /// 显示时按 UI 语言中/英。
  static const List<MapEntry<String, List<String>>> _prefTags = [
    MapEntry('meeting', ['会议', 'Meeting']),
    MapEntry('life', ['生活', 'Life']),
    MapEntry('study', ['学习', 'Study']),
    MapEntry('work', ['工作', 'Work']),
    MapEntry('health', ['健康', 'Health']),
    MapEntry('family', ['家庭', 'Family']),
    MapEntry('inspiration', ['灵感', 'Ideas']),
    MapEntry('travel', ['旅行', 'Travel']),
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: SharedPreferencesUtil().givenName);

    // 恢复已选偏好（若为默认 ['all'] 则视为未选）
    final saved = SharedPreferencesUtil().memorionCategories;
    final validIds = _prefTags.map((e) => e.key).toSet();
    for (final t in saved) {
      if (validIds.contains(t)) _selectedCategories.add(t);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final homeProvider = Provider.of<HomeProvider>(context, listen: false);
      final savedLanguage = SharedPreferencesUtil().userPrimaryLanguage;
      if (savedLanguage.isNotEmpty) {
        setState(() {
          _selectedLanguage = savedLanguage;
          try {
            _selectedLanguageName =
                homeProvider.availableLanguages.entries.firstWhere((e) => e.value == savedLanguage).key;
          } catch (_) {
            _selectedLanguageName = savedLanguage;
          }
        });
      }
      final savedTimezone = SharedPreferencesUtil().userTimezone;
      if (savedTimezone.isNotEmpty) {
        setState(() {
          _selectedTimezone = savedTimezone;
          final entry = HomeProvider.availableTimezones.entries.where((e) => e.value == savedTimezone).firstOrNull;
          _selectedTimezoneName = entry?.key ?? savedTimezone;
        });
      } else {
        _autoDetectTimezone();
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _canContinue => _nameController.text.trim().isNotEmpty && _selectedLanguage != null;

  void _autoDetectTimezone() {
    final deviceOffset = DateTime.now().timeZoneOffset;
    const offsetTimezones = <String, List<int>>{
      'America/New_York': [-5, -4],
      'America/Chicago': [-6, -5],
      'America/Denver': [-7, -6],
      'America/Los_Angeles': [-8, -7],
      'Europe/London': [0, 1],
      'Europe/Paris': [1, 2],
      'Europe/Berlin': [1, 2],
      'Asia/Kolkata': [5],
      'Asia/Bangkok': [7],
      'Asia/Singapore': [8],
      'Asia/Shanghai': [8],
      'Asia/Hong_Kong': [8],
      'Asia/Taipei': [8],
      'Asia/Tokyo': [9],
      'Asia/Seoul': [9],
      'Australia/Sydney': [10, 11],
      'Pacific/Auckland': [12, 13],
    };
    for (final entry in HomeProvider.availableTimezones.entries) {
      final offsets = offsetTimezones[entry.value];
      if (offsets != null && offsets.contains(deviceOffset.inHours) && deviceOffset.inMinutes % 60 == 0) {
        setState(() {
          _selectedTimezone = entry.value;
          _selectedTimezoneName = entry.key;
        });
        return;
      }
    }
  }

  void _toggleTag(String tag) {
    setState(() {
      if (_selectedCategories.contains(tag)) {
        _selectedCategories.remove(tag);
      } else {
        _selectedCategories.add(tag);
      }
    });
  }

  Future<void> _showLanguageSelector() async {
    // 只保留中文 / English 两项（记录语言）。
    final entries = <_PickerItem>[
      _PickerItem(value: 'en', title: 'English', subtitle: 'en', flag: '🇺🇸'),
      _PickerItem(value: 'zh', title: '中文', subtitle: 'zh', flag: '🇨🇳'),
    ];
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _LightPickerSheet(
        title: obLRead(context, '选择语言', 'Select language'),
        searchHint: obLRead(context, '搜索语言', 'Search language'),
        showSearch: false,
        entries: entries,
        selectedValue: _selectedLanguage,
        confirmLabel: obLRead(context, '同意并继续', 'Agree & continue'),
        onConfirm: (item) {
          if (item != null) {
            setState(() {
              _selectedLanguage = item.value;
              _selectedLanguageName = item.title;
            });
          }
        },
      ),
    );
  }

  Future<void> _showTimezoneSelector() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _LightPickerSheet(
        title: obLRead(context, '选择时区', 'Select timezone'),
        searchHint: obLRead(context, '搜索时区', 'Search timezone'),
        showSearch: true,
        entries: HomeProvider.availableTimezones.entries
            .map((e) => _PickerItem(value: e.value, title: e.key, subtitle: e.value))
            .toList(),
        selectedValue: _selectedTimezone,
        confirmLabel: obLRead(context, '同意并继续', 'Agree & continue'),
        onConfirm: (item) {
          if (item != null) {
            setState(() {
              _selectedTimezone = item.value;
              _selectedTimezoneName = item.title;
            });
          }
        },
      ),
    );
  }

  Future<void> _handleContinue() async {
    FocusManager.instance.primaryFocus?.unfocus();
    updateGivenName(_nameController.text.trim());

    final homeProvider = Provider.of<HomeProvider>(context, listen: false);

    if (_selectedLanguage != null) {
      await homeProvider.updateUserPrimaryLanguage(_selectedLanguage!);
      const supportedUiCodes = {'en', 'zh'};
      if (supportedUiCodes.contains(_selectedLanguage) && mounted) {
        context.read<LocaleProvider>().setLocale(Locale(_selectedLanguage!));
      }
    }
    if (_selectedTimezone != null) {
      await homeProvider.updateUserTimezone(_selectedTimezone!);
    }
    // 记录内容偏好：本地存（离线可用 + 立即回显）；未选则回退默认 ['all']。
    final categories = _selectedCategories.isEmpty ? ['all'] : _selectedCategories.toList();
    SharedPreferencesUtil().memorionCategories = categories;
    // 同步到服务端 user profile，供后续消费；网络失败不阻断 onboarding
    // （本地已存，下次改动会再同步一次）。
    setRecordingCategories(categories).catchError((e) {
      debugPrint('setRecordingCategories failed (local copy kept): $e');
      return false;
    });

    widget.goNext();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 40), // 让开进度点
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  _title(context),
                  const SizedBox(height: 6),
                  Text(obL(context, '填好这些，让 Memorion 更懂你的记录', 'Tell us a bit so Memorion knows you better'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary, height: 1.5)),
                  const SizedBox(height: 26),
                  _inputField(
                    child: TextField(
                      controller: _nameController,
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPrimary),
                      decoration: _fieldDecoration(obL(context, '昵称', 'Nickname')),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _selectorField(
                    hint: obL(context, '记录语言', 'Recording language'),
                    value: _selectedLanguageName,
                    onTap: _showLanguageSelector,
                  ),
                  const SizedBox(height: 14),
                  _selectorField(
                    hint: obL(context, '时区', 'Timezone'),
                    value: _selectedTimezoneName,
                    onTap: _showTimezoneSelector,
                  ),
                  const SizedBox(height: 28),
                  Text(obL(context, '记录内容偏好', 'What you like to record'),
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                  const SizedBox(height: 4),
                  Text(obL(context, '可多选，帮助 Memorion 更懂你想记录什么', 'Choose any — helps Memorion understand you'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: _prefTags.map((e) => _tagChip(e.key, obL(context, e.value[0], e.value[1]))).toList(),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, MediaQuery.of(context).padding.bottom + 16),
            child: _primaryButton(obL(context, '下一步', 'Next'), _canContinue ? _handleContinue : null),
          ),
        ],
      ),
    );
  }

  Widget _title(BuildContext context) {
    final zh = obL(context, 'zh', 'en') == 'zh';
    return RichText(
      text: TextSpan(
        style: const TextStyle(fontFamily: JXB.fontDisplay, fontSize: 26, fontWeight: FontWeight.w700, height: 1.2),
        children: zh
            ? const [
                TextSpan(text: '让我认识', style: TextStyle(color: JXB.textPrimary)),
                TextSpan(text: '你', style: TextStyle(color: JXB.brandPrimary)),
              ]
            : const [
                TextSpan(text: 'Let me get to know ', style: TextStyle(color: JXB.textPrimary)),
                TextSpan(text: 'you', style: TextStyle(color: JXB.brandPrimary)),
              ],
      ),
    );
  }

  Widget _inputField({required Widget child}) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFFEDEFF2), borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: child,
    );
  }

  InputDecoration _fieldDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPlaceholder),
      border: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
    );
  }

  Widget _selectorField({required String hint, String? value, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(color: const Color(0xFFEDEFF2), borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            Expanded(
              child: Text(
                value ?? hint,
                style: TextStyle(
                    fontFamily: JXB.fontSans, fontSize: 16, color: value != null ? JXB.textPrimary : JXB.textPlaceholder),
              ),
            ),
            const Icon(Icons.keyboard_arrow_down_rounded, color: JXB.textPlaceholder, size: 24),
          ],
        ),
      ),
    );
  }

  Widget _tagChip(String id, String label) {
    final selected = _selectedCategories.contains(id);
    return GestureDetector(
      onTap: () => _toggleTag(id),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? JXB.brandPrimary : JXB.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? JXB.brandPrimary : JXB.border, width: 1),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontFamily: JXB.fontSans,
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: selected ? Colors.white : JXB.textPrimary),
        ),
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback? onTap) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? JXB.brandPrimary : JXB.brandPrimary.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }
}

class _PickerItem {
  final String value;
  final String title;
  final String subtitle;
  final String? flag; // 国旗 emoji（语言选择用）
  _PickerItem({required this.value, required this.title, required this.subtitle, this.flag});
}

/// 浅色选择 sheet（语言 / 时区共用，还原 Figma 776:1773 / 776:1857）。
///
/// header：✕（关闭）+ 居中标题 + ✓ 蓝圆钮（确认当前选择）；可选搜索框；
/// 列表项（可带国旗 + 名称 + 副标，选中浅蓝底 + 勾）；底部「同意并继续」蓝钮确认。
class _LightPickerSheet extends StatefulWidget {
  final String title;
  final String searchHint;
  final bool showSearch;
  final List<_PickerItem> entries;
  final String? selectedValue;
  final String confirmLabel;
  final ValueChanged<_PickerItem?> onConfirm;

  const _LightPickerSheet({
    required this.title,
    required this.searchHint,
    required this.showSearch,
    required this.entries,
    required this.selectedValue,
    required this.confirmLabel,
    required this.onConfirm,
  });

  @override
  State<_LightPickerSheet> createState() => _LightPickerSheetState();
}

class _LightPickerSheetState extends State<_LightPickerSheet> {
  late List<_PickerItem> _filtered;
  final _searchController = TextEditingController();
  String? _pendingValue;

  @override
  void initState() {
    super.initState();
    _filtered = List.from(widget.entries);
    _pendingValue = widget.selectedValue;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filter(String q) {
    final query = q.toLowerCase();
    setState(() {
      _filtered = query.isEmpty
          ? List.from(widget.entries)
          : widget.entries
              .where((e) => e.title.toLowerCase().contains(query) || e.subtitle.toLowerCase().contains(query))
              .toList();
    });
  }

  _PickerItem? get _selectedItem {
    for (final e in widget.entries) {
      if (e.value == _pendingValue) return e;
    }
    return null;
  }

  void _confirm() {
    widget.onConfirm(_selectedItem);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.72;
    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: const BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(width: 36, height: 5, decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(3))),
          // header：✕ + 标题 + ✓
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 30, height: 30, alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Color(0x14808594), shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 16, color: JXB.textSecondary),
                  ),
                ),
                Expanded(
                  child: Text(widget.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                ),
                GestureDetector(
                  onTap: _pendingValue != null ? _confirm : null,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 30, height: 30, alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: _pendingValue != null ? JXB.brandSecondary : JXB.brandSecondary.withValues(alpha: 0.4),
                        shape: BoxShape.circle),
                    child: const Icon(Icons.check_rounded, size: 17, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          if (widget.showSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: _filter,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPrimary),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFFEDEFF2),
                  hintText: widget.searchHint,
                  hintStyle: const TextStyle(fontFamily: JXB.fontSans, color: JXB.textPlaceholder),
                  prefixIcon: const Icon(Icons.search, color: JXB.textPlaceholder, size: 20),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),
          Flexible(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              itemCount: _filtered.length,
              itemBuilder: (context, i) {
                final item = _filtered[i];
                final isSelected = _pendingValue == item.value;
                return GestureDetector(
                  onTap: () => setState(() => _pendingValue = item.value),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                    margin: const EdgeInsets.symmetric(vertical: 1),
                    decoration: BoxDecoration(
                      color: isSelected ? JXB.brandTint : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        if (item.flag != null) ...[
                          Text(item.flag!, style: const TextStyle(fontSize: 22)),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.title,
                                  style: const TextStyle(
                                      fontFamily: JXB.fontSans,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: JXB.textPrimary)),
                              const SizedBox(height: 1),
                              Text(item.subtitle,
                                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textSecondary)),
                            ],
                          ),
                        ),
                        if (isSelected) const Icon(Icons.check_rounded, color: JXB.brandPrimary, size: 20),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // 底部「同意并继续」
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 12),
            child: GestureDetector(
              onTap: _pendingValue != null ? _confirm : null,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _pendingValue != null ? JXB.brandSecondary : JXB.brandSecondary.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Text(widget.confirmLabel,
                    style: const TextStyle(
                        fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: Colors.white)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
