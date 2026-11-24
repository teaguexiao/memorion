import Foundation

/// Raw IMA ADPCM, high nibble first, continuous state across BLE packets.
/// This is not WAV's block ADPCM format. Z62 uses mono, 8 kHz.
struct RingIMAState {
    private var sample = 0
    private var index = 0
    private static let adjustment = [-1, -1, -1, -1, 2, 4, 6, 8]
    private static let steps = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
    mutating func decode(_ nibble: UInt8) -> Int16 {
        let step = Self.steps[index]
        var delta = step >> 3
        if nibble & 1 != 0 { delta += step >> 2 }
        if nibble & 2 != 0 { delta += step >> 1 }
        if nibble & 4 != 0 { delta += step }
        sample = min(32767, max(-32768, sample + (nibble & 8 == 0 ? delta : -delta)))
        index = min(88, max(0, index + Self.adjustment[Int(nibble & 7)]))
        return Int16(sample)
    }
}

struct RingADPCMDecoder {
    let stereo: Bool
    private var left = RingIMAState()
    private var right = RingIMAState()
    init(stereo: Bool = false) { self.stereo = stereo }
    mutating func decode(_ encoded: Data) throws -> Data {
        guard !stereo || encoded.count % 2 == 0 else { throw RingProtocolError.invalid("Truncated stereo ADPCM pair") }
        var pcm = Data(capacity: encoded.count * 4)
        func append(_ sample: Int16) {
            var value = sample.littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let input = Array(encoded)
        if stereo {
            // D interleaves entire ADPCM bytes, one left then one right.
            for offset in stride(from: 0, to: input.count, by: 2) {
                append(left.decode(input[offset] >> 4)); append(right.decode(input[offset + 1] >> 4))
                append(left.decode(input[offset] & 15)); append(right.decode(input[offset + 1] & 15))
            }
        } else {
            for byte in input { append(left.decode(byte >> 4)); append(left.decode(byte & 15)) }
        }
        return pcm
    }
}

enum RingTransferUpdate { case duplicate, progress, complete([String: Any]) }

final class RingDownloadTransfer {
    private let size: Int
    private let file: RingWaveFile
    private var decoder: RingADPCMDecoder
    private var sequence = RingSequence()
    private var count: Int?
    private(set) var rawBytes = 0
    init(size: Int, stereo: Bool) throws {
        guard size > 0 else { throw RingProtocolError.invalid("Missing directory size") }
        self.size = size
        decoder = RingADPCMDecoder(stereo: stereo)
        file = try RingWaveFile(rate: stereo ? 16000 : 8000, channels: stereo ? 2 : 1)
    }
    func append(_ item: RingDownloadPacket) throws -> RingTransferUpdate {
        guard item.size == size, count == nil || count == item.total else { throw RingProtocolError.invalid("File size or packet count changed") }
        count = item.total
        guard try sequence.accept(item.sequence, encoded: item.encoded) else { return .duplicate }
        let last = item.total - (sequence.first == 0 ? 1 : 0)
        guard item.total > 0, item.sequence <= last, rawBytes + item.encoded.count <= size else {
            throw RingProtocolError.invalid("File exceeds directory size")
        }
        try file.append(decoder.decode(item.encoded)); rawBytes += item.encoded.count
        if item.sequence == last {
            guard rawBytes == size else { throw RingProtocolError.invalid("Incomplete recording transfer") }
            return .complete(try file.finish())
        }
        return .progress
    }
    func abort() { file.abort() }
}

/// Owns partial-file cleanup. A WAV is published only after its header is
/// finalized, flushed and atomically renamed; callers never receive .part.
final class RingWaveFile {
    let url: URL
    let rate: Int
    let channels: Int
    private var handle: FileHandle?
    private(set) var bytes = 0
    private var complete = false
    var durationMs: Int { bytes * 1000 / (rate * channels * 2) }
    init(rate: Int = 8000, channels: Int = 1) throws {
        self.rate = rate; self.channels = channels
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memorion-ring-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("recording.wav.part")
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(bytes: 0, rate: rate, channels: channels)) else {
            try? FileManager.default.removeItem(at: dir)
            throw RingProtocolError.invalid("Cannot create audio file")
        }
        do { handle = try FileHandle(forWritingTo: url); try handle?.seekToEnd() }
        catch { try? FileManager.default.removeItem(at: dir); throw error }
    }
    func append(_ pcm: Data) throws {
        guard let handle = handle, !pcm.isEmpty, pcm.count % (2 * channels) == 0,
              bytes + pcm.count <= rate * channels * 2 * 8 * 3600 else {
            throw RingProtocolError.invalid("Invalid PCM or 8 hour duration limit exceeded")
        }
        try handle.write(contentsOf: pcm); bytes += pcm.count
    }
    func finish(minimumMs: Int = 0) throws -> [String: Any] {
        guard let handle = handle, bytes > 0, durationMs >= minimumMs else {
            throw RingProtocolError.invalid("Recording must be at least \(minimumMs / 1000) seconds")
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(bytes: bytes, rate: rate, channels: channels))
        try handle.synchronize(); try handle.close(); self.handle = nil
        let final = url.deletingPathExtension()
        try FileManager.default.moveItem(at: url, to: final)
        complete = true
        return ["path": final.path, "durationMs": durationMs]
    }
    func abort() {
        try? handle?.close(); handle = nil
        if !complete { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
    deinit { abort() }
    static func header(bytes: Int, rate: Int, channels: Int) -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ n: Int) { var v = UInt32(n).littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ n: Int) { var v = UInt16(n).littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        u32(bytes + 36); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16); data.append(Data("data".utf8)); u32(bytes)
        return data
    }
    static func removeInterruptedAudio() {
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for directory in directories where directory.lastPathComponent.hasPrefix("memorion-ring-") {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let partial = directory.appendingPathComponent("recording.wav.part")
            if manager.fileExists(atPath: partial.path) { try? manager.removeItem(at: partial) }
            if let contents = try? manager.contentsOfDirectory(atPath: directory.path), contents.isEmpty { try? manager.removeItem(at: directory) }
        }
    }
}
