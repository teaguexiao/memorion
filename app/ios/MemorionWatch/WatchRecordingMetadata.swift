import Foundation

/// Audio-relative marks travel with the audio, independently of processing or connectivity.
struct WatchRecordingMark: Codable, Equatable, Identifiable {
    let id: String
    let offsetSeconds: Double
    let markedAtMs: Double
    let contextBeforeSeconds: Double
    let contextAfterSeconds: Double

    init(id: String = UUID().uuidString, offsetSeconds: Double, markedAt: Date) {
        self.id = id
        self.offsetSeconds = offsetSeconds
        self.markedAtMs = markedAt.timeIntervalSince1970 * 1000
        self.contextBeforeSeconds = 15
        self.contextAfterSeconds = 15
    }
}

struct WatchRecordingMetadata: Codable, Equatable {
    static let transferKey = "watchRecordingMetadata"
    var accountId: String? = nil
    let sessionID: String
    let sessionStartedAtMs: Double
    let segmentOffsetSeconds: Double
    let durationSeconds: Double
    let marks: [WatchRecordingMark]

    func slice(offset: Double, duration: Double) -> Self {
        let includesEnd = offset + duration >= durationSeconds - 0.001
        let sliceMarks = marks.filter { $0.offsetSeconds >= offset && ($0.offsetSeconds < offset + duration ||
            (includesEnd && $0.offsetSeconds <= offset + duration)) }
            .map { WatchRecordingMark(id: $0.id, offsetSeconds: $0.offsetSeconds - offset,
                                      markedAt: Date(timeIntervalSince1970: $0.markedAtMs / 1000)) }
        return Self(accountId: accountId, sessionID: sessionID, sessionStartedAtMs: sessionStartedAtMs,
                    segmentOffsetSeconds: segmentOffsetSeconds + offset, durationSeconds: duration, marks: sliceMarks)
    }

    static func sidecarURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("json")
    }

    func save(for audio: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.sidecarURL(for: audio), options: .atomic)
    }

    static func load(for audio: URL) -> Self? {
        guard let data = try? Data(contentsOf: sidecarURL(for: audio)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The user's intent survives system interruptions. Actual capture is reported separately.
struct WatchRecordingSession: Codable, Equatable {
    var accountId: String? = nil
    let id: String
    let startedAt: Date
    var requested: Bool
    var completedDuration: Double
    var marks: [WatchRecordingMark]
    /// 正在写、还没收尾的那个文件名。正常 `stop()` 后清空。
    ///
    /// 启动时它还在 ⇒ 上个进程录到一半被系统回收了。靠它才能把那段救回来的文件按正常
    /// 收尾的方式记账（时长计入 `completedDuration`、标记挂到对的偏移上）—— 文件本身
    /// 很可能恰好停在帧边界上，单看文件分辨不出它是不是被杀的那一段。
    var openCaptureName: String? = nil

    init(startedAt: Date = Date(), accountId: String? = nil) {
        self.accountId = accountId
        id = UUID().uuidString
        self.startedAt = startedAt
        requested = true
        completedDuration = 0
        marks = []
    }

    /// Coalesce accidental rapid taps, and bound the WatchConnectivity metadata size.
    @discardableResult
    mutating func mark(at elapsed: Double, date: Date = Date()) -> WatchRecordingMark? {
        guard requested, elapsed.isFinite, elapsed >= 0 else { return nil }
        if let last = marks.last, elapsed - last.offsetSeconds < 2,
           date.timeIntervalSince1970 * 1000 - last.markedAtMs < 2000 { return last }
        guard marks.count < 200 else { return nil }
        let mark = WatchRecordingMark(offsetSeconds: elapsed, markedAt: date)
        marks.append(mark)
        return mark
    }

    /// A stopped recorder can reset its counter. Keep the last sampled captured duration,
    /// excluding previous segments and interruption gaps; measured file duration still wins.
    func capturedSegmentDuration(liveCounter: Double, lastKnownTotal: Double) -> Double {
        max(0, liveCounter, lastKnownTotal - completedDuration)
    }

    func metadata(segmentOffset: Double, duration: Double, segmentStartedAt: Date? = nil) -> WatchRecordingMetadata {
        let available = max(0, duration)
        let segmentStartMs = segmentStartedAt.map { $0.timeIntervalSince1970 * 1000 } ?? -.infinity
        let segmentMarks = marks.filter {
            $0.offsetSeconds >= segmentOffset && $0.offsetSeconds <= segmentOffset + available + 0.25
                && $0.markedAtMs >= segmentStartMs
        }.map {
            WatchRecordingMark(
                id: $0.id,
                offsetSeconds: min(available, max(0, $0.offsetSeconds - segmentOffset)),
                markedAt: Date(timeIntervalSince1970: $0.markedAtMs / 1000)
            )
        }
        return WatchRecordingMetadata(
            accountId: accountId, sessionID: id,
            sessionStartedAtMs: startedAt.timeIntervalSince1970 * 1000,
            segmentOffsetSeconds: segmentOffset,
            durationSeconds: available,
            marks: segmentMarks
        )
    }
}
