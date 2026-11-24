import Foundation

enum RingProtocolError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let reason) = self { return reason }; return "Invalid packet" }
}

/// The owner's 603 advertises HID and an eight-byte vendor/MAC field, with
/// no local name or recording service. Do not depend on iOS's cached name.
struct RingAdvertisement {
    static let recordingService = "BAE80001-4F05-4503-8E65-3AF1F7329D1F"
    let name: String
    let mac: String

    init?(localName: String?, cachedName: String?, services: [String], manufacturer: Data?) {
        let name = [localName, cachedName].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let services = services.map { $0.uppercased() }
        let bytes = Array(manufacturer ?? Data())
        var mac = ""
        if bytes.count == 8, bytes[0] == 0x11, bytes[1] == 0xff {
            let address = Array(bytes[2...].reversed())
            if address.contains(where: { $0 != 0 }) && address.contains(where: { $0 != 0xff }) {
                mac = address.map { String(format: "%02X", $0) }.joined(separator: ":")
            }
        }
        let hid = services.contains("1812") || services.contains("00001812-0000-1000-8000-00805F9B34FB")
        guard services.contains(Self.recordingService) || name.uppercased().hasPrefix("BCL") || (hid && !mac.isEmpty) else {
            return nil
        }
        self.name = name.isEmpty ? "ChipletRing" : name
        self.mac = mac
    }
}

/// 603/Z62 commands verified byte for byte against BCLRingSDK 1.2.6.
/// Multibyte response fields are little endian; commands have no checksum.
struct RingPacket {
    let bytes: [UInt8]
    let frame: UInt8
    let command: UInt8
    let subcommand: UInt8

    init(_ data: Data) throws {
        bytes = Array(data)
        guard bytes.count >= 4, bytes[0] == 0 else { throw RingProtocolError.invalid("Invalid response header") }
        frame = bytes[1]; command = bytes[2]; subcommand = bytes[3]
    }
    static func request(frame: UInt8, command: UInt8, subcommand: UInt8, payload: Data = Data()) -> Data {
        Data([0, frame, command, subcommand]) + payload
    }
    func integer(_ offset: Int, _ length: Int) throws -> Int {
        guard offset >= 0, length > 0, length <= 4, offset + length <= bytes.count else {
            throw RingProtocolError.invalid("Truncated response")
        }
        return (0..<length).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
    }
    func text(_ offset: Int) throws -> String {
        guard offset < bytes.count,
              let value = String(bytes: bytes[offset...].prefix { $0 != 0 }, encoding: .utf8), !value.isEmpty else {
            throw RingProtocolError.invalid("Missing UTF-8 value")
        }
        return value
    }
    /// Manufacturer 1.23 mode 2: one long pulse at start, two at stop.
    static let recordingFeedbackStyle: UInt8 = 2
    func verifyRecordingFeedback(type: UInt8) throws {
        guard command == 0x8e, subcommand == 2, bytes.count == 6,
              bytes[4] == type, bytes[5] == Self.recordingFeedbackStyle else {
            throw RingProtocolError.invalid("Ring recording vibration setting did not match")
        }
    }
    func capacity() throws -> [String: Int] {
        guard bytes.count == 16 else { throw RingProtocolError.invalid("Invalid capacity response") }
        let total = try integer(4, 4), used = try integer(8, 4), free = try integer(12, 4)
        guard total > 0, used + free <= total else { throw RingProtocolError.invalid("Invalid capacity values") }
        return ["total": total, "used": used, "free": free]
    }
    func battery() throws -> Int {
        guard bytes.count == 5 else { throw RingProtocolError.invalid("Invalid battery response length") }
        // This Z62 ring also reports 101 (0x65). Its meaning is not documented;
        // keep the connection usable and expose an unknown percentage.
        return bytes[4] <= 100 ? Int(bytes[4]) : -1
    }
    func directory() throws -> RingDirectoryEntry {
        // Z62 returns just one zero byte for an empty directory.
        if bytes.count == 5, bytes[4] == 0 { return RingDirectoryEntry(count: 0, index: 0, file: nil) }
        let count = try integer(4, 4)
        guard count <= 100000 else { throw RingProtocolError.invalid("Invalid file count") }
        if count == 0, bytes.count == 8 { return RingDirectoryEntry(count: 0, index: 0, file: nil) }
        let index = try integer(8, 4), size = try integer(12, 4), name = try text(16)
        guard count > 0, index >= 1, index <= count, name.utf8.count <= 240 else {
            throw RingProtocolError.invalid("Invalid directory entry")
        }
        let stem = name.hasSuffix(".bin") ? String(name.dropLast(4)) : name
        let pieces = stem.split(separator: "_", omittingEmptySubsequences: false)
        let type = pieces.last.map(String.init)?.uppercased() ?? ""
        let date = pieces.count > 2 ? pieces.dropFirst().dropLast().joined(separator: "_") : ""
        return RingDirectoryEntry(count: count, index: index, file: ["name": name, "size": size, "type": type, "date": date])
    }
    func audio() throws -> (sequence: Int, encoded: Data) {
        let length = try integer(4, 2), sequence = try integer(6, 4)
        guard length > 0, length == bytes.count - 10 else { throw RingProtocolError.invalid("Audio length mismatch") }
        return (sequence, Data(bytes[10...]))
    }
    func download() throws -> RingDownloadPacket {
        // Status + file size + packet count + packet index + payload length.
        guard try integer(4, 1) == 1 else { throw RingProtocolError.invalid("Ring rejected the file transfer") }
        let size = try integer(5, 4), total = try integer(9, 4), sequence = try integer(13, 4), length = try integer(17, 4)
        guard size > 0, total > 0, total <= size, length > 0, length == bytes.count - 21 else {
            throw RingProtocolError.invalid("Invalid download packet")
        }
        return RingDownloadPacket(size: size, total: total, sequence: sequence, encoded: Data(bytes[21...]))
    }
}

