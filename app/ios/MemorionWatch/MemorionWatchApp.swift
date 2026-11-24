import SwiftUI
#if targetEnvironment(simulator)
import AVFoundation
import WidgetKit
#endif

/// Launch snapshots must not carry a previous recording's timer or status.
/// Keep this presentation state independent of microphone/session state.
@MainActor
private final class WatchLaunchPresentation: ObservableObject {
    @Published private(set) var showsSnapshot = true
    private var isActive = false

    func updateScenePhase(_ phase: ScenePhase) {
        isActive = phase == .active
        switch phase {
        case .active: showsSnapshot = false
        case .background: showsSnapshot = true
        case .inactive: break // Wrist-down/temporary inactivity keeps the live UI.
        @unknown default: break
        }
    }

    func prepareSnapshot() {
        // A late background task must not cover an app that already became active.
        guard !isActive else { return }
        showsSnapshot = true
    }
}

/// Observe presentation in a View so snapshot tasks repaint the window even
/// when neither the scene phase nor recording state has changed.
private struct WatchLaunchContainer<Content: View>: View {
    @ObservedObject var presentation: WatchLaunchPresentation
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            content
                .opacity(presentation.showsSnapshot ? 0 : 1)
                .allowsHitTesting(!presentation.showsSnapshot)
                .accessibilityHidden(presentation.showsSnapshot)
            if presentation.showsSnapshot {
                VStack(spacing: 12) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(Color(red: 84/255, green: 164/255, blue: 253/255))
                    Text("Memorion").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .accessibilityIdentifier("watch-launch-snapshot")
            }
        }
        .animation(nil, value: presentation.showsSnapshot)
    }
}

/// Memorion 的 watchOS 端：手动启停录音，落本地，再同步给 iPhone。
///
/// ⚠️ **这是一个纯原生 target，不含任何 Dart。** Flutter 官方不支持 watchOS，所以
/// Watch 端与 `app/lib/` 之间没有任何共享代码 —— 两边的行为要靠人工保持一致。
///
/// ⚠️ **Watch 端刻意完全不联网。** 音频只交给 iPhone，由 iPhone 用它自己那把 API key
/// 上传。原因不是省事：`POST /v1/auth/app-token` 换发 bound key 时会**硬删上一把**，
/// 所以第二个设备一旦自己去 mint key，就会把手机那把撤掉，表现为「手机上某个功能一直
/// 加载失败」而两头都静默。Watch 绝不能拿到 mint key 的能力。
@main
struct MemorionWatchApp: App {
    /// 整个 Watch 端只有这一个 recorder 实例。它同时持有 WCSession 的 delegate，
    /// 而 WCSession 的 delegate 必须在 App 启动时就设好（否则 iPhone 侧的排队消息
    /// 在首次 activate 前会丢），所以它是 App 级别的 StateObject 而不是 View 级别。
    @StateObject private var recorder = WatchRecorder.shared
    @StateObject private var launchPresentation = WatchLaunchPresentation()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        MemorionWatchShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
#if targetEnvironment(simulator)
            if let preview = ProcessInfo.processInfo.environment["MEMORION_WIDGET_PREVIEW"] {
                ControlWidgetPreview(configuration: preview)
            } else { recordingRoot }
#else
            recordingRoot
#endif
        }
        .backgroundTask(.snapshot) { _ in
            await launchPresentation.prepareSnapshot()
            return SnapshotResponse(estimatedSnapshotExpiration: .distantFuture)
        }
    }

    private var recordingRoot: some View {
            WatchLaunchContainer(presentation: launchPresentation) {
                RecorderView(recorder: recorder)
            }
                .onAppear {
                    launchPresentation.updateScenePhase(scenePhase)
                    recorder.handleBecameActive()
                }
                .onChange(of: scenePhase) { _, phase in
                    launchPresentation.updateScenePhase(phase)
                    if phase == .active { recorder.handleBecameActive() }
                    if phase == .background { recorder.handleWentBackground() }
                }
#if targetEnvironment(simulator)
                .simulatorTypography()
                .onAppear(perform: Self.autoInjectIfRequested(recorder))
                .onAppear(perform: Self.autoRecordIfRequested(recorder))
                .onAppear(perform: Self.simulatorFlowIfRequested(recorder, launchPresentation))
#endif
    }

