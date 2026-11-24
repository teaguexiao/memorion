import 'package:flutter/material.dart';
import 'package:memorion/backend/http/api/calendar.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// 日程数据离开设备前的明确同意。
///
/// ## 为什么需要一个独立于系统权限的同意
///
/// iOS 的日历权限弹窗只表达一件事：用户允许 App **读取本机日历**。它不表达
/// "允许把日程上传到 Memorion 的服务器"，更不表达"允许转交给第三方 AI 供应商"。
/// App Review Guideline 5.1.2(i)（2025-11-13 新增）原文要求：
///
/// > You must clearly disclose where personal data will be shared with third
/// > parties, **including with third-party AI**, and obtain explicit permission
/// > before doing so.
///
/// 实际拒审信把它拆成四项硬要求：披露发送什么、指明发给谁、事前取得许可、
/// 隐私政策涵盖。这个 sheet 负责前三项。
///
/// ## 三个刻意的设计约束
///
/// 1. **默认不同意**，且未同意时 `CalendarSyncService` 一条都不传。
/// 2. **没有"下次再说就当同意"**：只有点确认按钮才写入 true。用 barrier dismiss
///    或取消都算未同意——不做"看过即视为同意"，那会让同意形同虚设。
/// 3. **可撤回**：`revoke()` 与 `ensure()` 对称，撤回路径和给予一样容易
///    （5.1.1(ii) 与 GDPR Art. 7(3) 都要求这一点）。
///
/// ## 真相源在服务端，本地只是缓存
///
/// 这份同意曾经只存在 `shared_preferences` 里，结果它和系统日历权限的存活范围
/// 不一致：系统权限记在 iOS 侧（TCC，跨 App 更新保留），本地这份跟着 App 沙盒走
/// （删除重装即丢，登出也会被 `clearUserPreferences` 清掉）。于是重装后授权页
/// 的日历开关显示"关"、提醒事项显示"开"—— 提醒事项只读系统权限，而日历还多
/// 依赖了这个本地标记。用户看到的是"每次装新版日历都要重开"，看起来像 iOS
/// 权限 bug，实际是本地状态丢了，而服务器上此前同步的日程都还在。
///
/// 所以同意状态记在服务端、跟着账号走：`refreshFromServer()` 回读，
/// `ensure()`/`revoke()` 上报。换账号自然是另一个人的记录，仍会重新询问。
class CalendarAiConsent {
  /// 送给 AI 供应商处理的供应商名单。
  ///
  /// **必须点名而非只说"第三方 AI 服务"** —— 实际拒审案例里，只写类别的被拒，
  /// 点名的过审；GDPR 侧 EDPB 透明度指引（WP260）同样要求 "generally the
  /// named recipients"。改动供应商时这里和隐私政策要一起改。
  static const providers = 'OpenAI · Anthropic · AWS Bedrock';

  /// 用户是否已同意（本地缓存值，同步读取）。
  ///
  /// 同步 getter 是刻意的：`CalendarSyncService` 的闸门要在任何网络动作**之前**
  /// 拦住上传，不能自己先去发一个请求。缓存的新鲜度由 `refreshFromServer()` 负责。
  static bool get granted => SharedPreferencesUtil().calendarAiConsentGranted;

  static void _set(bool value) => SharedPreferencesUtil().calendarAiConsentGranted = value;

  /// 从服务端回读同意状态并更新本地缓存，返回最新值。
  ///
  /// 两种"读不到"都**保持本地不变**（返回当前缓存）：
  /// - 请求失败 —— 把它当成"没同意"会在网络差时凭空撤回用户的同意；
  /// - `consentGranted == null` —— 后端还没上这个字段。App 与后端的上线顺序保证
  ///   不了，把缺字段当成 false 会在新 App 碰上旧后端时把所有人的开关打成关。
  static Future<bool> refreshFromServer() async {
    final state = await fetchCalendarSyncState();
    final remote = state?.consentGranted;
    if (remote == null) return granted;
    _set(remote);
    return remote;
  }

  /// 撤回同意 —— 服务端会在同一次请求里删掉已同步的日程。
  ///
  /// 返回是否成功。失败时本地状态**不动**：显示成已撤回而服务端还允许同步，
  /// 等于骗用户数据已经删了。
  static Future<bool> revoke() async {
    final ok = await setCalendarConsent(false);
    if (ok) _set(false);
    return ok;
  }

