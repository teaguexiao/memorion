import Foundation

/// 一条已录完、等待同步给 iPhone 的录音。
struct PendingRecording: Identifiable, Equatable {
    let url: URL
    /// 按下录音的那一刻。**不是**录完的时刻，也不是同步的时刻。
    let startedAt: Date
    let byteCount: Int

    var id: String { url.lastPathComponent }
}

/// 待同步录音的本地队列。就是磁盘上一个目录，没有数据库。
///
/// ## 为什么录制时刻编码在文件名里
///
/// 后端 `POST /v1/conversations/upload-audio` 的 `started_at` **没有 `now()` 兜底，缺了
/// 直接 400**，因为 transcript segment 只存相对偏移量，段的绝对时间是
/// `started_at + segment.start` 推导出来的 —— 锚点错了整条对话就落在错误的日期上，
/// 而事后没有任何办法把错锚点和真锚点区分开（后端 `_require_recording_started_at`
/// 有一整段注释讲这件事）。
///
/// 所以锚点绝不能存在一个可能与文件失联的地方。用 sidecar JSON 或 UserDefaults 都存在
/// 「文件在、元数据没了」的形态，而那时唯一的选择是编一个时间或者丢掉录音。把 epoch
/// 毫秒直接编进文件名后，这个形态在结构上就不存在了：能列举到文件就一定知道它的锚点。
/// 后端的 SD 卡同步路径（`routers/sync.py`）用的正是同一招。
///
/// ## 为什么只在确认送达后才删
///
/// 传输失败保留文件、交给用户手动重发。「传输失败就删」在这里等于永久丢录音 ——
/// 这是本仓库反复出现的那类缺陷（失败被当成空结果）的最贵形态。
final class PendingRecordingStore {
    static let filePrefix = "rec_"
    /// 新录音一律写 ADTS（`.aac`）。
    ///
    /// 🚨 **为什么不是 m4a：进程被系统杀掉时，m4a 整段作废，ADTS 只丢最后一帧。**
    /// m4a 的 moov（索引）只在 `AVAudioRecorder.stop()` 时写；watchOS 回收进程时 `stop()`
    /// 根本没机会跑，于是一段录了一小时的文件变成一个打不开的 mdat，启动时只能删掉
    /// （2026-10-30 用户录了一段，表盘组件变成问号，那段录音一条都没传上来）。ADTS 每帧
    /// 自带帧头，截到最后一个完整帧就是一个合法文件 —— 模拟器上 `kill -9` 实测保住了
    /// 被杀前除编码器缓冲（约 1 秒）外的全部音频，后端 `ffmpeg -xerror` 照常解码。
    static let fileExtension = "aac"
    /// 升级前已经录好、还在队列里的旧文件。只读不写。
    static let legacyFileExtension = "m4a"
    static let acceptedExtensions: Set<String> = [fileExtension, legacyFileExtension]

    // MARK: - 正在写的文件

    /// 本进程里正在被 `AVAudioRecorder` 写着的文件。
    ///
    /// 🚨 **ADTS 正在写的文件看起来也是「完整」的**，所以挡住它不能再靠格式判据（m4a 时代
    /// 靠的是「还没有 moov」）。不挡的话，录音中途的一次对账就会把半截文件传给 iPhone，
    /// 回执回来时 `onAcknowledged` 删掉的正是这个还在写的文件。登记放在这里而不是
    /// `WatchRecorder` 里，是因为 `isFinalized` 是三条入队路径唯一的汇聚点
    /// （见 `WatchTransfer.enqueue`），而且它可能在非主线程被调到。
    private static let captureLock = NSLock()
    private static var capturingPaths = Set<String>()

    static func beginCapture(_ url: URL) {
        captureLock.lock(); defer { captureLock.unlock() }
        capturingPaths.insert(url.standardizedFileURL.path)
    }

    static func endCapture(_ url: URL) {
        captureLock.lock(); defer { captureLock.unlock() }
        capturingPaths.remove(url.standardizedFileURL.path)
    }

    static func isCapturing(_ url: URL) -> Bool {
        captureLock.lock(); defer { captureLock.unlock() }
        return capturingPaths.contains(url.standardizedFileURL.path)
    }

    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pending_recordings", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 为一次新录音分配文件路径，锚点即刻写进文件名。
    func newRecordingURL(startedAt: Date) -> URL {
        let millis = Int64((startedAt.timeIntervalSince1970 * 1000).rounded())
        return directory.appendingPathComponent("\(Self.filePrefix)\(millis).\(Self.fileExtension)")
    }

