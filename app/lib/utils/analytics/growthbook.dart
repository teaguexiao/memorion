/// Feature flag 封装（GrowthBook）。
///
/// 2026-07：GrowthBook SDK 已从项目移除，本类保留为 no-op 空壳。
/// feature flag 走本地默认值（与此前未配置 apiKey 时的运行时行为一致：
/// displayFeedback / displayMemoriesSearchBar 默认 false）。
/// 未来若恢复远程开关，重新引入 SDK 并在 init/feature 处接回即可。
class GrowthbookUtil {
  static final GrowthbookUtil _instance = GrowthbookUtil._internal();

  factory GrowthbookUtil() {
    return _instance;
  }

  GrowthbookUtil._internal();

  static Future<void> init() async {
    // no-op：GrowthBook SDK 已移除。
  }

  bool displayFeedback() => false;

  bool displayMemoriesSearchBar() => false;

  bool isFeedbackEnabled() {
    // 与旧行为一致：无远程开关时视为关闭。
    return false;
  }
}
