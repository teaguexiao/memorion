import Foundation
import WatchConnectivity

/// 把待同步录音交给 iPhone。
///
/// `transferFile` 是**排队式**的：不需要 iPhone 此刻可达，也不需要 Watch 端 App 保持
/// 前台，系统会在两端都就绪时投递，App 被杀掉也不影响。所以这里没有任何「等待连接」
/// 的逻辑 —— 需要的只是入队和确认送达。
///
/// ⚠️ **`transferFile` 在配对的模拟器之间根本不投递**（2026-08-13 实测）。手表侧
/// `wcd` 会一路打到 `found valid file transfer` / `handleFileResultWithPairingID … with
/// kNoErr` / `Updating progress to finished`，而 iPhone 那台模拟器的 `wcd` **从头到尾
/// 没有任何 incoming file 记录**，App 容器里的
/// `Library/Application Support/com.apple.watchconnectivity/<watch-udid>/WatchContent/`
/// 是个空目录。同一对模拟器上 `updateApplicationContext` 是能到的（手表侧
/// `ReceivedApplicationContext/context` 有内容），所以坏的只是文件传输这一条。
/// **别照着这个现象去改传输逻辑** —— 手表侧 kNoErr 是守护进程在本机自己签的收，
/// 端到端必须在真机上验（这也正是删除只认 App 级回执、不认 `didFinish` 的理由）。
final class WatchTransfer: NSObject {
    /// iPhone 侧凭这个 key 取录制时刻。值是 ISO-8601 UTC 字符串，与后端
    /// `started_at` query 参数要的格式完全一致，中间任何一跳都不需要再解释一次时区。
    static let startedAtKey = "startedAtIso8601"
    static let durationKey = "durationSeconds"
    /// 与 iPhone 侧 `WatchSessionService.ackKey` 必须一字不差。
    static let ackKey = WatchReceiptProtocol.ackKey
    /// 与 iPhone 侧 `WatchSessionService.nudgeKey` 必须一字不差。见 `nudgeCompanion()`。
    static let nudgeKey = "flushWatchTransfers"

    /// `enqueue` 的结果。
    ///
    /// 🚨 **必须回给调用方，这不是「更好的日志」。** 三种结果里有两种是「这一刻什么都没
    /// 发生」，而 UI 以前一律显示「已保存，正在自动同步到 iPhone…」/「正在同步 N 段录音…」
    /// —— 于是「自动同步没触发」和「手动点了没反应」两个真实故障，在表上长得跟成功
    /// 一模一样（2026-08-15 用户报的正是这两句）。把失败呈现成成功是本仓库最贵的那类缺陷。
    enum EnqueueOutcome: Equatable {
        /// 真的交给系统了。
        case queued
        /// 系统队列里已经有这个文件（上次入队还没送达）。**没有发生第二次传输。**
        case alreadyQueued
        /// session 还没激活完，攒进 `deferred`，激活回调里自动冲。
        case deferredUntilActivated
        /// 文件没收尾 —— 要么正在录（`PendingRecordingStore.beginCapture`），要么是缺 moov 的旧 m4a。
        /// 两种都不能传，见 `enqueue` 的注释。
        case notFinalized
        /// 这台设备不支持 WatchConnectivity（手表上不该出现）。
        case unsupported
    }

    /// `enqueueAll` 的分类计数。UI 要按这个说话，不能只报总数。
    struct EnqueueSummary {
        var queued = 0
        var alreadyQueued = 0
        var deferred = 0
        var notFinalized = 0
        var unsupported = 0

        var total: Int { queued + alreadyQueued + deferred + notFinalized + unsupported }
    }

