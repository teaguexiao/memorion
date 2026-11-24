import 'package:flutter/material.dart';
import 'package:memorion/models/subscription.dart';
import 'package:memorion/providers/purchase_provider.dart';
import 'package:memorion/providers/usage_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key});

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage> {
  static const _manageUrl = 'https://apps.apple.com/account/subscriptions';
  static const _privacyUrl = 'https://memorion.me/privacy';
  static const _termsUrl = 'https://memorion.me/terms-of-service';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<UsageProvider>().fetchSubscription();
      context.read<PurchaseProvider>().loadProducts();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: Scaffold(
        backgroundColor: JXB.bgApp,
        body: SafeArea(
          child: Column(
            children: [
              _topBar(context),
              Expanded(
                child: Consumer2<UsageProvider, PurchaseProvider>(
                  builder: (context, usage, purchases, _) {
                    final response = usage.subscription;
                    if (response == null && usage.isLoading) {
                      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                    }
                    return _content(context, response, purchases);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                width: 36,
                height: 36,
                child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary),
              ),
            ),
            Expanded(
              child: Text(
                revampText(context, en: 'Subscription', zh: '订阅'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: JXB.fontSans,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: JXB.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 36),
          ],
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    UserSubscriptionResponse? response,
    PurchaseProvider purchases,
  ) {
    if (response == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            revampText(
              context,
              en: 'Subscription status is unavailable. Pull back and try again.',
              zh: '暂时无法获取订阅状态，请返回后重试。',
            ),
            textAlign: TextAlign.center,
            style: JXB.bodySmall,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
      children: [
        _statusCard(context, response),
        const SizedBox(height: 18),
        _sectionTitle(context, en: 'Plan benefits', zh: '方案权益'),
        const SizedBox(height: 10),
        _benefitsComparison(context, response),
        if (response.canPurchase) ...[
          const SizedBox(height: 18),
          _sectionTitle(context, en: 'Choose Pro', zh: '选择 Pro'),
          const SizedBox(height: 10),
          _planCard(
            context,
            purchases,
            productId: PurchaseProvider.annualProductId,
            title: revampText(context, en: 'Annual', zh: '年度订阅'),
            note: revampText(context, en: 'About 2 months free', zh: '相当于每年省约 2 个月'),
            emphasized: true,
          ),
          const SizedBox(height: 10),
          _planCard(
            context,
            purchases,
            productId: PurchaseProvider.monthlyProductId,
            title: revampText(context, en: 'Monthly', zh: '月度订阅'),
            note: revampText(context, en: 'Flexible monthly billing', zh: '按月续订，更灵活'),
          ),
        ],
        if (response.accessLevel == AccessLevel.pro) ...[
          const SizedBox(height: 18),
          _outlineButton(
            context,
            label: revampText(context, en: 'Manage with Apple', zh: '在 Apple 中管理订阅'),
            onTap: () => _open(_manageUrl),
          ),
        ],
        if (!response.isLegacy) ...[
          const SizedBox(height: 12),
          TextButton(
            onPressed: purchases.purchasePending || !purchases.storeAvailable ? null : purchases.restore,
            child: Text(
              revampText(context, en: 'Restore Purchases', zh: '恢复购买'),
              style: const TextStyle(
                fontFamily: JXB.fontSans,
                color: JXB.brandPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        if (purchases.purchasePending) ...[
          const SizedBox(height: 4),
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ],
        if (purchases.error != null) ...[
          const SizedBox(height: 10),
          Text(
            purchases.products.isEmpty
                ? revampText(
                    context,
                    en: 'App Store pricing is temporarily unavailable.',
                    zh: '暂时无法获取 App Store 价格。',
                  )
                : revampText(
                    context,
                    en: 'The purchase could not be completed. Check your App Store account and try again.',
                    zh: '购买未完成，请检查 App Store 账户后重试。',
                  ),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: JXB.fontSans,
              fontSize: 13,
              color: JXB.error,
              height: 1.4,
            ),
          ),
          if (response.canPurchase && purchases.products.isEmpty)
            Center(
              child: TextButton(
                onPressed: purchases.loading ? null : purchases.loadProducts,
                child: Text(
                  revampText(context, en: 'Try Again', zh: '重试'),
                  style: const TextStyle(
                    fontFamily: JXB.fontSans,
                    color: JXB.brandPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
        if (response.canPurchase) ...[
          const SizedBox(height: 20),
          Text(
            revampText(
              context,
              en: 'Payment is charged to your Apple ID. Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period. You can manage or cancel in App Store settings.',
              zh: '费用将从你的 Apple ID 扣款。订阅会自动续订，除非你在当前周期结束至少 24 小时前取消。你可以随时在 App Store 设置中管理或取消。',
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: JXB.fontSans,
              fontSize: 11,
              height: 1.5,
              color: JXB.textPlaceholder,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legalLink(context, revampText(context, en: 'Terms', zh: '服务条款'), _termsUrl),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('·', style: TextStyle(color: JXB.textPlaceholder)),
              ),
              _legalLink(context, revampText(context, en: 'Privacy', zh: '隐私政策'), _privacyUrl),
            ],
          ),
        ],
      ],
    );
  }

  Widget _statusCard(BuildContext context, UserSubscriptionResponse response) {
    final (title, detail, icon, tint) = switch (response.accessLevel) {
      AccessLevel.legacyUnlimited => (
          revampText(context, en: 'Legacy Unlimited', zh: '老用户无限权益'),
          revampText(
            context,
            en: 'Your existing account keeps unlimited access.',
            zh: '你的现有账户会永久保留无限权益。',
          ),
          Icons.all_inclusive_rounded,
          JXB.successTint,
        ),
      AccessLevel.trialAvailable => (
          revampText(context, en: '90 days of Pro included', zh: '包含 90 天 Pro 体验'),
          revampText(
            context,
            en: 'It starts with your first recording. No payment method and no automatic charge.',
            zh: '从第一次录音开始计算，无需付款方式，也不会自动扣费。',
          ),
          Icons.auto_awesome_rounded,
          JXB.brandTint,
        ),
      AccessLevel.foundingTrial => (
          revampText(context, en: 'Founding Pro Access', zh: 'Founding Pro 体验'),
          response.trialDaysRemaining == null
              ? revampText(context, en: 'Your Pro access is active.', zh: '你的 Pro 权益已生效。')
              : revampText(
                  context,
                  en: '${response.trialDaysRemaining} days remaining',
                  zh: '还剩 ${response.trialDaysRemaining} 天',
                ),
          Icons.brightness_5_rounded,
          JXB.brandTint,
        ),
      AccessLevel.pro => (
          'Memorion Pro',
          revampText(
            context,
            en: 'Your subscription is active and managed by Apple.',
            zh: '订阅已生效，并由 Apple 管理。',
          ),
          Icons.workspace_premium_rounded,
          JXB.brandTint,
        ),
      AccessLevel.starter => (
          revampText(context, en: 'Starter', zh: 'Starter 免费版'),
          revampText(
            context,
            en: 'Your memories and previous recordings remain available.',
            zh: '你的记忆和历史录音会继续保留。',
          ),
          Icons.favorite_outline_rounded,
          JXB.warningTint,
        ),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: JXB.border),
        boxShadow: JXB.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
            child: Icon(icon, color: JXB.brandPrimary, size: 23),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: const TextStyle(
              fontFamily: JXB.fontSans,
              fontSize: 23,
              fontWeight: FontWeight.w700,
              color: JXB.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(detail, style: JXB.bodySmall),
          if (response.accessLevel == AccessLevel.foundingTrial && !response.canPurchase) ...[
            const SizedBox(height: 14),
            Text(
              revampText(
                context,
                en: 'Subscription options will appear during the final 14 days.',
                zh: '订阅选项会在体验期最后 14 天出现。',
              ),
              style: const TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 12,
                color: JXB.textPlaceholder,
              ),
            ),
          ],
          if (response.accessLevel == AccessLevel.foundingTrial && response.canPurchase) ...[
            const SizedBox(height: 14),
            Text(
              revampText(
                context,
                en: 'Purchasing now starts Apple billing immediately.',
                zh: '现在购买会立即开始由 Apple 计费。',
              ),
              style: const TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 12,
                color: JXB.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _benefitsComparison(
    BuildContext context,
    UserSubscriptionResponse response,
  ) {
    final hasProBenefits = switch (response.accessLevel) {
      AccessLevel.legacyUnlimited || AccessLevel.foundingTrial || AccessLevel.pro => true,
      AccessLevel.trialAvailable || AccessLevel.starter => false,
    };
    final starterCloudAllowance = _formatStarterAllowance(
      context,
      response.starterTranscriptionSecondsLimit,
    );

    return Column(
      children: [
        _benefitCard(
          context,
          title: revampText(context, en: 'Starter', zh: 'Starter 免费版'),
          subtitle: revampText(
            context,
            en: 'Free, with a monthly cloud allowance',
            zh: '免费使用，包含每月云端额度',
          ),
          icon: Icons.favorite_outline_rounded,
          isCurrent: !hasProBenefits,
          benefits: [
            revampText(
              context,
              en: 'Unlimited on-device transcription',
              zh: '不限量本机离线转录',
            ),
            revampText(
              context,
              en: '$starterCloudAllowance of cloud transcription each month',
              zh: '每月 $starterCloudAllowance云端转录',
            ),
            revampText(
              context,
              en: 'AI insights and memories for included recordings',
              zh: '为额度内录音生成 AI 洞察与记忆',
            ),
            revampText(
              context,
              en: 'Keep your memories and recording history',
              zh: '持续保留记忆与历史录音',
            ),
          ],
        ),
        const SizedBox(height: 10),
        _benefitCard(
          context,
          title: revampText(context, en: 'Memorion Pro', zh: 'Memorion Pro'),
          subtitle: revampText(
            context,
            en: 'No monthly cloud limit',
            zh: '云端处理不设每月额度',
          ),
          icon: Icons.workspace_premium_rounded,
          isCurrent: hasProBenefits,
          emphasized: true,
          benefits: [
            revampText(
              context,
              en: 'Everything in Starter',
              zh: '包含 Starter 全部权益',
            ),
            revampText(
              context,
              en: 'Unlimited cloud transcription',
              zh: '无限云端转录',
            ),
            revampText(
              context,
              en: 'Unlimited AI insights and memories',
              zh: '无限 AI 洞察与记忆',
            ),
          ],
        ),
      ],
    );
  }

  String _formatStarterAllowance(BuildContext context, int seconds) {
    final minutes = seconds <= 0 ? 0 : (seconds + 59) ~/ 60;
    if (minutes > 0 && minutes % 60 == 0) {
      final hours = minutes ~/ 60;
      return revampText(
        context,
        en: '$hours ${hours == 1 ? 'hour' : 'hours'}',
        zh: '$hours 小时',
      );
    }
    return revampText(
      context,
      en: '$minutes minutes',
      zh: '$minutes 分钟',
    );
  }

  Widget _benefitCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isCurrent,
    required List<String> benefits,
    bool emphasized = false,
  }) {
    final accent = emphasized ? JXB.brandPrimary : JXB.textSecondary;
    return Container(
      key: ValueKey('subscription-benefits-${emphasized ? 'pro' : 'starter'}'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: emphasized ? JXB.brandTintFaint : JXB.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isCurrent ? accent : JXB.border,
          width: isCurrent ? 1.5 : 1,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 4,
            child: ColoredBox(
              color: emphasized ? JXB.brandPrimary : JXB.border,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: emphasized ? JXB.brandTint : JXB.bgApp,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, size: 18, color: accent),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontFamily: JXB.fontSans,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: JXB.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(subtitle, style: JXB.caption),
                        ],
                      ),
                    ),
                    if (isCurrent)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: emphasized ? JXB.brandTint : JXB.bgApp,
                          borderRadius: BorderRadius.circular(JXB.radiusFull),
                        ),
                        child: Text(
                          revampText(
                            context,
                            en: 'Your benefits',
                            zh: '当前权益',
                          ),
                          style: TextStyle(
                            fontFamily: JXB.fontSans,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: accent,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                ...benefits.map(
                  (benefit) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          size: 17,
                          color: accent,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            benefit,
                            style: const TextStyle(
                              fontFamily: JXB.fontSans,
                              fontSize: 13,
                              height: 1.35,
                              color: JXB.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _planCard(
    BuildContext context,
    PurchaseProvider purchases, {
    required String productId,
    required String title,
    required String note,
    bool emphasized = false,
  }) {
    final product = purchases.product(productId);
    final enabled = product != null && !purchases.purchasePending;
    return GestureDetector(
      onTap: enabled ? () => purchases.buy(productId) : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: JXB.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: emphasized ? JXB.brandPrimary : JXB.border,
            width: emphasized ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 5,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontFamily: JXB.fontSans,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: JXB.textPrimary,
                        ),
                      ),
                      if (emphasized) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: JXB.brandTint,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            revampText(context, en: 'Best value', zh: '更划算'),
                            style: const TextStyle(
                              fontFamily: JXB.fontSans,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: JXB.brandPrimary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(note, style: JXB.caption),
                  const SizedBox(height: 8),
                  Text(
                    product?.price ??
                        (purchases.loading
                            ? revampText(context, en: 'Loading App Store price…', zh: '正在获取 App Store 价格…')
                            : revampText(context, en: 'Price unavailable', zh: '价格暂不可用')),
                    style: const TextStyle(
                      fontFamily: JXB.fontNumber,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: JXB.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              Icons.chevron_right_rounded,
              color: enabled ? JXB.brandPrimary : JXB.textPlaceholder,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, {required String en, required String zh}) {
    return Text(
      revampText(context, en: en, zh: zh),
      style: const TextStyle(
        fontFamily: JXB.fontSans,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: JXB.textSecondary,
      ),
    );
  }

  Widget _outlineButton(BuildContext context, {required String label, required VoidCallback onTap}) {
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: JXB.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          backgroundColor: JXB.surface,
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: JXB.fontSans,
            fontWeight: FontWeight.w600,
            color: JXB.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _legalLink(BuildContext context, String label, String url) {
    return GestureDetector(
      onTap: () => _open(url),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: JXB.fontSans,
          fontSize: 11,
          color: JXB.brandPrimary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}
