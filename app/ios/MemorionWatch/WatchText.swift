import Foundation
import WatchConnectivity

/// Watch 端的中英取词，对应 Flutter 侧的 `revampText(context, en:, zh:)`
/// （`app/lib/utils/revamp_text.dart`）。
///
/// ⚠️ **不能只看系统语言。** App 里有一个**手动语言开关**
/// （`LocaleProvider` → `SharedPreferencesUtil().uiLocale`），把它设成中文的英文系统用户
/// 在手机上看到的是中文；Watch 若只读 `Locale.preferredLanguages`，同一个人的手腕上会是
/// 英文。所以优先用 iPhone 通过 `updateApplicationContext` 下发的 `uiLocale`。
///
/// `receivedApplicationContext` 由系统持久化、跨 App 重启存活，所以这里不需要自己落盘，
/// 也不需要等 iPhone 可达。
///
/// ⚠️ 这些 Swift 文案**不受 pre-commit 的 i18n 双向守卫保护** ——
/// `.claude/hooks/check_app_i18n.py:241` 只扫 `app/lib/**.dart`。也就是说在 Watch 端漏掉
/// 英文对照不会被任何东西拦下，而这正是 `about_page.dart` 整页中文上线很久的那个形态。
/// **新增 Watch 文案一律走 `WatchText.pick`，不要写裸字面量。**
enum WatchText {
    /// iPhone 下发 UI 语言时用的 key。iPhone 侧必须用同一个字符串
    /// （见 `ios/Runner/WatchSessionService.swift`）。
    static let localeKey = "uiLocale"

    static func pick(en: String, zh: String) -> String {
        isChinese ? zh : en
    }

    static var isChinese: Bool {
        if let pushed = pushedLocaleCode, !pushed.isEmpty {
            return pushed.lowercased().hasPrefix("zh")
        }
        // 回退：跟随系统。iPhone 还没同步过来时（首次安装、从未配对成功）就是这一支。
        let system = Locale.preferredLanguages.first ?? "en"
        return system.lowercased().hasPrefix("zh")
    }

    private static var pushedLocaleCode: String? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default.receivedApplicationContext[localeKey] as? String
    }
}
