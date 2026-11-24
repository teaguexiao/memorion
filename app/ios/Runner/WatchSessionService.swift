import AVFoundation
import Flutter
import Foundation
import WatchConnectivity

/// iPhone 侧接收 Apple Watch 传来的录音，落盘排队，再交给 Flutter 上传。
///
/// ## 为什么必须在这一侧排队落盘，不能收到就直接回调 Flutter
///
/// `transferFile` 的投递时机由系统决定：手机 App 可能**根本没在运行**，也可能是被这次投递
/// 唤起到后台的。这种时候 `FlutterMethodChannel.invokeMethod` 那一头没人听，事件直接消失。
/// 「收到就 invokeMethod」的写法在前台演示时百分之百通过，而真实使用中会静默丢录音 ——
/// 正是本仓库反复出现的那类缺陷（失败/空被当成正常）。
///
/// 所以这里的真相源是**磁盘上的目录**，MethodChannel 只是「顺便通知一下前台」。Flutter
/// 起来后主动 `getPendingRecordings` 拉一次，上传成功再 `markUploaded` 删文件。
///
/// ## 为什么 Watch 端不自己上传
///
/// `POST /v1/auth/app-token` 换发 bound key 时会**硬删上一把**。第二个设备一旦自己 mint
/// key，手机那把就被撤掉，表现为「手机上某功能一直加载失败」而两头都静默
/// （已加 401 自愈，但没必要再制造一次）。所以 Watch 只递文件，联网全在手机侧。
class WatchSessionService: NSObject {
    /// 与 Watch 端 `WatchTransfer.startedAtKey` 必须一字不差。
    private static let startedAtKey = "startedAtIso8601"
    /// 与 Watch 端 `WatchText.localeKey` 必须一字不差。
    private static let localeKey = "uiLocale"
    /// 与 Watch 端 `PendingRecordingStore.filePrefix` 必须一字不差 —— 文件名里的 epoch
    /// 毫秒是 `started_at` 的**兜底来源**，见 `resolveStartedAt`。
    private static let filePrefix = "rec_"
    /// 与 Watch 端 `WatchTransfer.ackKey` 必须一字不差。手表**只在收到这个回执后才删录音**。
    private static let ackKey = WatchReceiptProtocol.ackKey
    /// 与 Watch 端 `WatchTransfer.nudgeKey` 必须一字不差。见 `didReceiveMessage`。
    private static let nudgeKey = "flushWatchTransfers"

    private let receipts: WatchReceiptStore
    private let inboxLock = NSRecursiveLock()
    private let prepareRecording: (URL, NSRecursiveLock) async throws -> [URL]?

    init(inboxDirectory: URL? = nil, defaults: UserDefaults = .standard,
         prepareRecording: @escaping (URL, NSRecursiveLock) async throws -> [URL]? = {
             try await WatchAudioPreparation.splitIfNeeded($0, fileLock: $1)
         }) {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inbox = inboxDirectory ?? base.appendingPathComponent("watch_recordings", isDirectory: true)
        let rejected = inbox.appendingPathComponent("rejected", isDirectory: true)
        self.inboxDirectory = inbox
        rejectedDirectory = rejected
        receipts = WatchReceiptStore(defaults: defaults, inbox: inbox, rejected: rejected)
        self.prepareRecording = prepareRecording
        super.init()
        requestDefaults = defaults
        momentContext = defaults.dictionary(forKey: "memorion.watch.phoneContext.v1") ?? [:]
        try? FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
    }

    private var channel: FlutterMethodChannel?
    private let momentRequestKey = "memorion.watch.openMoment.v1"
    private var momentContext: [String: Any] = [:]
    private var requestDefaults: UserDefaults = .standard