  /// 已同意则直接返回 granted，否则弹出说明并等用户决定。
  ///
  /// ⚠️ **只有服务端记下了才算同意**：上报失败返回 [CalendarConsentOutcome.failed]
  /// 且不写本地。否则会出现本地已同意、服务端未记录的分裂状态 —— 那时同步会被
  /// 服务端的闸门 409 挡掉，而界面显示开关是开的，用户只看到"开了但一直没同步"。
  ///
  /// 三态而不是 bool：`declined` 与 `failed` 对调用方是两回事，前者什么都不该说
  /// （用户刚亲手拒绝），后者必须提示重试，否则点了"同意并同步"却毫无反应。
  static Future<CalendarConsentOutcome> ensure(BuildContext context) async {
    if (granted) return CalendarConsentOutcome.granted;

    final agreed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // 拖动关闭 == 未同意，与点取消同义。
      builder: (ctx) => const _ConsentSheet(),
    );

    if (agreed != true) {
      // 记下明确的拒绝，好让 resolveIfUndecided 不再每次启动去问服务端。
      _set(false);
      return CalendarConsentOutcome.declined;
    }

    if (!await setCalendarConsent(true)) return CalendarConsentOutcome.failed;
    _set(true);
    return CalendarConsentOutcome.granted;
  }
}

/// `CalendarAiConsent.ensure` 的结果。
enum CalendarConsentOutcome {
  granted,

  /// 用户按了"暂不同意"或划走了弹窗。
  declined,

  /// 用户同意了，但没能上报到服务端（网络失败等），本次不算同意。
  failed,
}

class _ConsentSheet extends StatelessWidget {
  const _ConsentSheet();

  @override
  Widget build(BuildContext context) {
    final zh = isRevampChinese(context);
    return Container(
      decoration: const BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 20),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(999)),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                revampText(context, en: 'Sync your schedule to Memorion?', zh: '把日程同步到 Memorion？'),
                style: const TextStyle(
                    fontFamily: JXB.fontSans, fontSize: 19, fontWeight: FontWeight.w700, color: JXB.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                revampText(context,
                    en: 'So Ask can answer questions about your schedule, your calendar events are stored on Memorion\'s servers and processed by AI providers.',
                    zh: '为了让 Ask 能回答你的行程问题，日程会存放在 Memorion 的服务器上，并交由 AI 服务商处理。'), // i18n-ignore: revampText 已双语
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.55, color: JXB.textSecondary),
              ),
              const SizedBox(height: 18),
              _block(
                context,
                label: revampText(context, en: 'What is sent', zh: '会发送什么'),
                body: revampText(context,
                    en: 'Event title, start and end time, location, and which calendar it came from.',
                    zh: '日程标题、开始与结束时间、地点，以及来自哪个日历。'),
              ),
              const SizedBox(height: 14),
              _block(
                context,
                label: revampText(context, en: 'What is never read', zh: '永远不会读取'),
                body: revampText(context,
                    en: 'Event notes, attendees, and meeting links. Memorion never adds, edits, or deletes calendar events.',
                    zh: '日程备注、参会人和会议链接。Memorion 也不会新增、修改或删除任何日程。'), // i18n-ignore: revampText 已双语
              ),
              const SizedBox(height: 14),
              _block(
                context,
                label: revampText(context, en: 'Who processes it', zh: '由谁处理'),
                body: revampText(context,
                    en: '${CalendarAiConsent.providers} — acting only as data processors. They are contractually prohibited from training their models on your data.',
                    zh: '${CalendarAiConsent.providers} —— 仅作为数据处理方。合同禁止它们用你的数据训练模型。'),
              ),
              const SizedBox(height: 14),
              _block(
                context,
                label: revampText(context, en: 'You stay in control', zh: '随时可撤回'),
                body: revampText(context,
                    en: 'Turn the calendar toggle off anytime and the synced events are deleted from our servers.',
                    zh: '随时关闭日历开关，已同步的日程会从我们的服务器删除。'),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _button(
                      context,
                      label: revampText(context, en: 'Not now', zh: '暂不同意'),
                      bg: const Color(0xFFF2F4F7),
                      fg: JXB.textPrimary,
                      onTap: () => Navigator.pop(context, false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _button(
                      context,
                      label: revampText(context, en: 'Agree & sync', zh: '同意并同步'),
                      bg: JXB.brandPrimary,
                      fg: Colors.white,
                      onTap: () => Navigator.pop(context, true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // 不做成 checkbox 前置条件：多一道勾选只是增加摩擦，同意的实质在于
              // 用户看到了上面四段说明后主动点了确认按钮。
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    zh ? '不同意也可以继续使用 Memorion 的其他功能。' : 'You can keep using the rest of Memorion either way.', // i18n-ignore: 三元已双语
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _block(BuildContext context, {required String label, required String body}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
        const SizedBox(height: 4),
        Text(body,
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, height: 1.5, color: JXB.textSecondary)),
      ],
    );
  }

  Widget _button(BuildContext context,
      {required String label, required Color bg, required Color fg, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(label,
            style: TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: fg)),
      ),
    );
  }
}
