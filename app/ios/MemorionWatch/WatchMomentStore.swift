import Foundation

struct WatchMoment: Codable, Identifiable, Equatable {
    let id: String
    let markedAtMs: Double
    let offsetSeconds: Double
    var status: String
    var text: String?
    var conversationId: String?
    var recordingKey: String?

    var date: Date { Date(timeIntervalSince1970: markedAtMs / 1000) }
    var isReady: Bool { status == "ready" && !(text ?? "").isEmpty }
}

/// A bounded local read cache; audio remains governed by the receipt protocol.
final class WatchMomentStore {
    private let defaults: UserDefaults
    private let key = "memorion.watch.moments.v1"
    private let ownerKey = "memorion.watch.moments.owner"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var owner: String { defaults.string(forKey: ownerKey) ?? "" }
    var moments: [WatchMoment] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WatchMoment].self, from: data)) ?? []
    }
    func merge(_ incoming: [WatchMoment], owner: String? = nil) {
        var current = moments
        if let owner, owner != self.owner {
            // First pairing retains marks captured before the phone signed in.
            if !self.owner.isEmpty { current = [] }
            defaults.set(owner, forKey: ownerKey)
        }
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for item in incoming {
            // A local retry must not downgrade a transcript already received.
            let priority = ["waitingForPhone": 0, "waitingForUpload": 1, "processing": 2,
                            "audioUnavailable": 3, "failed": 3, "noSpeech": 4, "ready": 5]
            if let existing = byID[item.id], (priority[existing.status] ?? 0) > (priority[item.status] ?? 0) { continue }
            byID[item.id] = item
        }
        let result = byID.values.sorted { $0.markedAtMs > $1.markedAtMs }.prefix(100)
        if let data = try? JSONEncoder().encode(Array(result)) { defaults.set(data, forKey: key) }
    }
    func saveMarks(_ metadata: WatchRecordingMetadata, recordingKey: String, status: String = "waitingForPhone") {
        merge(metadata.marks.map {
            WatchMoment(id: $0.id, markedAtMs: $0.markedAtMs, offsetSeconds: $0.offsetSeconds,
                        status: status, recordingKey: recordingKey)
        })
    }
}
