import Foundation

/// Versioned, metadata-only reconciliation. A missing/unknown reply is never a receipt.
enum WatchReceiptProtocol {
    static let requestKey = "watchReceiptRequestV1"
    static let responseKey = "watchReceiptResponseV1"
    static let ackKey = "receivedByPhone" // Keep compatibility with older companions.
    static let batchSize = 100

    static func validName(_ name: String) -> Bool {
        // `.aac` 是现在的录音格式，`.m4a` 是升级前的。两个扩展名都是 4 个字符，下面的
        // `dropLast(4)` 对两者都成立。
        guard name.count <= 64, name.hasPrefix("rec_"),
              name.hasSuffix(".aac") || name.hasSuffix(".m4a") else { return false }
        let anchor = name.dropFirst(4).dropLast(4)
        return !anchor.isEmpty && anchor.allSatisfy { $0.isASCII && $0.isNumber }
            && (Int64(anchor) ?? 0) > 0
    }

    static func names(_ value: Any?) -> [String] {
        guard let names = value as? [String] else { return [] }
        var seen = Set<String>()
        return names.filter { validName($0) && seen.insert($0).inserted }
    }

    static func batches(_ names: [String]) -> [[String]] {
        let names = self.names(names)
        return stride(from: 0, to: names.count, by: batchSize).map {
            Array(names[$0..<min($0 + batchSize, names.count)])
        }
    }
}

/// iPhone receipt state shared by the WC delegate and Flutter main thread.
/// Pending acknowledgements survive process death and failed WCSession deliveries.
final class WatchReceiptStore {
    private let lock = NSRecursiveLock()
    private let defaults: UserDefaults
    private let inbox: URL
    private let rejected: URL
    private static let handledKey = "watchHandledRecordings"
    private static let pendingKey = "watchPendingAcknowledgements"

    init(defaults: UserDefaults = .standard, inbox: URL, rejected: URL) {
        self.defaults = defaults
        self.inbox = inbox
        self.rejected = rejected
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var handledNames: [String] { locked { defaults.stringArray(forKey: Self.handledKey) ?? [] } }
    var pendingNames: [String] { locked { WatchReceiptProtocol.names(defaults.array(forKey: Self.pendingKey)) } }

    func markHandled(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        var names = handledNames
        if !names.contains(name) { names.append(name) }
        // Keep the existing history limit, except receipts still awaiting delivery.
        let pending = Set(pendingNames)
        let recent = Set(names.suffix(300))
        names.removeAll { !recent.contains($0) && !pending.contains($0) }
        defaults.set(names, forKey: Self.handledKey)
    }

    func rememberAcknowledgement(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard WatchReceiptProtocol.validName(name) else { return }
        var names = pendingNames
        if !names.contains(name) { names.append(name) }
        defaults.set(names, forKey: Self.pendingKey)
    }

    func deliveredAcknowledgement(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(pendingNames.filter { $0 != name }, forKey: Self.pendingKey)
    }

    func confirmedNames(for requested: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let handled = Set(handledNames)
        return WatchReceiptProtocol.names(requested).prefix(WatchReceiptProtocol.batchSize).filter { name in
            handled.contains(name) || hasCopy(in: inbox, name: name) || hasCopy(in: rejected, name: name)
        }
    }

    private func hasCopy(in directory: URL, name: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(name).path
        ) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
            && ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0
    }
}

/// Each foreground/manual recovery cycle can retry audio at most three times.
/// Receipt-only queries can continue; they never spend another audio upload.
struct WatchAudioRetryBudget {
    private struct Attempt { var count = 0; var next: Date = .distantPast }
    private var attempts: [String: Attempt] = [:]

    mutating func reserve(_ name: String, now: Date) -> Bool {
        var attempt = attempts[name] ?? Attempt()
        guard attempt.count < 3, now >= attempt.next else { return false }
        let delays: [TimeInterval] = [60, 120, 300]
        attempt.next = now.addingTimeInterval(delays[attempt.count])
        attempt.count += 1
        attempts[name] = attempt
        return true
    }

    mutating func delivered(_ name: String, now: Date) {
        var attempt = attempts[name] ?? Attempt()
        attempt.next = max(attempt.next, now.addingTimeInterval(60))
        attempts[name] = attempt
    }

    mutating func retain(_ names: Set<String>) {
        attempts = attempts.filter { names.contains($0.key) }
    }

    mutating func reset() { attempts.removeAll() }
}