struct RingDirectoryEntry {
    let count: Int
    let index: Int
    let file: [String: Any]?
}
struct RingDownloadPacket {
    let size: Int
    let total: Int
    let sequence: Int
    let encoded: Data
}

/// The public 0x10 protocol uses UTC Unix milliseconds, not local-time epoch
/// values. Its separate signed time-zone byte only supports whole hours.
struct RingClock {
    let milliseconds: Int64
    let timezoneHours: Int

    static func payload(milliseconds: Int64, timezoneMinutes: Int) throws -> Data {
        guard (1_577_836_800_000..<4_102_444_800_000).contains(milliseconds),
              timezoneMinutes % 60 == 0, (-12...14).contains(timezoneMinutes / 60) else {
            throw RingProtocolError.invalid("Unsupported ring clock or fractional time zone")
        }
        var data = Data((0..<8).map { UInt8(truncatingIfNeeded: milliseconds >> ($0 * 8)) })
        data.append(UInt8(bitPattern: Int8(timezoneMinutes / 60)))
        return data
    }

    init(_ packet: RingPacket) throws {
        guard packet.command == 0x10, packet.subcommand == 1, packet.bytes.count == 13 else {
            throw RingProtocolError.invalid("Invalid ring clock response")
        }
        let value = (0..<8).reduce(UInt64(0)) { $0 | UInt64(packet.bytes[4 + $1]) << ($1 * 8) }
        let hours = Int(Int8(bitPattern: packet.bytes[12]))
        guard value >= 1_577_836_800_000, value < 4_102_444_800_000, (-12...14).contains(hours) else {
            throw RingProtocolError.invalid("Invalid ring clock values")
        }
        milliseconds = Int64(value); timezoneHours = hours
    }

    func verify(milliseconds: Int64, timezoneMinutes: Int) throws {
        guard abs(self.milliseconds - milliseconds) <= 5000, timezoneHours * 60 == timezoneMinutes else {
            throw RingProtocolError.invalid("Ring clock readback did not match")
        }
    }
    var result: [String: Any] { ["milliseconds": milliseconds, "timezoneMinutes": timezoneHours * 60] }
}