    /// 传输离开手表后回调（主线程）。
    ///
    /// ⚠️ **这不等于「iPhone 的 App 收到了」，所以绝不能在这里删录音。**
    /// `didFinish(error: nil)` 只说明文件交到系统那边并送到了对端**设备**；对端 App 的
    /// `session(_:didReceive:)` 是否真的跑过、落盘是否成功，这里一无所知。
    /// 2026-08-13 在模拟器上实测到：手表这边 kNoErr、progress finished，而手机侧
    /// `didReceive` 从未触发、收件箱是空的 —— 按 didFinish 删就是**永久丢录音**。
    /// 删除只认 `onAcknowledged`。
    var onDelivered: ((URL) -> Void)?
    /// iPhone 的 App 确认已落盘（收到 `ackKey` 回执）。**唯一可以删录音的信号。**
    var onAcknowledged: ((String) -> Void)?
    /// Always read disk on reconciliation; UI snapshots can lag incoming receipts.
    var pendingRecordings: (() -> [PendingRecording])?
    var onStateChanged: (() -> Void)?
    private var reconciliationTimer: Timer?
    private var lastReconciliation: Date?
    private var lastRequestedNames: [String] = []
    private var acknowledgedNames = Set<String>()
    private var audioRetryBudget = WatchAudioRetryBudget()
    /// 送达失败后回调（主线程）。文件**不会**被删除。
    var onFailed: ((URL, Error) -> Void)?

    /// ⚠️ **必须带 `.withFractionalSeconds`。** 文件名里的锚点是**毫秒**，只到秒的 ISO 串
    /// 会让 iPhone 侧从 metadata 还原出一个差最多 999ms 的时刻。iPhone 那边现在按收到的
    /// 文件名原样落盘（不再按时刻重算名字），所以这已经不影响回执匹配了，但两边的锚点
    /// 还是该一致 —— 否则日志里两个数对不上，查问题时会先怀疑错的地方。
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    var onApplicationContext: (([String: Any]) -> Void)?

    func openOnPhone(conversationID: String, offset: Double, owner: String) {
        guard let session, session.activationState == .activated else { return }
        let request: [String: Any] = ["openWatchMoment": UUID().uuidString, "conversationId": conversationID,
                                      "offsetSeconds": offset, "accountId": owner]
        session.transferUserInfo(request)
        if session.isReachable { session.sendMessage(request, replyHandler: nil, errorHandler: nil) }
    }

    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    /// 激活完成前入队的录音。见 `enqueue` 的注释。
    private var deferred: [PendingRecording] = []

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// 入队一条录音。
    ///
    /// ⚠️ **必须等激活完成才能调 `transferFile`。** 激活是异步的，而
    /// `WatchRecorder.init()` 里 `activate()` 的下一行就是 `enqueueAll(pending)` ——
    /// 那时 `activationState` 还是 `.notActivated`，`transferFile` 会立刻以
    /// 「WatchConnectivity session has not been activated」失败（2026-08-13 在模拟器上
    /// 实测到）。失败走的是 `onFailed` → UI 弹「同步失败」，于是**每次冷启动的重传都
    /// 必然失败一次**，而上次没送达的文件永远送不出去。所以这里把还没激活时的入队
    /// 攒起来，等 `activationDidCompleteWith` 再冲。
    ///
    /// ⚠️ **重复入队检查是必需的，不是优化。** `transferFile` 的队列由系统持有并跨启动
    /// 存活，所以 App 重启后 `pending()` 里那些「还没送达」的文件很可能正在传输中。不查
    /// `outstandingFileTransfers` 就会把同一段录音传两次，而 iPhone 侧每次收到都会上传，
    /// 结果是用户看到两条一模一样的对话。
    ///
    /// 🚨 **没收尾的文件在这里被挡住，而这个检查必须在这一层。** 判据
    /// （`PendingRecordingStore.isFinalized`）本来只在 `WatchRecorder.init()` 里以
    /// 「启动扫一遍并删掉」的形式存在，但从 `pending()` 取文件入队的地方有**三个**：冷启动
    /// 重新入队、用户点「立即同步」（`retryPending`）、激活后冲 `deferred`。后两个都不经过
    /// 那次清理，于是 2026-08-15 的 `rec_1786778452129.m4a`（息屏切段后在后台录了 24 秒、
    /// 进程被挂起、`stop()` 没跑）被用户手动那一下直接传了出去，42 分钟后换回一个 400。
    /// 放在 `enqueue` 里是因为**这是三条路唯一的汇聚点**——判据放在调用方，就一定会漏掉
    /// 将来新增的第四条路。
    ///
    /// 这一条同时挡住**正在录的那个文件**：`pending()` 是裸列目录，录制中它就在里面。
    /// ADTS 正在写的文件看着也是完整的，所以靠的是显式登记（`isCapturing`），不是格式。
    /// 以前在录音过程中点一下「立即同步」，传出去的就是一个半截文件。
    @discardableResult
    func enqueue(_ recording: PendingRecording) -> EnqueueOutcome {
        guard let session else { return .unsupported }

        let name = recording.url.lastPathComponent

        guard PendingRecordingStore.isFinalized(at: recording.url) else {
            NSLog("[WatchTransfer] refusing \(name): not finalized (capturing or no moov, \(recording.byteCount) bytes)")
            return .notFinalized
        }

        guard session.activationState == .activated else {
            if !deferred.contains(where: { $0.url == recording.url }) {
                deferred.append(recording)
            }
            NSLog("[WatchTransfer] deferred \(name): session not activated (state=\(session.activationState.rawValue))")
            return .deferredUntilActivated
        }

        if session.outstandingFileTransfers.contains(where: { $0.file.fileURL.lastPathComponent == name }) {
            NSLog("[WatchTransfer] \(name) already in system queue, not re-sending")
            return .alreadyQueued
        }

        var metadata: [String: Any] = [
            Self.startedAtKey: isoFormatter.string(from: recording.startedAt),
            Self.durationKey: 0,  // iPhone 侧不依赖它；真时长由后端解码音频得出
        ]
        if let details = WatchRecordingMetadata.load(for: recording.url), let json = details.jsonString {
            metadata[WatchRecordingMetadata.transferKey] = json
            metadata[Self.durationKey] = details.durationSeconds
        }
        session.transferFile(recording.url, metadata: metadata)
        NSLog("[WatchTransfer] queued \(name) (\(recording.byteCount) bytes), reachable=\(session.isReachable)")
        return .queued
    }

