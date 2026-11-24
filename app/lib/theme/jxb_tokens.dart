import 'package:flutter/material.dart';

/// 记小宝 · 1.0 UI 浅色设计令牌 (JXB Design Tokens)
///
/// 依据 `docs/product/Memorion-iOS-UI设计与Figma构建规格-2026-07.md` §1.2–§1.5
/// 与 Figma 「1.0 第一层级主要页面」实际画板 (file iISwI4qcPJqFq2eNvC10c2) 校准。
///
/// 全 App 唯一的设计令牌来源。旧的深色令牌 `theme/redesign_tokens.dart` 已于
/// 2026-08-20 随最后一批深色 UI 一起删除。
/// 1.0 改版页面只绑定此处的语义令牌，页面内不再散落硬编码色值 / 字号。
class JXB {
  JXB._();

  // ── 颜色 · Semantic ────────────────────────────────────────────────
  /// 主按钮、选中态、关键链接、时段
  static const Color brandPrimary = Color(0xFF007AFF);

  /// 次级操作、信息态
  static const Color brandSecondary = Color(0xFF54A4FD);

  /// 标题、正文主文本
  static const Color textPrimary = Color(0xFF25282D);

  /// 次文本、描述
  static const Color textSecondary = Color(0xFF808594);

  /// 占位、禁用、极浅辅助文字（元信息、空档条）
  static const Color textPlaceholder = Color(0xFFB2B2B2);

  /// 页面底色（Figma 1.0 实测淡蓝，非规格文档的灰紫 #F2F2F7）
  static const Color bgApp = Color(0xFFF6FAFF);

  /// 卡片、输入框、Sheet
  static const Color surface = Color(0xFFFFFFFF);

  /// 边框、分隔线
  static const Color border = Color(0xFFE5E5EA);

  /// 成功、已完成、录音正常
  static const Color success = Color(0xFF34C759);

  /// 临期、低电量、固件更新
  static const Color warning = Color(0xFFFFB13E);

  /// 删除、失败、断连错误
  static const Color error = Color(0xFFFF3B30);

  /// Dialog / Sheet 背景遮罩 (黑 32%)
  static const Color scrim = Color(0x52000000);

  // ── 颜色 · Tint (语义色的低透明容器底色) ────────────────────────────
  /// 选中容器、信息提示底色 (brandPrimary 10%)
  static const Color brandTint = Color(0x1A007AFF);

  /// Processing 卡等极浅品牌底 (brandPrimary 3%，取自 Figma 实际画板)
  static const Color brandTintFaint = Color(0x08007AFF);

  /// 正文选区高亮 (brandSecondary 18%)。刻意半透明——选中后文字仍要清晰可读，
  /// 只像被一层浅蓝底轻轻框住。
  ///
  /// ⚠️ **只在 `main.dart` 的全局 `textSelectionTheme` 里绑定一次**，页面级
  /// `Theme` 不要再声明。原因是页面级 `ThemeData.light().copyWith(...)` 若不写
  /// `textSelectionTheme`，`Theme` 注入 `DefaultSelectionStyle` 时取的是
  /// `data.textSelectionTheme.selectionColor ?? 外层值`——也就是**一定会**继承
  /// 全局值，所以治全局就够了，逐页声明只是多一份要同步的真相源。
  static const Color textSelection = Color(0x2E54A4FD);

  static const Color successTint = Color(0x1A34C759); // 10%
  static const Color warningTint = Color(0x1FFFB13E); // 12%
  static const Color errorTint = Color(0x1AFF3B30); // 10%

  // ── 间距 ────────────────────────────────────────────────────────────
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space6 = 24;
  static const double space8 = 32;

  // ── 圆角 ────────────────────────────────────────────────────────────
  static const double radiusSmall = 8;
  static const double radiusControl = 12;
  static const double radiusCard = 16;
  static const double radiusBubble = 24;
  static const double radiusFull = 999;

  // ── 尺寸 ────────────────────────────────────────────────────────────
  static const double sizeTouch = 44;
  static const double sizeInput = 44;
  static const double sizeButton = 48;
  static const double pageWidth = 390;