/// Reject gaps and conflicting retransmissions before advancing decoder state.
struct RingSequence {
    private var last: Int?
    private var previous: Data?
    private(set) var first: Int?
    mutating func accept(_ sequence: Int, encoded: Data) throws -> Bool {
        if sequence == last {
            guard encoded == previous else { throw RingProtocolError.invalid("Conflicting retransmission") }
            return false
        }
        if let last = last {
            guard sequence == last + 1 else { throw RingProtocolError.invalid("Audio packet gap") }
        } else {
            guard sequence == 0 || sequence == 1 else { throw RingProtocolError.invalid("Missing first audio packet") }
            first = sequence
        }
        last = sequence; previous = encoded
        return true
    }
}

/// Read-only health history. Bounded and complete before values are published.
/// Zero means absent for biometric fields; unworn records must not be shown.
struct RingHealthHistory {
    private var total: Int?
    private var entries = [Int: Data]()
    private var latest = [String: [String: Any]]()
    var receivedCount: Int { entries.count }
    mutating func append(_ packet: RingPacket) throws -> Bool {
        let count = try packet.integer(4, 4)
        guard packet.command == 0x36, packet.subcommand == 1, count <= 10000,
              total == nil || total == count else { throw RingProtocolError.invalid("Invalid health record count") }
        total = count
        if count == 0 {
            guard packet.bytes.count == 8 else { throw RingProtocolError.invalid("Invalid empty health history") }
            return true
        }
        let index = try packet.integer(8, 4), time = try packet.integer(12, 4)
        let rrCount = try packet.integer(28, 1)
        guard index > 0, index <= count, packet.bytes.count >= 29 + rrCount * 2 else {
            throw RingProtocolError.invalid("Truncated health history")
        }
        let raw = Data(packet.bytes)
        if let previous = entries[index] {
            guard previous == raw else { throw RingProtocolError.invalid("Conflicting health record") }
            return entries.count == count
        }
        entries[index] = raw
        guard time >= 1514736000, time <= Int(Date().timeIntervalSince1970) + 86400,
              try packet.integer(26, 1) < 100 else { return entries.count == count }
        func save(_ key: String, _ value: Int, _ maximum: Int = 65534) {
            guard value > 0, value <= maximum, time >= (latest[key]?["time"] as? Int ?? 0) else { return }
            latest[key] = ["value": value, "time": time]
        }
        save("steps", try packet.integer(16, 2))
        save("heartRate", try packet.integer(18, 1), 250)
        save("oxygen", try packet.integer(19, 1), 100)
        save("hrv", try packet.integer(20, 1), 254)
        save("stress", try packet.integer(21, 1), 100)
        save("temperature", try packet.integer(22, 2))
        save("sleepStage", try packet.integer(25, 1), 4)
        var offset = 29 + rrCount * 2
        while offset < packet.bytes.count {
            let length = try packet.integer(offset, 1), kind = try packet.integer(offset + 1, 1)
            guard length >= 1, offset + length + 1 <= packet.bytes.count else {
                throw RingProtocolError.invalid("Truncated health extension")
            }
            let width: Int
            let keys: [String]
            switch kind {
            case 2: width = 2; keys = ["intervalSteps"]
            case 10: width = 1; keys = ["maxCadence", "minCadence"]
            case 11: width = 1; keys = ["breathingRate", "breathingConfidence"]
            case 13: width = 2; keys = ["calories", "basalCalories", "exerciseCalories"]
            case 15: width = 1; keys = ["diastolic", "systolic"]
            default: width = 0; keys = []
            }
            guard length >= 1 + width * keys.count else { throw RingProtocolError.invalid("Invalid health extension length") }
            for (i, key) in keys.enumerated() { save(key, try packet.integer(offset + 2 + i * width, width)) }
            offset += length + 1
        }
        return entries.count == count
    }
    func snapshot() -> [String: Any] { ["recordCount": entries.count, "metrics": latest] }
}