    /// 从文件名还原锚点。解析不出来就返回 nil —— 调用方必须当成「不可上传」处理，
    /// 而不是拿当前时间顶上。
    static func startedAt(from url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix(filePrefix) else { return nil }
        guard let millis = Int64(name.dropFirst(filePrefix.count)) else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000.0)
    }

    /// 待同步列表，按录制时间从早到晚。
    func pending() -> [PendingRecording] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url -> PendingRecording? in
            guard Self.acceptedExtensions.contains(url.pathExtension) else { return nil }
            // 文件名里没有可解析的锚点 —— 只可能是外部改名或旧版本残留。宁可让它留在
            // 磁盘上（用户能在设置里清理），也不要编一个 started_at 传上去。
            guard let startedAt = Self.startedAt(from: url) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return PendingRecording(url: url, startedAt: startedAt, byteCount: size)
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    /// 只在 iPhone 确认收到后调用。
    func remove(_ recording: PendingRecording) {
        do {
            try FileManager.default.removeItem(at: recording.url)
            try? FileManager.default.removeItem(at: WatchRecordingMetadata.sidecarURL(for: recording.url))
        } catch {
            // Keep it visible. Reconciliation retries cleanup on the next receipt.
            NSLog("[PendingStore] confirmed recording could not be removed: \(recording.url.lastPathComponent)")
        }
    }

    /// 丢弃一条不值得同步的录音（太短）。与 `remove` 分开命名，避免把「送达了」
    /// 和「主动扔掉」写成同一个调用而在日志里分不清。
    func discard(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: WatchRecordingMetadata.sidecarURL(for: url))
    }

    var totalPendingBytes: Int {
        pending().reduce(0) { $0 + $1.byteCount }
    }

    // MARK: - 没收尾的文件

    /// 这个文件收尾了没有 —— 也就是**能不能传**。
    ///
    /// - 正在被本进程写的文件：一律不能传（见 `beginCapture`）。
    /// - `.aac`（ADTS）：开头是 ADTS 帧头即可。被杀进程留下的半截尾帧由
    ///   `salvageUnfinalized()` 在启动时截掉，所以这里不必每次扫全文件（它在每 30 秒的
    ///   对账里对每个文件都会被调一次）。
    /// - `.m4a`（升级前的旧文件）：有没有 moov atom。m4a 的 moov 是 `stop()` 时才写的，
    ///   没有它任何解码器都打不开，事后不可恢复。
    ///
    /// 🚨 **这是入队的前置判据，必须由 `WatchTransfer.enqueue` 统一执行，不能靠启动时扫
    /// 一遍。** 2026-08-15 生产上的 `rec_1786778452129.m4a` 就是这么漏出去的：息屏切段开的
    /// 后半段在后台录了 24 秒被系统挂起、`stop()` 没跑，而清理只在
    /// `WatchRecorder.init()` 里跑一次 —— 用户点的那下「立即同步」走的是
    /// `retryPending()`，直接从 `pending()` 取文件入队，绕过了唯一为它准备的检查。
    ///
    /// ⚠️ **判据刻意是「扫字节结构」而不是「试着用 `AVAudioPlayer`/`AVAudioFile` 打开」。**
    /// 后者的失败原因不止一种（编解码限制、临时资源不足），而这个判据下游会**真的删掉用户
    /// 的录音** —— 一次误判就是永久丢一段。
    static func isFinalized(at url: URL) -> Bool {
        guard !isCapturing(url) else { return false }
        if url.pathExtension == fileExtension { return startsWithADTSHeader(at: url) }
        return hasMoovAtom(at: url)
    }

    struct SalvageResult {
        /// 截掉半截尾帧后保住的文件。
        var recovered: [URL] = []
        /// 一帧完整音频都没有、或是无法恢复的旧格式文件，已删除。
        var dropped = 0
    }

    /// 收拾上一个进程没来得及收尾的文件：ADTS 截到最后一个完整帧并保留，一帧都没有的
    /// 删掉；旧 m4a 没有 moov 的只能删掉。
    ///
    /// 🚨 **只能在「此刻没有文件正在被写」时调，绝不能放进 `pending()`。** 安全的时机有两个：
    /// App 启动时，以及 `phase != .recording` 时（见 `WatchRecorder.retryPending()`）。
    /// 本进程正在写的文件额外由 `isCapturing` 挡住，作为第二道保险。
    func salvageUnfinalized() -> SalvageResult {
        var result = SalvageResult()
        for rec in pending() where !Self.isCapturing(rec.url) {
            if rec.url.pathExtension == Self.fileExtension {
                switch Self.trimToCompleteADTSFrames(at: rec.url) {
                case .intact:
                    continue
                case .trimmed(let removedBytes):
                    NSLog("[PendingStore] salvaged \(rec.url.lastPathComponent): trimmed \(removedBytes) trailing bytes")
                    result.recovered.append(rec.url)
                    continue
                case .empty:
                    break
                case .unreadable:
                    // 读不了 ≠ 坏了。留着，下次再看；入队时 `isFinalized` 会自己判断。
                    continue
                }
            } else if Self.hasMoovAtom(at: rec.url) {
                continue
            }
            try? FileManager.default.removeItem(at: rec.url)
            try? FileManager.default.removeItem(at: WatchRecordingMetadata.sidecarURL(for: rec.url))
            NSLog("[PendingStore] dropped unrecoverable \(rec.url.lastPathComponent) (\(rec.byteCount) bytes)")
            result.dropped += 1
        }
        return result
    }

    func url(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    // MARK: - ADTS

    enum ADTSTrimOutcome: Equatable {
        /// 整个文件就是若干个完整帧。
        case intact
        /// 尾部有半截帧（或垃圾），已截掉。
        case trimmed(removedBytes: Int)
        /// 一个完整帧都没有。
        case empty
        /// 文件打不开或截不动。
        case unreadable
    }

    private static func startsWithADTSHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 7), header.count == 7 else { return false }
        return adtsFrameLength(header, at: header.startIndex) != nil
    }

    /// ADTS 帧头：12 位同步字 0xFFF、layer 恒为 0，帧长 13 位（含帧头）。
    private static func adtsFrameLength(_ bytes: Data, at index: Data.Index) -> Int? {
        guard index + 7 <= bytes.endIndex,
              bytes[index] == 0xFF, bytes[index + 1] & 0xF6 == 0xF0 else { return nil }
        let length = (Int(bytes[index + 3] & 0x03) << 11) | (Int(bytes[index + 4]) << 3) | (Int(bytes[index + 5]) >> 5)
        return length >= 7 ? length : nil
    }

    /// 从头逐帧走，把文件截到最后一个完整帧结束的位置。
    ///
    /// 帧头只占 7 字节、整小时的文件约 5.6 万帧，所以按块读进内存再解析，而不是每帧 seek 一次。
    static func trimToCompleteADTSFrames(at url: URL) -> ADTSTrimOutcome {
        guard let handle = try? FileHandle(forUpdating: url) else { return .unreadable }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd() else { return .unreadable }

        var cleanEnd: UInt64 = 0
        var buffer = Data()
        var bufferStart: UInt64 = 0
        let chunk = 256 * 1024
        do {
            try handle.seek(toOffset: 0)
            scan: while true {
                var cursor = Int(cleanEnd - bufferStart)
                while true {
                    guard let length = adtsFrameLength(buffer, at: buffer.startIndex + cursor) else { break }
                    guard cursor + length <= buffer.count else { break }
                    cursor += length
                    cleanEnd = bufferStart + UInt64(cursor)
                }
                // 剩下的字节要么不够一个帧头/一整帧（再读一块），要么不是帧头（停）。
                let remaining = buffer.count - cursor
                let needsMore = remaining < 7 || adtsFrameLength(buffer, at: buffer.startIndex + cursor) != nil
                guard needsMore, bufferStart + UInt64(buffer.count) < total else { break scan }
                buffer = buffer.suffix(remaining)
                bufferStart = cleanEnd
                guard let next = try handle.read(upToCount: chunk), !next.isEmpty else { break scan }
                buffer.append(next)
            }
            if cleanEnd == 0 { return .empty }
            if cleanEnd == total { return .intact }
            try handle.truncate(atOffset: cleanEnd)
            return .trimmed(removedBytes: Int(total - cleanEnd))
        } catch {
            NSLog("[PendingStore] could not trim \(url.lastPathComponent): \(error.localizedDescription)")
            return .unreadable
        }
    }

    /// 走一遍 MP4 顶层 box，看有没有 `moov`。
    ///
    /// box 头是 `[大小 4 字节大端][类型 4 字节]`；`size == 1` 表示真实大小在紧随其后的 8
    /// 字节里，`size == 0` 表示这个 box 一直延伸到文件末尾（录制中的 `mdat` 就是这个形态，
    /// 于是走查在这里终止 —— 结论正是「没收尾」）。
    private static func hasMoovAtom(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let total = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        guard total > 8 else { return false }

        var offset = 0
        while offset + 8 <= total {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let header = try? handle.read(upToCount: 8), header.count == 8 else { return false }

            let size32 = header.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            // box 类型是 4 个 ASCII 字节。解不出来说明结构已经坏了，当成「没收尾」。
            let type = String(bytes: header.suffix(4), encoding: .ascii) ?? ""
            if type == "moov" { return true }

            var advance = size32
            if size32 == 1 {
                guard let ext = try? handle.read(upToCount: 8), ext.count == 8 else { return false }
                advance = ext.reduce(0) { $0 << 8 | Int($1) }
            } else if size32 == 0 {
                return false // 延伸到文件末尾且不是 moov —— 录制中被中断的形态。
            }
            guard advance >= 8 else { return false } // 结构坏了，别在这里死循环。
            offset += advance
        }
        return false
    }
}
