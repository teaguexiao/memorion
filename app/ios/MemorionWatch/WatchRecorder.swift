import AVFoundation
import Combine
import Foundation
import WatchKit
import WidgetKit

/// One app-owned recorder. UI navigation and transfer never govern microphone lifetime.
/// Active capture may continue in the background; watchOS can refuse reactivation
/// after a call, Siri, or process suspension. Keep user intent and resume in the
/// foreground when permitted, while showing the actual interrupted state.
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    static let shared = WatchRecorder()
    enum Phase: Equatable {
        case idle
        case recording
        /// 上一次操作的结果，供 UI 展示一句话。
        case failed(String)
    }

    /// Bound individual files without restarting on every wrist-down event.
    private static let rotateAfterSeconds: TimeInterval = 55 * 60

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var recordingRequested = false
    @Published private(set) var quickEntryGeneration = 0
    @Published private(set) var interruptedReason: String?
    @Published private(set) var markCount = 0
    @Published private(set) var lastSavedDuration: TimeInterval = 0

    private static let sessionDefaultsKey = "memorion.watch.recordingSession.v1"
    private var recordingSession: WatchRecordingSession?
    @Published private(set) var requestingPermission = false
    @Published private(set) var pending: [PendingRecording] = []
    /// 给用户看的一句话状态。nil 表示没什么要说的。
    @Published private(set) var notice: String? {
        didSet { noticeIsSyncProgress = false }
    }
    private var noticeIsSyncProgress = false
    private var receiptCleanupFailures = Set<String>()
    private var transferFailures: [String: String] = [:]

    /// 系统队列里的传输条数；不代表正在发送，也不能代替手机回执。
    ///
    /// ⚠️ **这是「点了到底有没有反应」唯一能看见的证据。** 待同步列表只在 iPhone 回执后才
    /// 变短（删除只认 App 级回执），而投递时机完全由系统决定 —— 实测有过 42 分钟才到的。
    /// 少了这个数，「已入队、正在等 iPhone」和「什么都没发生」在界面上完全一样，
    /// 用户只能得出「点了没反应」的结论（2026-08-15 用户报的就是这句）。
    @Published private(set) var inFlightCount = 0

    /// iPhone 此刻能不能被叫醒（`WCSession.isReachable`）。
    ///
    /// ⚠️ **不可达 ≠ 同步失败**：`transferFile` 是排队式的，连上就会送。这个值只用来解释
    /// 「为什么还没送到」—— 不许拿它去挡入队，也不许因此显示任何失败字样。
    @Published private(set) var companionReachable = false

    @Published private(set) var moments: [WatchMoment] = []
    private let momentStore = WatchMomentStore()
    var todayReadyCount: Int { moments.filter { $0.isReady && Calendar.current.isDateInToday($0.date) }.count }

    private let store = PendingRecordingStore()
    private let transfer = WatchTransfer()

    private var recorder: AVAudioRecorder?
    private var tickTimer: Timer?
    private var currentURL: URL?
    private var currentStartedAt: Date?
    private let controlStore = WatchRecordingControlStore()
    private var foregroundRetryTimer: Timer?
    private var foregroundRetryDeadline: Date?
    private static let shortcutActivationTimeout: TimeInterval = 8

    private struct ShortcutRecordingError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func publishControlState(forceReload: Bool = false, leaseRetry: Int = 0) {
        let controlPhase: WatchRecordingControlState.Phase
        if !recordingRequested { controlPhase = .idle }
        else if isRecording { controlPhase = .recording }
        else if case .failed = phase { controlPhase = .unconfirmed }
        else { controlPhase = .paused }
        let state = WatchRecordingControlState(
            phase: controlPhase,
            sessionID: recordingRequested ? recordingSession?.id : nil)
        do {
            let changed = try controlStore.publish(state)
            if changed || forceReload {
                for kind in WatchRecordingControlStore.widgetKinds {
                    WidgetCenter.shared.reloadTimelines(ofKind: kind)
                }
            }
        } catch {
            NSLog("[WatchRecorder] control state publication failed: %@", error.localizedDescription)
            // A timeline read briefly probes the lease after an app crash. Retry
            // without blocking the main thread, and publish the current state then.
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileLocking.rawValue && leaseRetry < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.publishControlState(forceReload: true, leaseRetry: leaseRetry + 1)
                }
            }
        }
    }

#if targetEnvironment(simulator)
    var simulatorRoute = "root"
    var simulatorAppActiveOverride: Bool?
    var simulatorFailNextAudioActivation = false
    func simulatorSnapshot(_ stage: String) -> [String: Any] {
        ["stage": stage, "capturing": isRecording, "requested": recordingRequested,
         "elapsed": elapsed, "marks": markCount, "pending": pending.count,
         "route": simulatorRoute, "captureFile": currentURL?.lastPathComponent ?? "",
         "sessionID": recordingSession?.id ?? "", "status": recordingStatusText,
         "appActive": appIsActive,
         "controlPhase": WatchRecordingControlStore().read().phase.rawValue,
         "saved": pending.compactMap { audio -> [String: Any]? in
             guard let metadata = WatchRecordingMetadata.load(for: audio.url) else { return nil }
             return ["file": audio.id, "duration": metadata.durationSeconds,
                     "marks": metadata.marks.count, "sessionID": metadata.sessionID]
         }]
    }