    /// 把当前所有待同步录音入队（启动时、以及用户手动重发时调用）。
    @discardableResult
    func enqueueAll(_ recordings: [PendingRecording]) -> EnqueueSummary {
        var summary = EnqueueSummary()
        for recording in recordings {
            switch enqueue(recording) {
            case .queued: summary.queued += 1
            case .alreadyQueued: summary.alreadyQueued += 1
            case .deferredUntilActivated: summary.deferred += 1
            case .notFinalized: summary.notFinalized += 1
            case .unsupported: summary.unsupported += 1
            }
        }
        return summary
    }

    var outstandingCount: Int {
        session?.outstandingFileTransfers.count ?? 0
    }

    /// Poll only while the Watch UI is active. Background recovery uses WC's
    /// durable user-info queue; no background keep-alive or repeated audio upload.
    func setForeground(_ foreground: Bool) {
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
        if foreground {
            reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.reconcilePending()
                self?.onStateChanged?()
            }
        }
    }

    func resetAutomaticRetryBudget() { audioRetryBudget.reset() }

    private func finalizedRecordings() -> [PendingRecording] {
        (pendingRecordings?() ?? []).filter { PendingRecordingStore.isFinalized(at: $0.url) }
    }

    private func queueReceiptRequest(_ names: [String], session: WCSession) {
        guard session.activationState == .activated else { return }
        let alreadyQueued = session.outstandingUserInfoTransfers.contains {
            ($0.userInfo[WatchReceiptProtocol.requestKey] as? [String]) == names
        }
        if !alreadyQueued {
            session.transferUserInfo([WatchReceiptProtocol.requestKey: names])
        }
    }

    private func reconcilePending() {
        // A prior app receipt remains valid if local deletion failed. Retry that
        // cleanup on the foreground timer/nudge, even while the phone is offline.
        if !acknowledgedNames.isEmpty { acknowledge(Array(acknowledgedNames)) }
        guard let session, session.activationState == .activated else { return }
        let pendingNames = finalizedRecordings().map { $0.url.lastPathComponent }.sorted()
        acknowledgedNames.formIntersection(Set(pendingNames))
        audioRetryBudget.retain(Set(pendingNames))
        let names = pendingNames.filter { !acknowledgedNames.contains($0) }
        guard !names.isEmpty else { return }
        // onAppear/scenePhase/activation can fire together. Changed queues don't wait.
        if names == lastRequestedNames, let lastReconciliation,
           Date().timeIntervalSince(lastReconciliation) < 15 { return }
        lastRequestedNames = names
        lastReconciliation = Date()
        for batch in WatchReceiptProtocol.batches(names) {
            guard session.isReachable else {
                queueReceiptRequest(batch, session: session)
                continue
            }
            session.sendMessage([WatchReceiptProtocol.requestKey: batch], replyHandler: { [weak self] reply in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // An old companion, malformed reply, or error is not confirmation.
                    guard let received = reply[WatchReceiptProtocol.responseKey] as? [String] else { return }
                    let requested = Set(batch)
                    self.acknowledge(received.filter { requested.contains($0) })
                    // A new companion explicitly answered. Files it does not have
                    // can resume after a failed transfer; queued files stay queued.
                    for recording in self.finalizedRecordings()
                        where requested.contains(recording.url.lastPathComponent)
                            && !received.contains(recording.url.lastPathComponent) {
                        let name = recording.url.lastPathComponent
                        guard !session.outstandingFileTransfers.contains(where: { $0.file.fileURL.lastPathComponent == name }),
                              self.audioRetryBudget.reserve(name, now: Date()) else { continue }
                        self.enqueue(recording)
                    }
                    self.onStateChanged?()
                }
            }, errorHandler: { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.queueReceiptRequest(batch, session: session)
                    NSLog("[WatchTransfer] receipt query deferred to background delivery")
                }
            })
        }
    }

    private func acknowledge(_ names: [String]) {
        let local = Set(finalizedRecordings().map { $0.url.lastPathComponent })
        for name in WatchReceiptProtocol.names(names) where local.contains(name) {
            acknowledgedNames.insert(name)
            deferred.removeAll { $0.url.lastPathComponent == name }
            // The phone has a durable copy. Cancel redundant queued retransfers
            // before removing the Watch copy; cancellation callbacks aren't failures.
            for transfer in session?.outstandingFileTransfers ?? []
                where transfer.file.fileURL.lastPathComponent == name {
                transfer.cancel()
            }
            NSLog("[WatchTransfer] iPhone confirmed \(name)")
            onAcknowledged?(name)
        }
        // Only failed local deletions still need suppression. Finished files
        // aren't retained in memory for the lifetime of the Watch process.
        acknowledgedNames.formIntersection(Set(finalizedRecordings().map { $0.url.lastPathComponent }))
        onStateChanged?()
    }

    /// iPhone 此刻能不能被叫醒。见 `nudgeCompanion()`。
    var companionReachable: Bool {
        guard let session, session.activationState == .activated else { return false }
        return session.isReachable
    }

    /// 叫醒 iPhone 上的 App，让系统把排队中的文件传输**现在**投出去。返回「叫了没有」。
    ///
    /// ## 为什么需要这一下（2026-08-15 实测出来的）
    ///
    /// `transferFile` 的投递时机**完全由系统决定**，而实测到的时机是「iPhone 上的 Memorion
    /// 回到前台的那一刻」：一段 13:24 录完、入队后立刻 `didFinish(kNoErr)` 的录音，
    /// 直到 14:06 用户打开手机 App 才真正到达 —— 中间 42 分钟里手表侧一切正常，
    /// 「待同步」不动，用户看到的就是「没有自动同步」。
    ///
    /// `sendMessage` 是唯一能反过来推一把的通道：**从 watchOS 发消息时，系统会为了送达
    /// 而把 iOS 上的 App 拉起到后台**（这也是 `isReachable` 在两侧语义不对称的原因 ——
    /// iOS 侧的 `isReachable` 要求手表 App 在前台，手表侧只要求 iPhone 在范围内）。
    /// App 一被拉起就会 `activate()`（`AppDelegate:103`），排队的文件随之投出。
    ///
    /// ⚠️ **这是 best-effort，不是保证，所以调用方不能把它当成「同步成功」。**
    /// 不可达时它返回 false 而不做任何事；文件仍然在系统队列里，该来的还是会来。
    /// UI 上必须照实说「已交给系统，等 iPhone 收下」，别因为叫了一声就改口说已同步。
    ///
    /// ⚠️ 刻意不带 `replyHandler`：要回复就得等 iPhone 那边真的响应，而这里的目的只是
    /// 「把它叫起来」，等回复只会多一条会超时的路径。iPhone 侧必须实现
    /// `session(_:didReceiveMessage:)`，否则收到无回复消息时那侧会抛异常。
    @discardableResult
    func nudgeCompanion() -> Bool {
        reconcilePending()
        guard let session, session.activationState == .activated, session.isReachable else {
            return false
        }
        session.sendMessage([Self.nudgeKey: true], replyHandler: nil) { error in
            NSLog("[WatchTransfer] nudge failed: \(error.localizedDescription)")
        }
        NSLog("[WatchTransfer] nudged companion to flush \(session.outstandingFileTransfers.count) transfer(s)")
        return true
    }
}