    /// 只用来打日志。**解析走 `parseIso`**，别拿这个 formatter 去 `date(from:)`。
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// ⚠️ **两种精度都要试。** `ISO8601DateFormatter` 对 `.withFractionalSeconds` 是**严格**的：
    /// 带小数秒的 formatter 解析不了 `…:43Z`，不带的也解析不了 `…:43.456Z` —— 两边都是
    /// 返回 nil，而 `resolveStartedAt` 会静默退到文件名去。手表 App 是独立更新的（已经有
    /// 一版发在 TestFlight 上只发不带小数秒的串），所以这里必须同时认两种，不能假设对端
    /// 跟自己同版。
    private static func parseIso(_ value: String) -> Date? {
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ]
        for options in variants {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            f.timeZone = TimeZone(secondsFromGMT: 0)
            if let date = f.date(from: value) { return date }
        }
        return nil
    }

    /// 手表发来的录音格式。`aac`（ADTS）是手表现在录的格式，进程被杀也能救回来；`m4a` 是
    /// 升级前录的、以及超长录音在这边切出来的片段。四处列举/计数/清理必须共用这一份，否则
    /// 计数和清理对不上，UI 上就是「点了没反应」。
    static let audioExtensions: Set<String> = ["m4a", "wav", "aac"]

    /// 收到但还没上传成功的录音都躺在这里。
    private let inboxDirectory: URL

    /// 后端永久拒绝（400/413/415/422）的录音搬到这里。
    ///
    /// ⚠️ **必须是 `inboxDirectory` 的子目录，而且 `pendingRecordings()` 必须扫不到它。**
    /// 现在靠的是「非递归列举 + 按扩展名过滤」：目录没有 `audioExtensions` 里的扩展名，自然被滤掉。
    /// 谁哪天把列举改成递归（`enumerator(at:)`），被拒的文件就会重新进队列，于是又开始
    /// 每次启动重传一遍 —— 而那是**静默**的，只有 Soniox 账单看得出来。
    ///
    /// **搬而不删**是刻意的：这种 400 也可能来自我们自己（比如把 `started_at` 拼错了），
    /// 那时是所有文件一起被拒，删了就是把用户录音全丢了。
    private let rejectedDirectory: URL

    func setChannel(_ channel: FlutterMethodChannel) {
        self.channel = channel
    }

    /// 必须在 App 启动时就调（`AppDelegate`），不能等 Flutter 页面出现才调：delegate 设晚了
    /// 会漏掉系统在启动瞬间投递的文件。
    func activate() {
        guard WCSession.isSupported() else {
            NSLog("[WatchSession] WCSession unsupported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getStatus":
            result(status())
        case "prepareLongRecordings":
            Task {
                var failedPaths: [String] = []
                for item in pendingRecordings() {
                    guard let path = item["path"] as? String else { continue }
                    let original = URL(fileURLWithPath: path)
                    do {
                        if try await prepareRecording(original, inboxLock) != nil {
                            WatchAudioPreparation.withFileLock(inboxLock) {
                                markHandled(original.lastPathComponent)
                                try? FileManager.default.removeItem(at: original)
                                try? FileManager.default.removeItem(at: WatchRecordingMetadata.sidecarURL(for: original))
                            }
                        }
                    } catch {
                        // Preserve this original and continue preparing unrelated recordings.
                        failedPaths.append(path)
                        NSLog("[WatchSession] preparation failed for \(original.lastPathComponent): \(error)")
                    }
                }
                let failures = failedPaths
                DispatchQueue.main.async { result(failures) }
            }
        case "getPendingRecordings":
            result(pendingRecordings())
        case "markUploaded":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path'", details: nil))
                return
            }
            // 只有上传成功才走到这里。失败必须保留文件 —— 删掉就是永久丢录音。
            let url = URL(fileURLWithPath: path)
            inboxLock.lock()
            defer { inboxLock.unlock() }
            // ⚠️ **先记 handled，再删文件，顺序不能反。** 记录才是「这段已经终局处理」的
            // 真相源，删文件只是清理。反过来写（删成功才记）会在 `removeItem` 失败时留下
            // 一个既没记账、又还躺在队列目录里的文件 —— 下次 `syncPending` 把它当新录音
            // 再传一遍，用户看到两条一模一样的对话，还白烧一份**账号级、与实时转录共享**
            // 的 Soniox 额度。而 `pendingRecordings()` 现在会跳过 handled 过的文件，所以
            // 先记这一下就把「删不掉」从「重复上传」降级成「多占一点磁盘」。
            markHandled(url.lastPathComponent)
            try? FileManager.default.removeItem(at: WatchRecordingMetadata.sidecarURL(for: url))
            let removed = (try? FileManager.default.removeItem(at: url)) != nil
            if !removed {
                NSLog("[WatchSession] uploaded but could not delete \(url.lastPathComponent); marked handled, will retry deleting")
            }
            result(removed)
        case "markRejected":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path'", details: nil))
                return
            }
            result(moveToRejected(path, statusCode: args["statusCode"] as? Int))
        case "clearRejected":
            result(clearRejected())
        case "syncMoments":
            guard let args = call.arguments as? [String: Any], let json = args["json"] as? String,
                  let owner = args["accountId"] as? String else { result(false); return }
            momentContext["watchMoments"] = json
            momentContext["watchMomentsOwner"] = owner
            result(publishMomentContext())
        case "getOpenMomentRequest":
            result(requestDefaults.dictionary(forKey: momentRequestKey))
        case "ackOpenMomentRequest":
            if let id = (call.arguments as? [String: Any])?["id"] as? String,
               requestDefaults.dictionary(forKey: momentRequestKey)?["openWatchMoment"] as? String == id {
                requestDefaults.removeObject(forKey: momentRequestKey)
            }
            result(true)
        case "syncLocale":
            guard let args = call.arguments as? [String: Any],
                  let code = args["code"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'code'", details: nil))
                return
            }
            result(syncLocale(code))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 状态

    /// 给设置页显示「手表是否可用」。三个布尔各自独立，不要合成一个 —— 用户需要知道到底
    /// 是没配表、没装 App，还是只是此刻不可达（不可达完全不影响传输，`transferFile` 是排队式的）。
    ///
    /// ⚠️ **`activated` 必须一起回去。** `isPaired` / `isWatchAppInstalled` 在
    /// `activationState != .activated` 之前**一律是 false**，而激活是异步的（`activate()` 在
    /// `AppDelegate` 里发起，回调可能晚于用户点进设置页）。少了这一位，UI 会把「还没查出来」
    /// 渲染成「未配对手表」/「请在手表上安装 Memorion」—— 让用户去做一件已经做过的事，
    /// 而且看起来完全像个确定的结论。
    private func status() -> [String: Any] {
        guard WCSession.isSupported() else {
            return ["supported": false, "activated": false, "paired": false, "appInstalled": false, "reachable": false, "pendingCount": 0, "rejectedCount": 0]
        }
        let s = WCSession.default
        return [
            "supported": true,
            "activated": s.activationState == .activated,
            "paired": s.isPaired,
            "appInstalled": s.isWatchAppInstalled,
            "reachable": s.isReachable,
            // 这里刻意 `includeDuration: false`：状态是被轮询的（设置页在激活完成前每 500ms
            // 打一次），而算时长要为每个文件开一次 `AVAudioFile`。计数不需要时长。
            "pendingCount": pendingRecordings(includeDuration: false).count,
            "rejectedCount": rejectedCount(),
        ]
    }

    /// 被后端永久拒绝、已搬出队列的条数。
    ///
    /// UI 必须把它显示出来：搬走之后 `pendingCount` 归零，只看那一个数就会说「全部已同步」
    /// —— 而那段录音其实**一条对话都没生成**。这正是本仓库反复出现的那类缺陷（把失败
    /// 呈现成正常）。
    private func rejectedCount() -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: rejectedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }.count
    }

    private func moveToRejected(_ path: String, statusCode: Int?) -> Bool {
        inboxLock.lock()
        defer { inboxLock.unlock() }
        let source = URL(fileURLWithPath: path)
        let destination = rejectedDirectory.appendingPathComponent(source.lastPathComponent)
        do {
            // 同名已存在就先删旧的：同一段录音不会被拒两次，真撞上说明上一次搬完没清干净。
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
            let metadata = WatchRecordingMetadata.sidecarURL(for: source)
            if FileManager.default.fileExists(atPath: metadata.path) {
                try? FileManager.default.moveItem(at: metadata, to: WatchRecordingMetadata.sidecarURL(for: destination))
            }
            // 被拒也是终局：手表若因回执丢失重传，不能再上传一遍去换同一个 400。
            markHandled(source.lastPathComponent)
            NSLog("[WatchSession] rejected(\(statusCode.map(String.init) ?? "?")) → \(destination.lastPathComponent)")
            return true
        } catch {
            // 搬不动就留在队列里。会白重传，但不会丢文件 —— 两害取轻。
            NSLog("[WatchSession] move to rejected failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 删掉所有被永久拒绝的录音，返回真删掉的条数。
    ///
    /// ⚠️ **不可恢复。** 手表侧的原件在收到回执那一刻就删了（见 `sendAck`），`rejected/` 里
    /// 这一份是唯一的一份。所以这个动作只能由用户显式触发、且调用方必须先确认 —— 它跟
    /// `moveToRejected`「搬而不删」的取向正好相反，那条路留着的正是这个后悔的机会。
    ///
    /// ⚠️ **刻意不清 `handledNames`。** 那份记录是回执机制的必要配件，跟磁盘上有没有文件是
    /// 两件事：回执丢了的话手表会重传同一段录音，没有记录就会再上传一遍、再被拒一遍，还白烧
    /// 一份**账号级、与实时转录链路共享**的 Soniox 额度。用户想删的是占着地方的文件，不是
    /// 「这段处理过」这个事实。
    ///
    /// 扩展名过滤要和 `rejectedCount()` 一致，否则删完那个计数不归零 —— UI 上就是「点了没反应」。
    private func clearRejected() -> Int {
        inboxLock.lock()
        defer { inboxLock.unlock() }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: rejectedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var deleted = 0
        for url in urls where Self.audioExtensions.contains(url.pathExtension.lowercased()) {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                try? FileManager.default.removeItem(at: WatchRecordingMetadata.sidecarURL(for: url))
                deleted += 1
            } else {
                NSLog("[WatchSession] could not delete rejected \(url.lastPathComponent)")
            }
        }
        NSLog("[WatchSession] cleared \(deleted) rejected recording(s)")
        return deleted
    }

    private func syncLocale(_ code: String) -> Bool {
        momentContext[Self.localeKey] = code
        return publishMomentContext()
    }

    private func publishMomentContext() -> Bool {
        requestDefaults.set(momentContext, forKey: "memorion.watch.phoneContext.v1")
        guard WCSession.isSupported() else { return false }
        do {
            try WCSession.default.updateApplicationContext(momentContext)
            return true
        } catch { return false }
    }

    private func receiveOpenMoment(_ message: [String: Any]) {
        guard let id = message["openWatchMoment"] as? String,
              let conversation = message["conversationId"] as? String, !conversation.isEmpty,
              let owner = message["accountId"] as? String, !owner.isEmpty else { return }
        var seen = requestDefaults.stringArray(forKey: "memorion.watch.openMoment.seen") ?? []
        guard !seen.contains(id) else { return }
        requestDefaults.set(message, forKey: momentRequestKey)
        seen.append(id)
        requestDefaults.set(Array(seen.suffix(50)), forKey: "memorion.watch.openMoment.seen")
        channel?.invokeMethod("onOpenWatchMoment", arguments: nil)
    }

    // MARK: - 待上传队列

    private func pendingRecordings(includeDuration: Bool = true) -> [[String: Any]] {
        inboxLock.lock()
        defer { inboxLock.unlock() }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: inboxDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let handled = Set(handledNames())

        return urls.compactMap { url -> [String: Any]? in
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            // 已经终局处理过却还在磁盘上 —— 只可能是 `markUploaded` 里删文件那一步失败了
            // （handled 是先记的）。**绝不能返回给上层**：那会把一段已经上传成功的录音再传
            // 一遍，生成第二条一模一样的对话。顺手再删一次，这也是它唯一的自愈机会。
            if handled.contains(url.lastPathComponent) {
                NSLog("[WatchSession] already handled but still on disk: \(url.lastPathComponent), retrying delete")
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: WatchRecordingMetadata.sidecarURL(for: url))
                return nil
            }
            guard let startedAt = Self.startedAtFromFilename(url) else {
                // 文件名里没有锚点 —— 不可上传。留在磁盘上，不要拿当前时间顶上：
                // 后端没有 `now()` 兜底，锚点错了整条对话落在错误的日期上且事后不可区分。
                NSLog("[WatchSession] no anchor in \(url.lastPathComponent), skipping")
                return nil
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var item: [String: Any] = [
                "path": url.path,
                "startedAtMs": Int(startedAt.timeIntervalSince1970 * 1000),
                "byteCount": size,
            ]
            if let metadata = WatchRecordingMetadata.load(for: url), let json = metadata.jsonString {
                item[WatchRecordingMetadata.transferKey] = json
            }
            // 时长解不出来就**不放这个 key**，而不是放 0 —— UI 要能把「还不知道」和
            // 「真的 0 秒」分开显示（后者是不可能的，5s 以下手表侧就丢了）。
            if includeDuration, let seconds = Self.durationSeconds(of: url) {
                item["durationSeconds"] = seconds
            }
            return item
        }
        .sorted { ($0["startedAtMs"] as! Int) < ($1["startedAtMs"] as! Int) }
    }

    /// 音频时长（秒）。**纯展示用**。
    ///
    /// 时长的权威来源是后端解码音频后写进对话的那个值；这里算的是给「待同步」列表显示
    /// 「这段有多长」，让用户知道等的是 40 秒还是 40 分钟的东西。
    ///
    /// ⚠️ **绝不能拿这个结果当删除/过滤判据。** 它失败的原因不止一种（编解码限制、文件正在
    /// 被写、临时资源不足），而「打不开就删」在这里等于永久丢录音。手表侧
    /// `PendingRecordingStore.dropUnfinalized` 那个**会真删文件**的判定刻意走的是扫 box
    /// 结构，正是因为「试着打开」的失败不能唯一地推出「文件坏了」。
    ///
    /// 用 `AVAudioFile` 而不是 `AVURLAsset.duration`：后者在 iOS 16 起已废弃（要换成 async
    /// 的 `load(.duration)`），而这里在同步的 MethodChannel handler 里，不想为一个展示字段
    /// 把整条调用链改成异步。
    private static func durationSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }

    // MARK: - 回执与幂等

    /// 告诉手表「这段我收下了，可以删了」。
    ///
    /// ⚠️ **手表侧删录音只认这个回执**，所以这里每一条 didReceive 都必须发一次，包括
    /// 「早就处理过了」那种重复投递 —— 否则上一次回执丢了的那段录音会永远躺在手表上，
    /// 每次都重传、每次都被这边判重，用户看到的是「待同步」永远不归零。
    ///
    /// `transferUserInfo` 是排队式的：手表不在身边照样能发，系统会在下次连上时投递。
    private func sendAck(_ filename: String) {
        // Persist before checking activation: background delivery can race activation.
        receipts.rememberAcknowledgement(filename)
        if Thread.isMainThread {
            flushAcknowledgements()
        } else {
            DispatchQueue.main.async { [weak self] in self?.flushAcknowledgements() }
        }
    }

    private func flushAcknowledgements() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let queued = Set(session.outstandingUserInfoTransfers.compactMap {
            $0.userInfo[Self.ackKey] as? String
        })
        // Bound system work even after a long offline period. Unsent receipts
        // stay durable; successful callbacks admit the next batch.
        let capacity = max(0, 50 - queued.count)
        for name in receipts.pendingNames.filter({ !queued.contains($0) }).prefix(capacity) {
            session.transferUserInfo([Self.ackKey: name])
        }
    }

    private func handledNames() -> [String] {
        receipts.handledNames + (requestDefaults.stringArray(forKey: "memorion.watch.handledClips") ?? [])
    }

    private func markHandled(_ filename: String) {
        inboxLock.lock()
        defer { inboxLock.unlock() }
        if filename.hasSuffix("_part.m4a") {
            var names = requestDefaults.stringArray(forKey: "memorion.watch.handledClips") ?? []
            if !names.contains(filename) { names.append(filename) }
            requestDefaults.set(Array(names.suffix(500)), forKey: "memorion.watch.handledClips")
        } else { receipts.markHandled(filename) }
    }

    private func receiptReply(to message: [String: Any]) -> [String: Any] {
        guard message[WatchReceiptProtocol.requestKey] is [String] else { return [:] }
        let requested = WatchReceiptProtocol.names(message[WatchReceiptProtocol.requestKey])
        let confirmed = receipts.confirmedNames(for: requested)
        // The queued channel remains the fallback if the immediate reply is lost.
        for name in confirmed { receipts.rememberAcknowledgement(name) }
        flushAcknowledgements()
        NSLog("[WatchSession] receipt reconciliation: requested=\(requested.count) confirmed=\(confirmed.count)")
        return [WatchReceiptProtocol.responseKey: confirmed]
    }

    static func startedAtFromFilename(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix(filePrefix) else { return nil }
        let suffix = name.dropFirst(filePrefix.count)
        let anchor = suffix.hasSuffix("_part") ? suffix.dropLast(5) : suffix
        guard let millis = Int64(anchor) else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000.0)
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error {
            NSLog("[WatchSession] activation failed: \(error.localizedDescription)")
            return
        }
        // ⚠️ **模拟器上 `installed` 会假报 false。** 手机 App 重装/重启若干次之后，watchOS
        // 模拟器那边的安装记录会丢，此时手表上 App 明明在（`xcrun simctl listapps <watch-udid>`
        // 能看到 `me.memorion.api.watchkitapp`）、`simctl list pairs` 也是 active,connected，
        // 但这里报 `installed=false`，`updateApplicationContext` 跟着抛「尚未安装手表版App」。
        // 修法是重装手表 App：`xcrun simctl install <watch-udid> \
        //   build/ios/Debug-dev-iphonesimulator/Memorion.app/Watch/MemorionWatch.app`
        // 然后重启手机 App。真机上没这个现象 —— 别照着模拟器的 false 去改判定逻辑
        // （2026-08-13 实测）。
        NSLog("[WatchSession] activated: paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
        DispatchQueue.main.async {
            self.flushAcknowledgements()
            _ = self.publishMomentContext()
        }
    }

    // iOS 侧这两个是协议必须实现的（Watch 侧没有）。切换手表时会走 deactivate，
    // 必须重新 activate，否则换表后收不到任何文件。
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// 手表叫我们起来（见 Watch 端 `WatchTransfer.nudgeCompanion()`）。
    ///
    /// 🚨 **这个方法必须存在，即使方法体只打一行日志。** 被叫醒本身就是全部目的：
    /// 排队中的 `transferFile` 由系统投递，而实测的投递时机是「这个 App 活过来的那一刻」
    /// —— 一段 13:24 的录音等到 14:06 用户打开 App 才到达。`sendMessage` 会为了送达把
    /// 这个 App 拉起到后台，于是队列跟着被冲掉。
    ///
    /// ⚠️ 而且**不实现它是有害的，不只是少个功能**：手表用的是无 `replyHandler` 的
    /// `sendMessage`，对端没实现这个 delegate 方法时 WatchConnectivity 会在这一侧抛异常。
    ///
    /// 刻意什么都不做：文件由系统投递到 `didReceive`，那才是落盘和回执的地方；
    /// 在这里去扫队列只会跟它抢同一件事。
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["openWatchMoment"] != nil {
            DispatchQueue.main.async { self.receiveOpenMoment(message) }
        }
        guard message[Self.nudgeKey] != nil else { return }
        NSLog("[WatchSession] woken by watch to flush pending transfers")
        DispatchQueue.main.async { self.flushAcknowledgements() }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async { replyHandler(self.receiptReply(to: message)) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async {
            self.receiveOpenMoment(userInfo)
            _ = self.receiptReply(to: userInfo)
        }
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard let name = userInfoTransfer.userInfo[Self.ackKey] as? String else { return }
        DispatchQueue.main.async {
            if error == nil {
                self.receipts.deliveredAcknowledgement(name)
                self.flushAcknowledgements()
            } else {
                // Retain the durable receipt; activation/reachability/nudge retries it.
                NSLog("[WatchSession] receipt delivery failed; retained for retry")
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.flushAcknowledgements() }
    }

    private func saveRecordingMetadata(from file: WCSessionFile, for audio: URL) throws {
        guard let json = file.metadata?[WatchRecordingMetadata.transferKey] as? String else { return }
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "WatchMetadata", code: 1)
        }
        let metadata = try JSONDecoder().decode(WatchRecordingMetadata.self, from: data)
        try metadata.save(for: audio)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        inboxLock.lock()
        var locked = true
        defer { if locked { inboxLock.unlock() } }
        // Keep large copies on WC's serial delegate queue. Receipt bookkeeping
        // is locked separately; the inbox is published only by an atomic move.
        // ⚠️ **必须在这个方法返回前把文件拷走。** 系统在 delegate 返回后立刻删掉
        // `file.fileURL`（它在一个临时 inbox 里）。异步拷贝或者只存下 URL 稍后再读，
        // 拿到的都是一个已经不存在的路径 —— 而表现是「传输成功但录音不见了」。
        let startedAt = resolveStartedAt(for: file)

        // 🚨 **落盘用的名字必须原样沿用手表发来的那个文件名。**
        //
        // 回执带回去的就是这个字符串，而手表侧是拿 `url.lastPathComponent` **逐字**匹配才
        // 会删掉原件。按 `startedAt` 自己重算一个名字曾经在毫秒位上与手表不一致（手表文件名
        // 是毫秒，而 metadata 里的 ISO 串只到秒），于是回执永远匹配不上：手表的「待同步」
        // 不归零、每次启动重传一遍，这边判重后又 ack 同一个错名字 —— 一个静默的死循环，
        // 而两侧看起来都「成功」了。名字里解析不出锚点时才轮到我们自己造一个。
        let millis = Int64((startedAt.timeIntervalSince1970 * 1000).rounded())
        let canonicalName = Self.startedAtFromFilename(file.fileURL) != nil
            ? file.fileURL.lastPathComponent
            : "\(Self.filePrefix)\(millis).\(file.fileURL.pathExtension)"
        let destination = inboxDirectory.appendingPathComponent(canonicalName)

        // 已经终局处理过（上传成功或被永久拒绝）。**必须补发回执再返回** —— 手表之所以
        // 会重传，就是因为上一次回执没到。这里不补发，那段录音在手表上永远删不掉。
        if handledNames().contains(destination.lastPathComponent) {
            NSLog("[WatchSession] already handled: \(destination.lastPathComponent), re-acking")
            sendAck(destination.lastPathComponent)
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                // 同一段录音被传了两次（Watch 端重发、或系统重投）。已经在队列里就不必再拷，
                // 也绝不能覆盖 —— 覆盖会让正在上传的那个文件被换掉。回执同样要补。
                NSLog("[WatchSession] already queued: \(destination.lastPathComponent)")
                try saveRecordingMetadata(from: file, for: destination)
                sendAck(destination.lastPathComponent)
                return
            }
            // Publish only a complete copy. A failed copy must never leave a
            // partial inbox file that a later reconciliation could acknowledge.
            let staging = inboxDirectory.appendingPathComponent(".\(UUID().uuidString).incoming")
            defer { try? FileManager.default.removeItem(at: staging) }
            // Large I/O stays on WC's delegate queue without holding the inbox lock.
            inboxLock.unlock()
            locked = false
            try FileManager.default.copyItem(at: file.fileURL, to: staging)
            inboxLock.lock()
            locked = true
            // Recheck after copying: upload cleanup or a duplicate may have raced the copy.
            if handledNames().contains(destination.lastPathComponent) {
                sendAck(destination.lastPathComponent)
                return
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try saveRecordingMetadata(from: file, for: destination)
                sendAck(destination.lastPathComponent)
                return
            }
            try saveRecordingMetadata(from: file, for: destination)
            do { try FileManager.default.moveItem(at: staging, to: destination) }
            catch {
                try? FileManager.default.removeItem(at: WatchRecordingMetadata.sidecarURL(for: destination))
                throw error
            }
        } catch {
            // ⚠️ 拷失败**绝不能发回执**：手表收到回执就会把它这边的原件删了，而这边什么都
            // 没留下 —— 那就是永久丢录音。不发回执意味着手表会重传，这正是想要的。
            NSLog("[WatchSession] copy failed: \(error.localizedDescription)")
            return
        }

        // 文件已经安全落在这边的队列里了，可以让手表删原件。
        sendAck(destination.lastPathComponent)

        NSLog("[WatchSession] queued \(destination.lastPathComponent) startedAt=\(isoFormatter.string(from: startedAt))")

        // 前台的话顺便通知一声，让用户立刻看到。**没人听也没关系** —— 真相在磁盘上，
        // Flutter 起来后会自己 `getPendingRecordings`。
        // ⚠️ 锚点从**落盘后的文件名**再解析一次，而不是直接用上面那个 `millis`：
        // `getPendingRecordings` 走的就是文件名（`pendingRecordings()`），两条路径必须给出
        // 同一个 `startedAtMs`，否则「前台收到的这条」和「拉队列拿到的同一条」时间会差
        // 不到一秒 —— 小到不会有人发现，却足以让同一段录音上传出两个不同的锚点。
        let anchorMs = Self.startedAtFromFilename(destination)
            .map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? millis
        DispatchQueue.main.async {
            self.channel?.invokeMethod("onRecordingReceived", arguments: [
                "path": destination.path,
                "startedAtMs": Int(anchorMs),
            ])
        }
    }

    /// 录音开始时刻。metadata 优先，文件名兜底。
    ///
    /// ⚠️ **两条来源都失败时用 `Date()` 是刻意的，且只在这一处。** 后端
    /// `_require_recording_started_at` 没有 `now()` 兜底、缺了直接 400，所以这里若返回 nil
    /// 就等于丢掉一段真录音。两条来源同时失败意味着 Watch 端与这里的两个常量不一致
    /// （那是代码 bug，不是运行时状况），此时「时间偏了」比「录音没了」轻。日志里会留痕。
    private func resolveStartedAt(for file: WCSessionFile) -> Date {
        if let iso = file.metadata?[Self.startedAtKey] as? String,
           let date = Self.parseIso(iso) {
            return date
        }
        if let fromName = Self.startedAtFromFilename(file.fileURL) {
            NSLog("[WatchSession] metadata anchor missing, fell back to filename")
            return fromName
        }
        NSLog("[WatchSession] ⚠️ no anchor at all for \(file.fileURL.lastPathComponent) — using now(), timeline will be wrong")
        return Date()
    }
}