#endif

    override init() {
        super.init()
        moments = momentStore.moments
        transfer.onApplicationContext = { [weak self] context in
            guard let self, let json = context["watchMoments"] as? String,
                  let data = json.data(using: .utf8),
                  let incoming = try? JSONDecoder().decode([WatchMoment].self, from: data) else { return }
            self.momentStore.merge(incoming, owner: context["watchMomentsOwner"] as? String)
            self.moments = self.momentStore.moments
        }
        if let data = UserDefaults.standard.data(forKey: Self.sessionDefaultsKey),
           let session = try? JSONDecoder().decode(WatchRecordingSession.self, from: data), session.requested {
            recordingSession = session
            recordingRequested = true
            markCount = session.marks.count
            elapsed = session.completedDuration
            interruptedReason = WatchText.pick(en: "Waiting to resume", zh: "等待继续录音")
        }

        transfer.onDelivered = { [weak self] url in
            guard let self else { return }
            // ⚠️ **刻意什么都不删。** `didFinish(error: nil)` 只说明文件离开了手表并到达
            // 对端设备，不说明 iPhone 的 App 真的收下并落盘了（实测过手表 kNoErr 而手机
            // 收件箱是空的）。删除只认下面的 `onAcknowledged`。
            //
            // 所以文案也不能说「已同步」—— 那一步还没发生，列表里这条会继续留着。
            self.transferFailures.removeValue(forKey: url.lastPathComponent)
            self.refreshPending()
            guard self.notice == nil || self.noticeIsSyncProgress else { return }
            guard self.receiptCleanupFailures.isEmpty, self.transferFailures.isEmpty else {
                self.refreshSyncNotice()
                return
            }
            self.showSyncNotice(WatchText.pick(
                en: "Sent — waiting for your iPhone to confirm.",
                zh: "已送出，等待 iPhone 确认。"
            ))
        }
        transfer.pendingRecordings = { [weak self] in self?.store.pending() ?? [] }
        transfer.onStateChanged = { [weak self] in self?.refreshPending() }
        transfer.onAcknowledged = { [weak self] filename in
            guard let self else { return }
            // iPhone 明确说「我落盘了」。**这是唯一会删掉一条真录音的地方。**
            if let rec = self.store.pending().first(where: { $0.url.lastPathComponent == filename }) {
                if let metadata = WatchRecordingMetadata.load(for: rec.url) {
                    self.momentStore.saveMarks(metadata, recordingKey: filename, status: "waitingForUpload")
                    self.moments = self.momentStore.moments
                }
                self.store.remove(rec)
            }
            self.transferFailures.removeValue(forKey: filename)
            self.refreshPending()
            if self.pending.contains(where: { $0.url.lastPathComponent == filename }) {
                self.receiptCleanupFailures.insert(filename)
            }
            self.refreshSyncNotice()
        }
        transfer.onFailed = { [weak self] url, error in
            guard let self else { return }
            self.transferFailures[url.lastPathComponent] = error.localizedDescription
            self.refreshPending()
            self.refreshSyncNotice()
        }
        transfer.activate()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        // 🚨 **先救回上个进程录到一半的那段，再列举。** watchOS 回收进程时 `stop()` 没机会跑，
        // 那段文件既没收尾、也没记账。ADTS 截掉半截尾帧就能用（见
        // `PendingRecordingStore.fileExtension`），所以它照常入队同步，不再被当成废文件删掉。
        let recoveredSeconds = recoverInterruptedCapture()

        for audio in store.pending() {
            if let metadata = WatchRecordingMetadata.load(for: audio.url),
               metadata.accountId == nil || metadata.accountId == momentStore.owner {
                momentStore.saveMarks(metadata, recordingKey: audio.id,
                    status: PendingRecordingStore.isFinalized(at: audio.url) ? "waitingForPhone" : "audioUnavailable")
            }
        }
        moments = momentStore.moments

        // 其余没收尾的：ADTS 截尾保留；一帧都没有的、以及升级前留下的没有 moov 的 m4a，
        // 只能删掉。不删的话它们会一路传到 iPhone、上传、后端 ffmpeg 解不开返 400，最后落到
        // `rejected/` —— 用户看到的是「N 段无法转录」，一句解释不了原因、也无从下手的话。
        let salvage = store.salvageUnfinalized()
        notice = Self.salvageNotice(recoveredSeconds: recoveredSeconds,
                                    recoveredFiles: salvage.recovered.count, dropped: salvage.dropped)

        refreshPending()
        // 启动时把还留着的重新入队。`enqueue` 内部查了 `outstandingFileTransfers`，所以
        // 正在传的不会被重复入队。
        //
        // 已经传完却还没收到回执的文件也会重新入队。激活后同时核对手机回执，确认已收到
        // 就取消多余传输；iPhone 侧还会用已有处理记录判重并补发回执。
        transfer.enqueueAll(pending)
        publishControlState()
    }

    // MARK: - 录音

    var isRecording: Bool { phase == .recording && recorder?.isRecording == true }

    func toggle() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startFromQuickEntry() {
        quickEntryGeneration += 1
        startRecording()
        publishControlState(forceReload: true)
    }

    /// A shortcut result confirms capture, not just a persisted request. Yield
    /// the main actor while watchOS finishes bringing the application forward.
    func startFromShortcut() async throws {
        NSLog("[WatchRecorder] shortcut start received active=%d capturing=%d", appIsActive, isRecording)
        startFromQuickEntry()
        let sessionID = recordingSession?.id
        let deadline = ProcessInfo.processInfo.systemUptime + Self.shortcutActivationTimeout
        while true {
            try Task.checkCancellation()
            guard recordingRequested, recordingSession?.id == sessionID else {
                throw ShortcutRecordingError(message: WatchText.pick(
                    en: "Recording was stopped before it could start.", zh: "录音在开始前已被停止。"))
            }
            if isRecording {
                NSLog("[WatchRecorder] shortcut start confirmed")
                return
            }
            if case .failed(let message) = phase {
                throw ShortcutRecordingError(message: message)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                NSLog("[WatchRecorder] shortcut start awaiting foreground or permission")
                throw ShortcutRecordingError(message: WatchText.pick(
                    en: "Recording has not started yet. Open Memorion on your watch to continue and check microphone access.",
                    zh: "录音尚未开始。请打开手表上的 Memorion 继续，并确认麦克风权限。"))
            }
            // The system may mark the app active without a new SwiftUI scene
            // callback. This check also covers a delayed permission completion.
            resumeIfPossible()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    func showFromQuickEntry() {
        quickEntryGeneration += 1
        publishControlState(forceReload: true)
    }

    func handleQuickEntryURL(_ url: URL) {
        guard url.scheme == "memorion-watch" else { return }
        switch url.host {
        case "record": startFromQuickEntry()
        case "stop":
            let session = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "session" })?.value
            stopFromQuickEntry(sessionID: session)
        default: showFromQuickEntry()
        }
    }

    func stopFromQuickEntry(sessionID: String? = nil) {
        quickEntryGeneration += 1
        // A delayed tap on an old stop icon cannot stop a newer recording.
        if let sessionID, sessionID != recordingSession?.id {
            publishControlState(forceReload: true)
            return
        }
        stopRecording()
        publishControlState(forceReload: true)
    }

    func stopFromShortcut() {
        NSLog("[WatchRecorder] shortcut stop received active=%d capturing=%d", appIsActive, isRecording)
        stopFromQuickEntry()
        NSLog("[WatchRecorder] shortcut stop confirmed requested=%d capturing=%d", recordingRequested, isRecording)
    }

    /// Quick entries start, never toggle: tapping twice must not stop the microphone.
    func startRecording() {
        guard !isRecording, !requestingPermission else { return }
        if phase == .recording { stop(reason: .interrupted(.systemEnded)) }
        // A new explicit attempt must not report a previous activation failure
        // while its own foreground transition is still pending.
        if case .failed = phase {
            phase = .idle
            notice = nil
        }
        if !recordingRequested {
            recordingSession = WatchRecordingSession(accountId: momentStore.owner.isEmpty ? nil : momentStore.owner)
            markCount = 0
            elapsed = 0
        }
        recordingRequested = true
        persistRecordingSession()
        publishControlState()
        startAfterPermission()
    }

    func stopRecording() {
        cancelForegroundRetry()
        guard recordingRequested || isRecording || requestingPermission else {
            publishControlState()
            return
        }
        recordingRequested = false
        recordingSession?.requested = false
        persistRecordingSession()
        stop(reason: .user)
        interruptedReason = nil
        WKInterfaceDevice.current().play(.stop)
    }

    func markMoment() {
        guard isRecording, let url = currentURL, var session = recordingSession else { return }
        let position = session.completedDuration + (recorder?.currentTime ?? 0)
        guard session.mark(at: position) != nil else {
            notice = WatchText.pick(en: "This recording has reached its mark limit.", zh: "这次录音的标记已达上限。")
            return
        }
        do {
            try session.metadata(segmentOffset: session.completedDuration,
                                 duration: recorder?.currentTime ?? 0, segmentStartedAt: currentStartedAt).save(for: url)
            recordingSession = session
            elapsed = max(elapsed, position)
            markCount = session.marks.count
            momentStore.saveMarks(session.metadata(segmentOffset: session.completedDuration, duration: recorder?.currentTime ?? 0, segmentStartedAt: currentStartedAt), recordingKey: url.lastPathComponent)
            moments = momentStore.moments
            persistRecordingSession()
            notice = WatchText.pick(en: "Marked at \(Self.timestamp(position))", zh: "已标记 \(Self.timestamp(position))")
            WKInterfaceDevice.current().play(.click)
        } catch {
            notice = WatchText.pick(en: "Could not save this mark. Try again.", zh: "标记未能保存，请重试。")
        }
    }

    var recordingStatusText: String {
        if isRecording { return WatchText.pick(en: "Recording", zh: "录音中") }
        if requestingPermission { return WatchText.pick(en: "Waiting for microphone permission", zh: "等待麦克风权限") }
        if case .failed = phase { return WatchText.pick(en: "Not recording", zh: "当前未录音") }
        return WatchText.pick(en: "Recording interrupted", zh: "录音已中断")
    }

    func queueStatus(for audio: PendingRecording) -> String {
        let duration = WatchRecordingMetadata.load(for: audio.url).map { Self.timestamp($0.durationSeconds) + " · " } ?? ""
        if transferFailures[audio.id] != nil {
            return duration + WatchText.pick(en: "Saved · retry pending", zh: "已保存 · 等待重试")
        }
        return duration + WatchText.pick(en: "Saved · awaiting iPhone receipt", zh: "已保存 · 等待手机回执")
    }

    func openOnPhone(_ moment: WatchMoment) {
        guard let conversationID = moment.conversationId, moment.isReady else { return }
        transfer.openOnPhone(conversationID: conversationID, offset: moment.offsetSeconds, owner: momentStore.owner)
        notice = WatchText.pick(en: "Open Memorion on your iPhone to view this moment.", zh: "请打开 iPhone 上的 Memorion 查看此刻。")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func persistRecordingSession() {
        guard var session = recordingSession else { return }
        session.requested = recordingRequested
        recordingSession = session
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.sessionDefaultsKey)
        }
    }

    /// 上个进程被系统回收时正在写的那段：截掉半截尾帧，按 `finalize` 的方式记账，返回救回的秒数。
    ///
    /// 只在 `init` 里调 —— 那时本进程还没开始写任何文件。
    private func recoverInterruptedCapture() -> TimeInterval {
        guard var session = recordingSession, let name = session.openCaptureName else { return 0 }
        session.openCaptureName = nil
        defer {
            recordingSession = session
            elapsed = session.completedDuration
            persistRecordingSession()
        }
        let url = store.url(named: name)
        guard FileManager.default.fileExists(atPath: url.path),
              let startedAt = PendingRecordingStore.startedAt(from: url) else { return 0 }
        if url.pathExtension == PendingRecordingStore.fileExtension,
           PendingRecordingStore.trimToCompleteADTSFrames(at: url) == .empty {
            return 0 // 留给 `salvageUnfinalized()` 删。
        }
        // 量不出来就不记账：文件照样同步，只是标记偏移没法对齐。宁可这样，也不拿计数器
        // 去编一个时长（进程挂起期间计数器是停的，见 `stop` 里那段）。
        guard let duration = Self.audioDurationSeconds(of: url), duration > 0 else {
            NSLog("[WatchRecorder] recovered \(name) but could not measure it")
            return 0
        }
        let metadata = session.metadata(segmentOffset: session.completedDuration, duration: duration,
                                        segmentStartedAt: startedAt)
        if (try? metadata.save(for: url)) != nil {
            momentStore.saveMarks(metadata, recordingKey: name)
        }
        session.completedDuration += duration
        NSLog("[WatchRecorder] recovered interrupted capture \(name) (\(Int(duration))s)")
        return duration
    }

    private static func salvageNotice(recoveredSeconds: TimeInterval, recoveredFiles: Int, dropped: Int) -> String? {
        var parts: [String] = []
        if recoveredSeconds > 0 || recoveredFiles > 0 {
            let amount = recoveredSeconds < 60
                ? (en: "\(Int(recoveredSeconds)) s", zh: "\(Int(recoveredSeconds)) 秒")
                : (en: "\(Int((recoveredSeconds / 60).rounded())) min", zh: "\(Int((recoveredSeconds / 60).rounded())) 分钟")
            parts.append(recoveredSeconds > 0
                ? WatchText.pick(
                    en: "Recording was stopped by the system. About \(amount.en) before that was saved and will sync.",
                    zh: "录音被系统中断。中断前约 \(amount.zh) 已保存，会自动同步。")
                : WatchText.pick(
                    en: "Recording was stopped by the system. What was captured before that was saved and will sync.",
                    zh: "录音被系统中断。中断前录到的部分已保存，会自动同步。"))
        }
        if dropped > 0 {
            parts.append(WatchText.pick(
                en: "\(dropped) recording(s) were cut off before they could be saved and had to be removed.",
                zh: "有 \(dropped) 段录音在保存完成前被中断、无法使用，已清理。"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func resumeIfPossible() {
        guard recordingRequested, !isRecording, !requestingPermission,
              appIsActive else { return }
        startAfterPermission()
    }

    private var appIsActive: Bool {
#if targetEnvironment(simulator)
        if let override = simulatorAppActiveOverride { return override }
#endif
        return WKApplication.shared().applicationState == .active
    }

    /// Shortcut execution can arrive while the foreground scene is transitioning.
    /// Keep the persisted request. A short retry window also recovers activation
    /// when SwiftUI doesn't deliver another scene callback to the existing view.
    private func waitForForegroundIfNeeded() -> Bool {
        guard !appIsActive else { return false }
        interruptedReason = WatchText.pick(en: "Waiting to start", zh: "等待开始录音")
        NSLog("[WatchRecorder] deferring microphone activation until foreground")
        scheduleForegroundRetry()
        return true
    }

    private func scheduleForegroundRetry() {
        guard foregroundRetryTimer == nil else { return }
        foregroundRetryDeadline = Date().addingTimeInterval(Self.shortcutActivationTimeout)
        foregroundRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.foregroundRetryTimer === timer else { return }
                guard self.recordingRequested, !self.isRecording else {
                    self.cancelForegroundRetry()
                    return
                }
                if self.appIsActive {
                    self.cancelForegroundRetry()
                    NSLog("[WatchRecorder] retry recovered foreground activation")
                    self.resumeIfPossible()
                } else if let deadline = self.foregroundRetryDeadline, Date() >= deadline {
                    self.cancelForegroundRetry()
                    // Preserve user intent for the next actual activation. Do
                    // not keep a background polling loop or start a microphone
                    // while the app is inactive.
                    NSLog("[WatchRecorder] foreground retry expired; request preserved")
                }
            }
        }
    }

    private func cancelForegroundRetry() {
        foregroundRetryTimer?.invalidate()
        foregroundRetryTimer = nil
        foregroundRetryDeadline = nil
    }

    /// 🚨 **麦克风权限必须显式要一次，不能指望 `record()` 去要。**
    ///
    /// 权限处于 undetermined 时 `AVAudioRecorder.record()` **仍然返回 true**，录出来的是一个
    /// 结构完整、却一帧音频都没有的 m4a（moov atom 有，mdat 是空的）—— 它能过
    /// `isFinalized` 的结构判据，也能过计数器的时长门槛，一路传到 iPhone、上传，
    /// 几十分钟后才由后端 ffmpeg 判成 400。用户看到的是一句「无法转录」，而根因在四十分钟前
    /// 的一个从没弹出来的权限框（2026-08-15 生产上那条 557 字节 / 0.0 秒的录音）。
    ///
    /// ⚠️ **拒绝时不能只说「麦克风不可用」。** 手表上没有 App 级的权限设置界面，只能去
    /// iPhone 的「Watch → Memorion」里改 —— 文案必须把这条路指出来，否则用户无从下手。
    private func startAfterPermission() {
        guard recordingRequested, !requestingPermission else { return }
        guard !waitForForegroundIfNeeded() else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            start()
        case .denied:
            phase = .failed(WatchText.pick(en: "Microphone access denied", zh: "麦克风权限被拒绝"))
            notice = WatchText.pick(
                en: "Allow Memorion to use the microphone in system Settings, then return and retry.",
                zh: "请在系统设置中允许 Memorion 使用麦克风，然后回来重试。"
            )
            publishControlState()
        case .undetermined:
            requestingPermission = true
            notice = WatchText.pick(en: "Asking for microphone access…", zh: "正在请求麦克风权限…")
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.requestingPermission = false
                    guard self.recordingRequested else { return }
                    guard granted else {
                        self.phase = .failed(WatchText.pick(
                            en: "Microphone access denied", zh: "麦克风权限被拒绝"
                        ))
                        self.notice = WatchText.pick(
                            en: "Without microphone access nothing can be recorded.",
                            zh: "没有麦克风权限就录不到任何声音。"
                        )
                        self.publishControlState()
                        return
                    }
                    self.start()
                }
            }
        @unknown default:
            // 新枚举值：宁可试着录（失败会走 `start()` 的 catch 并明确报错），
            // 也不要在这里挡下一个其实可用的麦克风。
            start()
        }
    }

    private func start(playHaptic: Bool = true) {
        guard recordingRequested, !isRecording else { return }
        // Permission completion may arrive after the scene has left the foreground.
        guard !waitForForegroundIfNeeded() else { return }
        cancelForegroundRetry()
        notice = nil

        let startedAt = Date()
        let url = store.newRecordingURL(startedAt: startedAt)

        do {
            try activateAudioSession()

            // 对齐 `WKAudioRecorderPreset.wideBandSpeech`：16kHz / AAC 32kbps / 单声道。
            // 约 14.4 MB/小时 —— 手机端实时链路用的 PCM16 是 115 MB/小时，差 8 倍。
            // 瓶颈从来是电量，不是存储（Watch 有 64GB）。
            //
            // 后端不需要客户端转格式：非 `.opus` 的上传都走 `convert_to_wav_16k`
            // （ffmpeg）。容器由扩展名决定（`.aac` ⇒ ADTS），见 `PendingRecordingStore.fileExtension`。
            //
            // ⚠️ **登记必须在 `record()` 之前**：文件在 `record()` 那一刻出现在目录里，而对账
            // 计时器随时可能列举到它。
            PendingRecordingStore.beginCapture(url)
            recordingSession?.openCaptureName = url.lastPathComponent
            persistRecordingSession()
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,
            ])
            recorder.delegate = self
            guard recorder.record() else {
                throw NSError(domain: "MemorionWatch", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: WatchText.pick(
                        en: "The microphone is unavailable.", zh: "麦克风不可用。"
                    ),
                ])
            }

            self.recorder = recorder
            currentURL = url
            currentStartedAt = startedAt
            elapsed = recordingSession?.completedDuration ?? 0
            interruptedReason = nil
            phase = .recording
            publishControlState()
            if playHaptic { WKInterfaceDevice.current().play(.start) }
            startTicking()

            // Recording is kept alive by the active microphone. Extended runtime
            // categories describe other product types and must not govern this recorder.
        } catch {
            PendingRecordingStore.endCapture(url)
            recordingSession?.openCaptureName = nil
            persistRecordingSession()
            phase = .failed(error.localizedDescription)
            notice = WatchText.pick(
                en: "Could not start recording. \(error.localizedDescription)",
                zh: "无法开始录音。\(error.localizedDescription)"
            )
            publishControlState()
        }
    }

    /// 配好并激活录音用的 audio session。
    ///
    /// ⚠️ **优先 `.playAndRecord` + `.overrideMutedMicrophoneInterruption`，不是 `.record`。**
    /// 这是社区里唯一被实测证明「watchOS 息屏后仍在录」的组合（见类注释：保活靠的是活跃的
    /// 麦克风，不是后台运行会话）。`.record` 在同样条件下没有这个报告。option 需要
    /// watchOS 9+，本 target 是 10.0。哪个机型上这个组合起不来就退回 `.record` —— 那时至少
    /// 前台录音是好的，而且日志里能看见是哪一支。
    ///
    /// ⚠️ **会话已经是录音类别时只 `setActive(true)`，不再 `setCategory`。** 切段
    /// （`.rotate`）可能发生在后台，而在后台改 category 有失败的风险 —— 一失败就把一段
    /// 本来可以继续的录音终结在这里。
    private func activateAudioSession() throws {
#if targetEnvironment(simulator)
        if simulatorFailNextAudioActivation {
            simulatorFailNextAudioActivation = false
            throw NSError(domain: "MemorionSimulator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Injected audio activation failure"])
        }
