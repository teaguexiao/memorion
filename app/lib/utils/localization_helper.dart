import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/main.dart';

/// 在没有 BuildContext 的地方（比如 Provider）获取本地化字符串。
/// 使用全局 navigatorKey 提供的 context。
///
/// 用法：
///   final s = appS();
///   if (s != null) {
///     showError(s.errorNetworkUnavailable);
///   } else {
///     showError('Network unavailable');
///   }
S? appS() {
  final ctx = MyApp.navigatorKey.currentContext;
  if (ctx == null) return null;
  try {
    return S.of(ctx);
  } catch (_) {
    return null;
  }
}

/// 与 [appS] 类似，但提供英文 fallback，永远不返回 null。
String appT(String Function(S s) lookup, String fallback) {
  final s = appS();
  if (s == null) return fallback;
  try {
    return lookup(s);
  } catch (_) {
    return fallback;
  }
}