  /// 页面左右边距
  static const double pageMargin = 16;

  /// 列表行 / 卡片最小高度
  static const double rowMinHeight = 56;

  // ── 阴影 ────────────────────────────────────────────────────────────
  /// 卡片悬浮阴影。Figma 1.0 章节卡实测 0px 4.16px 14.04px rgba(43,41,38,0.06)。
  static const List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Color(0x0F2B2926), // rgba(43,41,38,0.06)
      offset: Offset(0, 4),
      blurRadius: 14,
    ),
  ];

  // ── 字体家族 ────────────────────────────────────────────────────────
  /// 产品中文主字体。v2.4 改版统一用 iOS 系统 PingFang SC（不再用 Noto Serif）。
  /// iOS 上 'PingFang SC' 为系统中文字体，无需打包字体资源。
  static const String fontSans = 'PingFang SC';

  /// 时间/数字等拉丁字形用 Inter（已打包）。
  static const String fontNumber = 'Inter';

  /// Bundled serif face used for display titles.
  static const String fontDisplay = 'NotoSerifSC';

  // ── 文字样式 ────────────────────────────────────────────────────────
  // 说明：字号取 Figma 1.0 画板实测值，与规格 §1.3 标准值对齐。

  /// Display 24/32 Bold — 日记主标题、里程碑判词
  static const TextStyle display = TextStyle(
    fontFamily: fontSans,
    fontSize: 24,
    height: 32 / 24,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  /// PageTitle 20/28 Bold — 页面标题
  static const TextStyle pageTitle = TextStyle(
    fontFamily: fontSans,
    fontSize: 20,
    height: 28 / 20,
    fontWeight: FontWeight.w700,
    color: textPrimary,
  );

  /// 日期组标题 (Figma 实测 23.92 SemiBold)
  static const TextStyle dayGroupTitle = TextStyle(
    fontFamily: fontSans,
    fontSize: 22,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  /// SectionTitle 17/24 Medium — 区块标题、卡片标题
  static const TextStyle sectionTitle = TextStyle(
    fontFamily: fontSans,
    fontSize: 17,
    height: 24 / 17,
    fontWeight: FontWeight.w500,
    color: textPrimary,
  );

  /// 章节卡标题 (v2.4：PingFang Medium 16)
  static const TextStyle chapterTitle = TextStyle(
    fontFamily: fontSans,
    fontSize: 16,
    height: 1.2,
    fontWeight: FontWeight.w500,
    color: textPrimary,
  );

  /// 章节卡正文/观察 (v2.4：14 / rgba(99,99,99,0.64) / 字距 0.28)
  static const TextStyle chapterBody = TextStyle(
    fontFamily: fontSans,
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: Color(0xA3636363), // rgba(99,99,99,0.64)
    letterSpacing: 0.28,
  );

  /// Body 16/24 Regular — 正文、转写、AI 叙事
  static const TextStyle body = TextStyle(
    fontFamily: fontSans,
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w400,
    color: textPrimary,
  );

  /// BodySmall 14/22 Regular — 辅助正文、列表描述、第一人称观察
  static const TextStyle bodySmall = TextStyle(
    fontFamily: fontSans,
    fontSize: 14,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: textSecondary,
  );

  /// Caption 12/18 Regular — 时间、来源、说明、元信息
  static const TextStyle caption = TextStyle(
    fontFamily: fontSans,
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w400,
    color: textPlaceholder,
  );

  /// MetaButton 14/20 Medium — 按钮、状态、Chip
  static const TextStyle metaButton = TextStyle(
    fontFamily: fontSans,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w500,
    color: textPrimary,
  );

  /// 章节卡时段 (v2.4：Inter Medium 11.44 品牌蓝)
  static const TextStyle chapterTime = TextStyle(
    fontFamily: fontNumber,
    fontSize: 11.44,
    height: 1.2,
    fontWeight: FontWeight.w500,
    color: brandPrimary,
  );

  /// 分类/高亮 chip 文字 (11.44)
  static const TextStyle tagLabel = TextStyle(
    fontFamily: fontSans,
    fontSize: 11.44,
    height: 1.0,
    fontWeight: FontWeight.w500,
  );
}