#endif
        let session = AVAudioSession.sharedInstance()
        if session.category == .playAndRecord || session.category == .record {
            try session.setActive(true)
            return
        }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.overrideMutedMicrophoneInterruption])
        } catch {
            NSLog("[WatchRecorder] .playAndRecord unavailable (\(error.localizedDescription)) — falling back to .record")
            try session.setCategory(.record, mode: .default)
        }
        try session.setActive(true)
    }

    private enum StopReason {
        case user
        /// 收尾当前文件并立刻接着录下一个。用户视角上仍然是「一直在录」。
        case rotate(RotateCause)
        /// 平台把我们打断了。**这些都不是 bug**，是 watchOS 的既有行为 —— 每一种都必须
        /// 在 UI 上说清楚，否则用户会以为录音还在继续（那是最坏的失败形态：以为录了，
        /// 其实没录）。
        case interrupted(Interruption)
    }

    enum RotateCause {
        /// 单个文件的时长上限到了（55 分钟）。
        case durationLimit
    }

    enum Interruption {
        /// Keep user intent; reactivate when watchOS permits foreground capture.
        case audioSession
        case encodingError
        case systemEnded

        var text: String {
            switch self {
            case .audioSession:
                return WatchText.pick(en: "interrupted by a call or Siri", zh: "被来电或 Siri 打断")
            case .encodingError:
                return WatchText.pick(en: "an audio encoding error", zh: "音频编码出错")
            case .systemEnded:
                return WatchText.pick(en: "the system stopped recording", zh: "系统停止了录音")
            }
        }
    }

    private func stop(reason: StopReason) {
        stopTicking()

        let url = currentURL
        let startedAt = currentStartedAt

        // 两个计数器取较大值，作为**读不出文件真实长度时**的兜底（见 `finalize`）。
        //
        // ⚠️ 必须在 `stop()` 之前读 `currentTime`（停掉之后它是 0）。计时器跑在主 run loop
        // 上，进程一被挂起就停摆 —— 恢复后 `elapsed` 会**少算整段后台时长**，一段真录了
        // 10 分钟的录音可能只报 30 秒。而 30 秒还看不出问题，**少算到 5 秒以下时会被当成
        // 「太短」直接删掉**：一段好录音因为一个计数器不准而消失。所以取两者较大值。
        //
        // 🚨 **但 `max()` 反过来会替空文件背书，所以它不能是最终判据。**
        // 录音器一帧都没录到时 `currentTime == 0`，而 `elapsed` 照样数到 10 ——
        // 于是一个 557 字节、0.0 秒的 m4a 拿着「10 秒」的证明过了下面的 5 秒门槛，传到
        // iPhone、上传、42 分钟后被后端 ffmpeg 判 400，用户看到一句无从下手的
        // 「无法转录」（2026-08-15 生产实测就是这一条）。真正的判据是文件里的音频长度，
        // 在 `finalize` 里量。
        let counterDuration = recordingSession?.capturedSegmentDuration(
            liveCounter: recorder?.currentTime ?? 0, lastKnownTotal: elapsed
        ) ?? max(0, recorder?.currentTime ?? 0)

        recorder?.stop()
        recorder = nil
        currentURL = nil
        currentStartedAt = nil
        if let url { PendingRecordingStore.endCapture(url) }
        // 正常收尾了，下次启动不必再当成被系统回收的那段去救。由下面的 `finalize` /
        // `persistRecordingSession` 落盘。
        recordingSession?.openCaptureName = nil

        if case .rotate = reason {
            // ⚠️ **切段绝不许动 audio session。** 息屏切段发生在后台，而在后台
            // `setActive(false)` 之后再 `setActive(true)` 大概率失败（watchOS 不允许从后台
            // 激活音频会话）—— 那就把一段本可以继续的录音终结在这里了。前台切段时它也是
            // 纯多余的。会话也刻意不 invalidate，为的就是让录音无缝接上。
        } else {
            try? AVAudioSession.sharedInstance().setActive(false)
        }

        phase = .idle
        elapsed = recordingSession?.completedDuration ?? 0

        if let url, let startedAt {
            finalize(url: url, startedAt: startedAt, counterDuration: counterDuration)
            elapsed = recordingSession?.completedDuration ?? 0
            lastSavedDuration = elapsed
        }

        switch reason {
        case .user:
            elapsed = 0
        case .rotate:
            start(playHaptic: false)
        case .interrupted(let reason):
            interruptedReason = reason.text
            notice = WatchText.pick(
                en: "Recording interrupted — \(reason.text). Saved audio is kept; recording will resume when allowed.",
                zh: "录音已中断（\(reason.text)）。已录部分保留，系统允许后会继续。"
            )
            WKInterfaceDevice.current().play(.notification)
            persistRecordingSession()

        }
        publishControlState()
    }

    /// 文件里**真实的音频长度**（秒）。`nil` 表示打不开，**不等于 0 秒** —— 这两者在
    /// `finalize` 里走完全不同的分支，绝不能合并。
    ///
    /// 这是和后端同一把尺子：后端 `validate_audio_file` 也是解码音频量长度（ffmpeg），
    /// 所以这里量出 0.0 秒的文件，传上去必然换回一个 400。
    ///
    /// ⚠️ 用 `AVAudioFile` 而不是 `AVURLAsset.duration`：后者 iOS 16 起废弃、要改成 async 的
    /// `load(.duration)`，而这里在 `stop()` 的同步路径上。
    private static func audioDurationSeconds(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    /// 决定这段文件是入队还是丢掉。
    ///
    /// `counterDuration` 是两个计数器的较大值，**只在文件长度读不出来时才用**（见 `stop`）。
    private func finalize(url: URL, startedAt: Date, counterDuration: TimeInterval) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // 🚨 **判据是文件里的音频长度，不是计数器。** 计数器只证明「按下开始之后过了多久」，
        // 不证明「录到了东西」—— 一个 0 帧的 m4a 也能拿到 10 秒的背书（见 `stop` 里那段）。
        //
        // ⚠️ **读不出来时退回计数器，绝不当成 0。** `AVAudioFile` 打不开的原因不止一种
        // （编解码限制、临时资源不足），而这里**会真的删掉用户的录音** —— 一次误判就是永久
        // 丢一段。同样的取向见 `PendingRecordingStore.salvageUnfinalized()` 的注释。
        let measured = Self.audioDurationSeconds(of: url)
        let duration = measured ?? counterDuration
        if measured == nil {
            NSLog("[WatchRecorder] could not measure \(url.lastPathComponent), falling back to counters (\(Int(counterDuration))s)")
        }

        // 一帧都没录到。**必须在手表上当场说清楚**：这种文件传上去只会在几十分钟后换回一个
        // 「无法转录」，那时用户既想不起是哪一段，也没有任何可执行的下一步。
        // 最常见的原因是麦克风权限从没被授予（`start()` 里 `record()` 在权限未定时也会
        // 返回 true），所以文案直接指向它。
        if measured == 0 {
            store.discard(at: url)
            notice = WatchText.pick(
                en: "No audio was captured — nothing was recorded. Check that Memorion is allowed to use the microphone.",
                zh: "这段没有录到任何声音。请检查 Memorion 的麦克风权限是否已开启。"
            )
            refreshPending()
            return
        }

        // Preserve every nonempty recording, including short voice notes.
        // Processing eligibility must never be used to delete captured audio.
        if var session = recordingSession {
            do {
                let metadata = session.metadata(segmentOffset: session.completedDuration, duration: duration, segmentStartedAt: startedAt)
                try metadata.save(for: url)
                momentStore.saveMarks(metadata, recordingKey: url.lastPathComponent)
                moments = momentStore.moments
            } catch {
                notice = WatchText.pick(en: "Audio saved, but mark metadata could not be saved.",
                                        zh: "录音已保存，但标记信息未能保存。")
            }
            session.completedDuration += max(0, duration)
            recordingSession = session
            persistRecordingSession()
        }


        refreshPending()

        // ⚠️ **入队结果必须照实说，不能一律「正在自动同步」。** 自动入队从第一版就有，但它
        // 曾经**完全没有痕迹**：送达前不显示任何东西，而那条录音还留在「待同步」列表里
        // （删除只认 iPhone 的 App 级回执）。用户看到的就是「停止录音后好像没有自动同步，
        // 还得手动点一下立刻同步」—— 而他点的那一下其实只是重复入队，`enqueue` 判重后
        // 什么都没做，于是更没有痕迹。
        //
        // 时机上刻意放在 `stop(reason:)` 调 `finalize` 的位置之后、那个 switch 之前：
        // 息屏切段和被打断的文案要能盖掉这一句（它们说的事更重要，且都已经包含
        // 「已录部分已保留」）。
        guard let rec = pending.first(where: { $0.url == url }) else {
            // 文件在磁盘上、`pending()` 却列不到它 —— 只可能是文件名里的锚点不可解析
            // （`pending()` 会跳过这种）。以前这里是**静默 return**：既没入队、也没有一个字，
            // 而列表里连这条都看不见。
            NSLog("[WatchRecorder] \(url.lastPathComponent) not in pending after save — not enqueued")
            notice = WatchText.pick(
                en: "Saved, but this clip could not be queued for sync. Tap Sync now.",
                zh: "已保存，但这段没能加入同步队列。请点一下「立即同步」。"
            )
            return
        }

        switch transfer.enqueue(rec) {
        case .queued:
            // 已交给系统；入队不代表已经开始传输。
            showSyncNotice(WatchText.pick(
                en: "Saved. Queued for your iPhone.",
                zh: "已保存，已排队等待 iPhone 接收。"
            ))
            // 顺手叫一声 iPhone。不可达时它什么都不做，文件仍在系统队列里。
            transfer.nudgeCompanion()
        case .alreadyQueued:
            showSyncNotice(WatchText.pick(
                en: "Saved. Already in the send queue — waiting for your iPhone.",
                zh: "已保存，已在发送队列里，等 iPhone 收下。"
            ))
        case .deferredUntilActivated:
            showSyncNotice(WatchText.pick(
                en: "Saved. Will sync as soon as the connection is ready.",
                zh: "已保存，连接就绪后会自动同步。"
            ))
        case .notFinalized:
            // `stop()` 跑过了却还是没有 moov —— 写文件那一步真的失败了（磁盘满、
            // 会话在后台被强行收走）。**刻意不在这里删**：`measured` 上面已经量到了非零
            // 时长，说明 `AVAudioFile` 打得开，两个判据打架时宁可留着让启动清理去决定。
            // 但**绝不能传** —— 传出去只会在几十分钟后换回一句「无法转录」。
            NSLog("[WatchRecorder] \(url.lastPathComponent) has no moov after stop() — not enqueued")
            notice = WatchText.pick(
                en: "This clip could not be saved completely and cannot be synced.",
                zh: "这段录音没能完整保存，无法同步。"
            )
        case .unsupported:
            notice = WatchText.pick(
                en: "Saved, but this watch cannot sync to an iPhone.",
                zh: "已保存，但这只手表无法与 iPhone 同步。"
            )
        }
        refreshPending()
    }

    // MARK: - 模拟器注入