extension WatchTransfer: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error {
            NSLog("[WatchTransfer] activation failed: \(error.localizedDescription)")
            return
        }
        guard state == .activated else { return }
        // 冲掉激活前攒下的入队请求。这才是「上次没送达的录音」真正被送出去的时刻。
        //
        // ⚠️ 必须回主线程：这个回调在系统队列上，而 `deferred` 的写入方
        // （`enqueue` ← `WatchRecorder`，`@MainActor`）在主线程。
        DispatchQueue.main.async {
            let queued = self.deferred
            self.deferred = []
            if !queued.isEmpty {
                NSLog("[WatchTransfer] activated, flushing \(queued.count) deferred transfer(s)")
                self.enqueueAll(queued)
            }
            // 🚨 **激活完还得叫一声 iPhone，别只是入队就完事。** 投递时机由系统定，实测就是
            // 「iPhone 上的 App 活过来的那一刻」—— 冷启动这条路上入队全部落进 `deferred`、
            // 在这里才真正交给系统，如果到此为止，那段录音就只能等用户哪天自己打开手机 App。
            // 判据用 `outstandingFileTransfers` 而不是 `queued.isEmpty`：上个进程留下的
            // 「已交给系统、还没投递」同样需要这一下，而它们根本不经过 `deferred`。
            guard let session = self.session else { return }
            if !session.outstandingFileTransfers.isEmpty || !self.finalizedRecordings().isEmpty {
                self.nudgeCompanion()
            }
            self.onApplicationContext?(session.receivedApplicationContext)
            self.onStateChanged?()
        }
    }

    /// iPhone 的回执。`transferUserInfo` 是排队式的，所以哪怕手表当时不在旁边，
    /// 回执也会在下次连上时到达。
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        DispatchQueue.main.async { self.onApplicationContext?(context) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let name = userInfo[Self.ackKey] as? String else { return }
        DispatchQueue.main.async { self.acknowledge([name]) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            // A failed direct query may have happened just before connectivity returned.
            self.lastReconciliation = nil
            if !self.finalizedRecordings().isEmpty { self.nudgeCompanion() }
            self.onStateChanged?()
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        DispatchQueue.main.async {
            let stillPending = (self.pendingRecordings?() ?? []).contains { $0.url.lastPathComponent == url.lastPathComponent }
            guard stillPending, !self.acknowledgedNames.contains(url.lastPathComponent) else {
                self.onStateChanged?()
                return
            }
            if let error {
                // 刻意不在这里删文件。失败保留 + 手动重发，是因为反过来（失败即删）
                // 意味着永久丢录音，而录音是不可重来的。
                NSLog("[WatchTransfer] transfer failed for \(url.lastPathComponent): \(error.localizedDescription)")
                self.onFailed?(url, error)
            } else {
                self.onDelivered?(url)
            }
            self.audioRetryBudget.delivered(url.lastPathComponent, now: Date())
            self.reconcilePending()
        }
    }
}