#if targetEnvironment(simulator)
    /// 让「注入示例音频」这个按钮**也能从命令行按下**：
    ///
    /// ```sh
    /// SIMCTL_CHILD_MEMORION_INJECT_FIXTURE=1 xcrun simctl launch \
    ///   --terminate-running-process <watch-udid> me.memorion.api.watchkitapp
    /// ```
    ///
    /// These flags exercise the native Watch simulator directly. An iPhone UI
    /// automation result does not establish that the Watch screen was tested.
    ///
    /// 整段包在 `#if targetEnvironment(simulator)` 里，真机与 App Store 构建里不存在。
    private static func autoInjectIfRequested(_ recorder: WatchRecorder) -> () -> Void {
        return {
            guard ProcessInfo.processInfo.environment["MEMORION_INJECT_FIXTURE"] == "1" else { return }
            NSLog("[Fixture] MEMORION_INJECT_FIXTURE=1 — injecting on launch")
            recorder.injectFixture()
        }
    }

    /// Simulator-only smoke probe: repeat quick entry, optionally mark, then stop at nine seconds.
    private static func autoRecordIfRequested(_ recorder: WatchRecorder) -> () -> Void {
        return {
            guard ProcessInfo.processInfo.environment["MEMORION_AUTO_RECORD"] == "1" else { return }
            NSLog("[AutoRecord] MEMORION_AUTO_RECORD=1 — starting on launch")
            recorder.startRecording()
            for seconds in [2.0, 6.0, 8.0, 12.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    if seconds == 2 || seconds == 6 {
                        recorder.startFromQuickEntry() // Duplicate quick entries must never toggle capture off.
                        if ProcessInfo.processInfo.environment["MEMORION_AUTO_MARK"] == "1" { recorder.markMoment() }
                    }
                    recorder.refreshPending() // Foreground/transfer refreshes must exclude the open capture.
                    NSLog("[AutoRecord] t=\(Int(seconds))s capturing=\(recorder.isRecording) requested=\(recorder.recordingRequested) elapsed=\(Int(recorder.elapsed)) marks=\(recorder.markCount) pending=\(recorder.pending.count)")
                }
            }
            // Explicit stop lets the probe inspect the finalized audio and metadata.
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
                NSLog("[AutoRecord] stopping")
                recorder.stopRecording()
            }
        }
    }

    private static var didStartSimulatorFlow = false
    /// Programmatic navigation and interruption injection, with actual microphone
    /// capture and durable files. This is a simulator regression, not a tap/gesture test.
    private static func simulatorFlowIfRequested(_ recorder: WatchRecorder,
                                                _ presentation: WatchLaunchPresentation) -> () -> Void {
        return {
            guard let flow = ProcessInfo.processInfo.environment["MEMORION_SIM_FLOW"],
                  !didStartSimulatorFlow else { return }
            didStartSimulatorFlow = true
            var events: [[String: Any]] = []
            var shortcutResults: [String: String] = [:]
            let output = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("watch-simulator-flow.json")
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            @MainActor func snapshot(_ stage: String) {
                var event = recorder.simulatorSnapshot(stage)
                event["showsLaunchSnapshot"] = presentation.showsSnapshot
                event["shortcutResults"] = shortcutResults
                events.append(event)
                if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted]) {
                    try? data.write(to: output, options: .atomic)
                }
                NSLog("[SimulatorFlow] %@ capturing=%d requested=%d route=%@", stage,
                      recorder.isRecording, recorder.recordingRequested, recorder.simulatorRoute)
            }
            @MainActor func step(_ seconds: Double, _ name: String, _ action: @escaping @MainActor () -> Void) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    action()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { snapshot(name) }
                }
            }
            func navigate(_ route: String) {
                NotificationCenter.default.post(name: Notification.Name("memorion.simulator.navigate"),
                                                object: nil, userInfo: ["route": route])
            }
            snapshot("idle")
            if flow == "launch-snapshot" {
                // Inject presentation lifecycle only. Capture, intents, audio files
                // and the rendered views remain real; OS snapshot timing is separate.
                step(1, "snapshot-started") { Task { _ = try? await StartWatchRecordingIntent().perform() } }
                step(3, "snapshot-inactive") { presentation.updateScenePhase(.inactive) }
                step(5, "snapshot-prepared") { presentation.prepareSnapshot() }
                step(7, "snapshot-restored") {
                    presentation.updateScenePhase(.active)
                    recorder.handleBecameActive()
                }
                step(9, "snapshot-late-task") { presentation.prepareSnapshot() }
                step(11, "snapshot-marked") { recorder.markMoment() }
                step(13, "snapshot-background") {
                    presentation.updateScenePhase(.background)
                    recorder.handleWentBackground()
                }
                step(15, "snapshot-stopped") { recorder.stopRecording() }
                step(17, "snapshot-prelaunch") { presentation.updateScenePhase(.inactive) }
                step(19, "snapshot-foreground") {
                    presentation.updateScenePhase(.active)
                    recorder.handleBecameActive()
                }
                step(20, "snapshot-restarted") { Task { _ = try? await StartWatchRecordingIntent().perform() } }
                step(22, "snapshot-new-stopped") { recorder.stopRecording() }
                step(24, "saved-queue") { }
                return
            }
            if flow == "permission-denied" {
                step(1, "denied") {
                    Task {
                        do {
                            _ = try await StartWatchRecordingIntent().perform()
                            shortcutResults["permission"] = "success"
                        } catch { shortcutResults["permission"] = "failed" }
                        snapshot("permission-result")
                    }
                }
                step(6, "stopped") { recorder.stopRecording() }
                return
            }
            if flow == "shortcut-activation" {
                func startShortcut(_ key: String) {
                    Task { @MainActor in
                        do {
                            _ = try await StartWatchRecordingIntent().perform()
                            shortcutResults[key] = "success"
                        } catch { shortcutResults[key] = "failed" }
                        snapshot("result-" + key)
                    }
                }
                step(1, "pending-cancel") {
                    recorder.simulatorAppActiveOverride = false
                    startShortcut("cancelled")
                }
                step(2, "cancelled") { Task { _ = try? await StopWatchRecordingIntent().perform() } }
                step(3, "active-after-cancel") { recorder.simulatorAppActiveOverride = true }
                step(3.5, "previous-failure") {
                    recorder.simulatorFailNextAudioActivation = true
                    startShortcut("previous-failure")
                }
                step(4, "pending-recovery") {
                    recorder.simulatorAppActiveOverride = false
                    startShortcut("recovered")
                    startShortcut("duplicate")
                }
                step(6, "recovered-without-callback") {
                    // Only the OS state changes: deliberately omit SwiftUI's
                    // activation callback to exercise the production fallback.
                    recorder.simulatorAppActiveOverride = true
                }
                step(8, "background-repeat") {
                    recorder.simulatorAppActiveOverride = false
                    startShortcut("background-repeat")
                }
                step(9, "background-stopped") { Task { _ = try? await StopWatchRecordingIntent().perform() } }
                step(10, "active-after-stop") { recorder.simulatorAppActiveOverride = true }
                step(11, "pending-timeout") {
                    recorder.simulatorAppActiveOverride = false
                    startShortcut("timeout")
                }
                step(20, "timeout-preserved") { }
                step(21, "late-foreground") {
                    recorder.simulatorAppActiveOverride = nil
                    recorder.handleBecameActive()
                }
                step(23, "stopped") { Task { _ = try? await StopWatchRecordingIntent().perform() } }
                step(25, "saved-queue") { }
                return
            }
            if flow == "quick-entry-lifecycle" {
                // Inject scene timing only; the intent and microphone remain real.
                step(1, "deferred") {
                    recorder.simulatorAppActiveOverride = false
                    Task { _ = try? await StartWatchRecordingIntent().perform() }
                }
                step(2, "cancelled") { recorder.stopRecording() }
                step(3, "active-after-cancel") {
                    recorder.simulatorAppActiveOverride = nil
                    recorder.handleBecameActive()
                }
                step(4, "queued-twice") {
                    recorder.simulatorAppActiveOverride = false
                    Task {
                        _ = try? await StartWatchRecordingIntent().perform()
                        _ = try? await StartWatchRecordingIntent().perform()
                    }
                }
                step(6, "foreground-started") {
                    recorder.simulatorAppActiveOverride = nil
                    recorder.handleBecameActive()
                }
                step(8, "background-repeat") {
                    recorder.simulatorAppActiveOverride = false
                    recorder.handleWentBackground()
                    Task { _ = try? await StartWatchRecordingIntent().perform() }
                }
                step(10, "foreground-repeat") {
                    recorder.simulatorAppActiveOverride = nil
                    recorder.handleBecameActive()
                    Task { _ = try? await StartWatchRecordingIntent().perform() }
                }
                step(12, "stopped") { recorder.stopRecording() }
                step(14, "saved-queue") { navigate("queue") }
                return
            }
            if flow == "recording-controls" {
                var oldSession = ""
                step(1, "control-started") {
                    Task {
                        _ = try? await StartWatchRecordingIntent().perform()
                        oldSession = recorder.simulatorSnapshot("read")["sessionID"] as? String ?? ""
                    }
                }
                step(3, "control-stale-stop") {
                    Task { _ = try? await StopWatchRecordingFromWidgetIntent(sessionID: "old-unrelated-session").perform() }
                }
                step(5, "control-stopped") { Task { _ = try? await StopWatchRecordingIntent().perform() } }
                step(7, "control-stop-again") { Task { _ = try? await StopWatchRecordingIntent().perform() } }
                step(9, "control-restarted") { Task { _ = try? await StartWatchRecordingIntent().perform() } }
                step(11, "control-old-session") {
                    Task { _ = try? await StopWatchRecordingFromWidgetIntent(sessionID: oldSession).perform() }
                }
                step(13, "control-bound-stopped") {
                    let session = recorder.simulatorSnapshot("read")["sessionID"] as? String ?? ""
                    Task { _ = try? await StopWatchRecordingFromWidgetIntent(sessionID: session).perform() }
                }
                step(15, "saved-queue") { }
                return
            }
            if flow == "control-urls" {
                // simctl openurl rejects Watch URLs (LS error 115). Exercise the
                // production onOpenURL handler; physical face delivery is separate.
                step(2, "url-started") { recorder.handleQuickEntryURL(URL(string: "memorion-watch://record")!) }
                step(4, "url-repeated") { recorder.handleQuickEntryURL(URL(string: "memorion-watch://record")!) }
                step(6, "url-stopped") {
                    let session = recorder.simulatorSnapshot("read")["sessionID"] as? String ?? ""
                    recorder.handleQuickEntryURL(URL(string: "memorion-watch://stop?session=" + session)!)
                }
                step(8, "saved-queue") { }
                return
            }
            guard flow == "recording" else { return }
            step(1, "started") {
                Task { _ = try? await StartWatchRecordingIntent().perform() }
            }
            step(3, "marked") { recorder.markMoment() }
            step(5, "moments") { navigate("moments") }
            step(7, "detail") { navigate("detail") }
            step(9, "queue") { navigate("queue") }
            step(11, "quick-entry") { recorder.startFromQuickEntry() }
            step(13, "interrupted") {
                NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                    object: AVAudioSession.sharedInstance(),
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            }
            step(16.5, "resumed") {
                NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                    object: AVAudioSession.sharedInstance(),
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                               AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
                recorder.handleBecameActive()
            }
            step(18, "marked-again") { recorder.markMoment() }
            step(21, "stopped") { recorder.stopRecording() }
            step(23, "saved-queue") { navigate("queue") }
        }
    }
#endif
}

#if targetEnvironment(simulator)
private extension View {
    @ViewBuilder func simulatorTypography() -> some View {
        if ProcessInfo.processInfo.environment["MEMORION_SIM_LARGE_TEXT"] == "1" {
            self.environment(\.dynamicTypeSize, .accessibility5)
        } else { self }
    }
}
#endif

#if targetEnvironment(simulator)
private struct ControlWidgetPreview: View {
    let configuration: String
    var body: some View {
        let parts = configuration.split(separator: ":").map(String.init)
        let phase = WatchRecordingControlState.Phase(rawValue: parts.first ?? "idle") ?? .idle
        let family: WidgetFamily = parts.count > 1 && parts[1] == "circular" ? .accessoryCircular :
            (parts.count > 1 && parts[1] == "inline" ? .accessoryInline : .accessoryRectangular)
        let mode: RecordingControlMode = parts.last == "stop" ? .stop : (parts.last == "start" ? .start : .adaptive)
        RecordingWidgetView(familyOverride: family,
            state: WatchRecordingControlState(phase: phase, sessionID: phase == .idle ? nil : "preview"), mode: mode)
            .padding(12)
    }
}
#endif
