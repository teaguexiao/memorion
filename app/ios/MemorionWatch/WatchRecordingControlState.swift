import Foundation
import Darwin

/// Only control state is shared with the widget; audio stays in the Watch app.
struct WatchRecordingControlState: Codable, Equatable {
    /// `interrupted` 只由 `read()` 推出来，App 从不写它：状态文件说在录，但持有租约的进程
    /// 已经不在了 ⇒ 录音**确定**停了（进程被系统回收或崩溃）。它跟 `unconfirmed` 分开，
    /// 是因为前者有明确的下一步（点一下继续录），后者才真的需要打开 App 看。
    enum Phase: String, Codable { case idle, recording, paused, unconfirmed, interrupted }
    var phase: Phase = .idle
    var sessionID: String?

    var symbol: String {
        switch phase {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .paused: return "pause.fill"
        case .unconfirmed: return "questionmark.circle"
        case .interrupted: return "arrow.clockwise.circle.fill"
        }
    }

    var actionTitle: String {
        switch phase {
        case .idle: return "Start recording"
        case .recording, .paused: return "Stop recording"
        case .unconfirmed: return "Open to check"
        case .interrupted: return "Resume recording"
        }
    }

    var statusTitle: String {
        switch phase {
        case .idle: return "Memorion"
        case .recording: return "Recording"
        case .paused: return "Waiting to resume"
        case .unconfirmed: return "Check recording"
        case .interrupted: return "Recording stopped"
        }
    }

    var actionURL: URL {
        // `interrupted` 也走 record：上一次的录音请求还留在 App 里（`recordingRequested`），
        // 启动后会接着同一个 session 续录，不会另起一段。
        if phase == .idle || phase == .interrupted { return URL(string: "memorion-watch://record")! }
        if phase == .unconfirmed { return URL(string: "memorion-watch://open")! }
        var url = URLComponents(string: "memorion-watch://stop")!
        if let sessionID { url.queryItems = [URLQueryItem(name: "session", value: sessionID)] }
        return url.url!
    }
}

final class WatchRecordingControlStore {
    static let groupID = "group.me.memorion.api.watchrecording"
    static let widgetKinds = ["MemorionRecording", "MemorionStartRecording", "MemorionStopRecording"]
    private let container: URL?
    private var ownerFD: Int32 = -1
    private var lastPublished: WatchRecordingControlState?

    init(container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)) {
        self.container = container
    }

    deinit { if ownerFD >= 0 { close(ownerFD) } }

    /// A separate lock file survives atomic state-file replacement. The OS releases
    /// the owner lease on process exit, so the next widget read reports that capture
    /// stopped instead of continuing to claim it. Rendering refresh is system-controlled.
    func publish(_ state: WatchRecordingControlState) throws -> Bool {
        guard let container else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        if ownerFD < 0 {
            let fd = open(container.appendingPathComponent("recording-owner.lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                throw CocoaError(.fileLocking)
            }
            ownerFD = fd
        }
        guard lastPublished != state else { return false }
        try JSONEncoder().encode(state).write(to: container.appendingPathComponent("recording-control.json"), options: .atomic)
        lastPublished = state
        return true
    }

    func read() -> WatchRecordingControlState {
        guard let container else { return WatchRecordingControlState(phase: .unconfirmed) }
        let file = container.appendingPathComponent("recording-control.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return WatchRecordingControlState() }
        guard let data = try? Data(contentsOf: file),
              var state = try? JSONDecoder().decode(WatchRecordingControlState.self, from: data) else {
            return WatchRecordingControlState(phase: .unconfirmed)
        }
        guard state.phase != .idle else { return state }
        let fd = open(container.appendingPathComponent("recording-owner.lock").path, O_RDWR)
        guard fd >= 0 else { state.phase = .unconfirmed; return state }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            // 没人持有租约 ⇒ 写下这份状态的进程已经退出，录音确定停了。
            //
            // ⚠️ 以前这里给的是 `unconfirmed`（问号）。2026-10-30 用户在表盘上看到的就是它：
            // 录着录着进程被系统回收，组件从停止键变成问号，而问号既不说发生了什么、也不说
            // 该做什么。实际情况是确定的，下一步也是确定的 —— 点一下继续录。
            flock(fd, LOCK_UN)
            state.phase = .interrupted
        } else if errno != EWOULDBLOCK {
            state.phase = .unconfirmed
        }
        return state
    }
}