#if targetEnvironment(simulator)
    /// 模拟器上代替录音：造一条待同步录音并立刻入队。
    /// 见 `WatchSimulatorFixture` 的注释 —— 合成音得到后端 400 是**预期**结果。
    func injectFixture() {
        let startedAt = Date()
        guard let url = WatchSimulatorFixture.makeFile(at: store.newRecordingURL(startedAt: startedAt)) else {
            notice = "Could not create sample audio."
            return
        }
        refreshPending()
        if let rec = pending.first(where: { $0.url == url }) {
            transfer.enqueue(rec)
        }
        notice = "Injected \(WatchSimulatorFixture.kind) — syncing…"
    }
#endif

    // MARK: - 手动重发

    /// 用户点「立即同步」。把所有待同步的重新入队。
    ///
    /// 🚨 **文案必须由 `enqueueAll` 的结果决定，不能一律「正在同步 N 段」。**
    /// 绝大多数情况下这一下什么都没做：文件早就在系统队列里，`enqueue` 判重后直接返回
    /// （见 `WatchTransfer.EnqueueOutcome`）。而列表只在 iPhone 回执后才变短，于是
    /// 「点了 → 文案说正在同步 → 列表一动不动」，用户唯一能得出的结论就是「点了没反应」
    /// —— 2026-08-15 用户报的正是这句，而当时真实情况是「已入队、系统还没投递」。
    ///
    /// 这一下真正能做的事只有一件：`nudgeCompanion()` 把 iPhone 上的 App 叫起来，
    /// 让系统现在就把队列冲掉（实测投递时机就是 App 活过来的那一刻）。
    ///
    /// 🚨 **没在录的时候先收拾一遍没收尾的文件。** 这是 `salvageUnfinalized()` 第二个安全的
    /// 调用时机（第一个是 `init`）：此刻没有任何文件正在被写。不收拾的话，废文件会永久占着
    /// 「待同步」一格 —— `enqueue` 会拒绝它，于是它既传不走、又不会消失，用户点多少次都
    /// 一样，而这正是「点了没反应」的另一种真身。
    func retryPending() {
        transfer.resetAutomaticRetryBudget()
        if phase != .recording {
            let salvage = store.salvageUnfinalized()
            if let message = Self.salvageNotice(recoveredSeconds: 0, recoveredFiles: salvage.recovered.count,
                                                dropped: salvage.dropped) {
                notice = message
                refreshPending()
                // 清完就没别的了就停在这句上 —— 后面那些文案会盖掉它，而它更重要。
                if pending.isEmpty { return }
            }
        }

        refreshPending()
        guard !pending.isEmpty else {
            showSyncNotice(WatchText.pick(en: "Nothing waiting to sync.", zh: "没有待同步的录音。"))
            return
        }

        let summary = transfer.enqueueAll(pending)
        let nudged = transfer.nudgeCompanion()
        refreshPending()

        if summary.unsupported > 0 {
            notice = WatchText.pick(
                en: "This watch cannot sync to an iPhone.",
                zh: "这只手表无法与 iPhone 同步。"
            )
            return
        }

        // 录制中点的这一下：正在录的那个文件必然被拒（还没 moov），这不是故障。
        // 说「无法同步」会让用户以为录音坏了，所以单独说清楚。
        if summary.notFinalized > 0 && summary.notFinalized == summary.total {
            notice = phase == .recording
                ? WatchText.pick(
                    en: "Still recording — this part will sync once you stop.",
                    zh: "还在录音中，这一段停止后会自动同步。"
                )
                : WatchText.pick(
                    en: "\(summary.notFinalized) recording(s) were not saved completely and cannot be synced.",
                    zh: "有 \(summary.notFinalized) 段录音没能完整保存，无法同步。"
                )
            return
        }

        // ⚠️ 判据是「一条都没能入队、且有 deferred」，不是 `deferred == total`。
        // 混合结果（比如一条 deferred + 一条废文件）下后者为 false，会一路掉进下面
        // 那个用 `alreadyQueued` 计数说话的分支，说出「这 0 段已在队列里」。
        if summary.queued == 0 && summary.alreadyQueued == 0 && summary.deferred > 0 {
            showSyncNotice(WatchText.pick(
                en: "Connection not ready yet — will retry automatically.",
                zh: "连接还没就绪，稍后会自动重试。"
            ))
            return
        }

        // 一条都没有新入队 ⇒ 全都还在系统队列里等投递。**这是最常见的情况，也正是
        // 「点了没反应」的真身**，所以必须说清楚在等什么、以及用户能做什么。
        if summary.queued == 0 && summary.alreadyQueued > 0 {
            showSyncNotice(nudged
                ? WatchText.pick(
                    en: "\(summary.alreadyQueued) queued — checking iPhone receipts.",
                    zh: "\(summary.alreadyQueued) 段已排队，正在核对 iPhone 接收状态。"
                )
                : WatchText.pick(
                    en: "\(summary.alreadyQueued) queued. Open Memorion on your iPhone to continue syncing.",
                    zh: "\(summary.alreadyQueued) 段已排队，请打开 iPhone 上的 Memorion 继续同步。"
                )
            )
            return
        }

        // 到这里 `queued` 必然 > 0：上面的分支已经把 unsupported / 全废 / 全 deferred /
        // 「一条没新入队」都拦掉了。别把这句写成兜底 —— 它会说出「已排队 0 段」。
        guard summary.queued > 0 else {
            notice = WatchText.pick(
                en: "Nothing could be queued right now — will retry automatically.",
                zh: "这一下没有能入队的录音，稍后会自动重试。"
            )
            return
        }

        showSyncNotice(nudged
            ? WatchText.pick(
                en: "Queued \(summary.queued) recording(s) — waiting for iPhone confirmation.",
                zh: "已排队 \(summary.queued) 段录音，等待 iPhone 确认。"
            )
            : WatchText.pick(
                en: "Queued \(summary.queued) recording(s). Open Memorion on your iPhone to receive them.",
                zh: "已排队 \(summary.queued) 段。打开 iPhone 上的 Memorion 就会收下。"
            )
        )
    }

    private func showSyncNotice(_ message: String) {
        notice = message
        noticeIsSyncProgress = true
    }

    private func refreshSyncNotice() {
        // 回执只替换同步状态，保留录音失败、权限或文件丢失提示。
        guard notice == nil || noticeIsSyncProgress else { return }
        if let name = transferFailures.keys.sorted().first, let error = transferFailures[name] {
            showSyncNotice(WatchText.pick(
                en: "Sync failed — the recording is still on your watch. \(error)",
                zh: "同步失败，录音仍保留在手表上。\(error)"
            ))
        } else if !receiptCleanupFailures.isEmpty {
            showSyncNotice(WatchText.pick(
                en: "iPhone confirmed receipt, but some watch copies could not be removed. Will retry cleanup.",
                zh: "iPhone 已确认收到，但部分手表副本暂时无法清理，将重试清理。"
            ))
        } else if pending.isEmpty {
            showSyncNotice(WatchText.pick(
                en: "All recordings received by iPhone.",
                zh: "iPhone 已确认收到全部录音。"
            ))
        } else {
            showSyncNotice(WatchText.pick(
                en: "\(pending.count) recording(s) remain — waiting for iPhone confirmation.",
                zh: "还剩 \(pending.count) 段录音，等待 iPhone 确认。"
            ))
        }
    }

    func refreshPending() {
        // An open capture is not a saved recording, even if its file already exists.
        pending = store.pending().filter { $0.url != currentURL }
        let names = Set(pending.map { $0.url.lastPathComponent })
        receiptCleanupFailures.formIntersection(names)
        transferFailures = transferFailures.filter { names.contains($0.key) }
        inFlightCount = transfer.outstandingCount
        companionReachable = transfer.companionReachable
    }

    /// App 出现 / 回到前台。刷新队列，**并且队列非空时叫一声 iPhone**。
    ///
    /// 🚨 **抬腕打开手表 App 看一眼「怎么还没同步」，以前恰恰是唯一不推一把的动作。**
    /// `nudgeCompanion()` 之前只挂在两处：停止录音之后、点「立即同步」。而
    /// `transferFile` 的投递时机由系统定，实测就是「iPhone 上的 Memorion 活过来的那一刻」
    /// —— 于是「已交给系统但还没投递」的录音只能等用户自己去打开手机 App（实测等过 42
    /// 分钟）。用户看到的就是「经常没有自动同步」，而手表这边一切正常、也确实没有任何
    /// 一步可以指责。打开手表 App 和点「立即同步」应该做同一件事，区别只是不出文案。
    ///
    /// ⚠️ **刻意不写 `notice`。** 这条路径不是用户主动要求同步，弹一句「正在叫 iPhone」
    /// 会盖掉上一次真正重要的提示（比如「这段录音没能完整保存」）—— 那句话是用户唯一的
    /// 线索，而这句只是个后台动作。
    ///
    /// ⚠️ **不收拾没收尾的文件**（`salvageUnfinalized()`）：录音中正在写的那个文件同样没收尾，
    /// 而这个方法在录音中也会被调到（通知横幅下来再回去就是一次 `.active`）。清理只能待在
    /// `init` 和 `retryPending()` 那两个「此刻没有文件正在被写」的时机。正在录的那段由
    /// `enqueue` 自己挡下来（返回 `.notFinalized`），不会漏传。
    func handleBecameActive() {
        if phase == .recording && recorder?.isRecording != true {
            stop(reason: .interrupted(.systemEnded))
        }
        resumeIfPossible()
        publishControlState(forceReload: true)
        transfer.resetAutomaticRetryBudget()
        transfer.setForeground(true)
        refreshPending()
        guard !pending.isEmpty else { return }
        // 重新入队是幂等的（`enqueue` 查了 `outstandingFileTransfers`），这一下真正的作用
        // 是补齐上个进程漏下的，然后 nudge。
        transfer.enqueueAll(pending)
        let nudged = transfer.nudgeCompanion()
        NSLog("[WatchRecorder] became active with \(pending.count) pending, nudged=\(nudged)")
        refreshPending()
    }

    // MARK: - 计时与切片

    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.elapsed = (self.recordingSession?.completedDuration ?? 0) + (self.recorder?.currentTime ?? 0)
                if self.recorder?.isRecording != true {
                    self.stop(reason: .interrupted(.systemEnded))
                    return
                }
                if (self.recorder?.currentTime ?? 0) >= Self.rotateAfterSeconds,
                   WKApplication.shared().applicationState == .active {
                    // 切片：停掉当前文件，立刻开新的。用户视角上仍然是「一直在录」。
                    self.stop(reason: .rotate(.durationLimit))
                }
            }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - 离开前台

    /// Called by the app scene, independently of which page is visible.
    func handleWentBackground() {
        transfer.setForeground(false)
        // Keep an already-active microphone running. Stopping it on wrist-down
        // creates the very background restart that watchOS may refuse.
    }

    // MARK: - 打断

    @objc nonisolated private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            if type == .began, self.phase == .recording {
                self.stop(reason: .interrupted(.audioSession))
            } else if type == .ended {
                self.resumeIfPossible()
            }
        }
    }
}

// MARK: - AVAudioRecorderDelegate

// 三个 delegate 回调都是 `nonisolated` + 内部 hop 回 MainActor：系统可以在任意线程调它们，
// 而这个类是 `@MainActor`。不加 `nonisolated` 在 Swift 6 语言模式下是编译错误。
extension WatchRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.stop(reason: .interrupted(flag ? .systemEnded : .encodingError))
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.stop(reason: .interrupted(.encodingError))
        }
    }
}
