import Foundation

func hex(_ value: String) -> Data {
    let chars = Array(value); return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
}
var passed = 0
func test(_ name: String, _ body: () throws -> Void) throws {
    try body(); passed += 1; print("PASS \(name)")
}
func check(_ value: Bool, _ reason: String = "Assertion failed") throws {
    if !value { throw RingProtocolError.invalid(reason) }
}
func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw RingProtocolError.invalid("Expected rejection")
}
func packet(_ size: Int, _ total: Int, _ seq: Int, _ data: Data) -> RingDownloadPacket {
    RingDownloadPacket(size: size, total: total, sequence: seq, encoded: data)
}
do {
    try test("synthetic nameless HID advertisement yields ring MAC without an iOS name cache") {
        let ring = RingAdvertisement(localName: nil, cachedName: nil, services: ["1812"], manufacturer: hex("11ff010000000002"))
        try check(ring?.name == "ChipletRing" && ring?.mac == "02:00:00:00:00:01")
        let full = RingAdvertisement(localName: "", cachedName: "BCL6030002", services: ["00001812-0000-1000-8000-00805f9b34fb"], manufacturer: hex("11ff010000000002"))
        try check(full?.name == "BCL6030002" && full?.mac == ring?.mac)
    }
    try test("unrelated HID devices and malformed manufacturer addresses are excluded") {
        for data in [Data(), hex("11ff0100000000"), hex("11ff01000000000200"), hex("12ff010000000002"), hex("11ff000000000000"), hex("11ffffffffffffff")] {
            try check(RingAdvertisement(localName: nil, cachedName: "Keyboard", services: ["1812"], manufacturer: data) == nil)
        }
        try check(RingAdvertisement(localName: nil, cachedName: nil, services: [], manufacturer: hex("11ff010000000002")) == nil)
    }
    try test("named rings and advertised recording service remain discoverable") {
        try check(RingAdvertisement(localName: "bcl603", cachedName: nil, services: [], manufacturer: nil)?.name == "bcl603")
        try check(RingAdvertisement(localName: "", cachedName: "BCL6030002", services: [], manufacturer: nil)?.name == "BCL6030002")
        try check(RingAdvertisement(localName: nil, cachedName: nil, services: [RingAdvertisement.recordingService.lowercased()], manufacturer: nil)?.name == "ChipletRing")
    }
    let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
    let oracle = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures)) as! [String: String]
    let input = Data((0..<256).map { UInt8($0) }) + hex("12ab9977")
    for stereo in [false, true] {
        let mode = stereo ? "stereo" : "mono"
        try test("\(mode) agrees with vendor on all nibble values and state continuity") {
            var decoder = RingADPCMDecoder(stereo: stereo)
            let pcm = try decoder.decode(input.prefix(256)) + decoder.decode(input.suffix(4))
            try check(pcm == hex(oracle[mode]!))
        }
        try test("\(mode) packet partition and decoder reset") {
            var a = RingADPCMDecoder(stereo: stereo), b = RingADPCMDecoder(stereo: stereo), reset = RingADPCMDecoder(stereo: stereo)
            var split = Data()
            for offset in stride(from: 0, to: input.count, by: 2) { split += try b.decode(input.subdata(in: offset..<(offset + 2))) }
            try check(split == a.decode(input))
            try check(split == reset.decode(input))
        }
    }
    try test("odd stereo payload rejected") { var d = RingADPCMDecoder(stereo: true); try rejects { _ = try d.decode(Data([1])) } }
    try test("commands match SDK oracle") {
        let commands: [(UInt8, UInt8, Data, String)] = [
            (0x12,0,Data(),"00001200"),(0x12,2,Data(),"00011202"),
            (0x11,0,Data(),"00021100"),(0x11,1,Data(),"00031101"),
            (0x36,0x10,Data(),"00043610"),
            (0x36,0x11,Data("00_20261116_120000_8".utf8),"0005361130305f32303236313131365f3132303030305f38"),
            (0x36,0x12,Data("00_20261116_120000_8".utf8),"0006361230305f32303236313131365f3132303030305f38"),
            (0x36,0x13,Data(),"00073613"),(0x36,0x14,Data(),"00083614"),
            (0x71,1,Data([1]),"0009710101"),(0x71,1,Data([0]),"000a710100"),(0x71,8,Data([1]),"000b710801")]
        for (i, c) in commands.enumerated() {
            try check(RingPacket.request(frame: UInt8(i), command: c.0, subcommand: c.1, payload: c.2) == hex(c.3))
        }
    }
    try test("actual Z62 firmware hardware and empty list") {
        try check(RingPacket(hex("00001100362E302E312E385A3632")).text(4) == "6.0.1.8Z62")
        try check(RingPacket(hex("0001110136303356312E32332E32")).text(4) == "603V1.23.2")
        try check(RingPacket(hex("0004361000")).directory().count == 0)
        try check(RingPacket(hex("0004361000000000")).directory().file == nil)
    }
    try test("actual Z62 directory and capacity") {
        let entry = try RingPacket(hex("000436104800000001000000E02E00003031303230333034303530365F323032355F31325F30363A31353A30343A35355F382E62696E")).directory()
        try check(entry.count == 72 && entry.index == 1 && entry.file?["size"] as? Int == 12000)
        try check(entry.file?["type"] as? String == "8")
        let capacity = try RingPacket(hex("00033614000000010020000000E0FF00")).capacity()
        try check(capacity == ["total":16777216,"used":8192,"free":16769024])
    }
    try test("battery 101 remains unknown and malformed payloads are rejected") {
        try check(RingPacket(hex("000212003e")).battery() == 62)
        try check(RingPacket(hex("0002120064")).battery() == 100)
        try check(RingPacket(hex("0002120065")).battery() == -1)
        try check(RingPacket(hex("00021200ff")).battery() == -1)
        try rejects { _ = try RingPacket(hex("00021200")).battery() }
        try rejects { _ = try RingPacket(hex("000212003e00")).battery() }
    }
    try test("malformed headers counts UTF8 and capacities rejected") {
        for data in [Data(),hex("000011"),hex("0100110030")] { try rejects { _ = try RingPacket(data) } }
        try rejects { _ = try RingPacket(hex("00043610010000000100000004000000ff")).directory() }
        try rejects { _ = try RingPacket(hex("0004361001000000020000000400000038")).directory() }
        try rejects { _ = try RingPacket(hex("00033614010000000100000001000000")).capacity() }
        try rejects { _ = try RingPacket(hex("00001100")).text(4) }
    }
    try test("live packet length checked before decoding") {
        let audio = try RingPacket(hex("0006710802000100000012ab")).audio()
        try check(audio.sequence == 1 && audio.encoded == hex("12ab"))
        try rejects { _ = try RingPacket(hex("0006710803000100000012ab")).audio() }
        try rejects { _ = try RingPacket(hex("000671080000")).audio() }
    }
    try test("sequence gaps duplicates and conflicting retransmissions") {
        var seq = RingSequence()
        try check(seq.accept(1, encoded: hex("12")))
        try check(!seq.accept(1, encoded: hex("12")))
        try rejects { _ = try seq.accept(1, encoded: hex("13")) }
        try rejects { _ = try seq.accept(3, encoded: hex("12")) }
        try check(seq.accept(2, encoded: hex("34")))
        var missing = RingSequence(); try rejects { _ = try missing.accept(2, encoded: hex("12")) }
    }
    try test("download header status and lengths") {
        let p = try RingPacket(hex("00053611010400000002000000010000000200000012ab")).download()
        try check(p.size == 4 && p.total == 2 && p.sequence == 1 && p.encoded == hex("12ab"))
        try rejects { _ = try RingPacket(hex("0005361100")).download() }
        try rejects { _ = try RingPacket(hex("00053611010400000002000000010000000300000012ab")).download() }
    }
    for first in [0,1] {
        try test("complete file transfer sequence base \(first)") {
            let transfer = try RingDownloadTransfer(size: 4, stereo: false)
            _ = try transfer.append(packet(4,2,first,hex("12ab")))
            if case .duplicate = try transfer.append(packet(4,2,first,hex("12ab"))) {} else { throw RingProtocolError.invalid("Duplicate advanced state") }
            guard case .complete(let result) = try transfer.append(packet(4,2,first+1,hex("9977"))) else { throw RingProtocolError.invalid("Not complete") }
            let url = URL(fileURLWithPath: result["path"] as! String)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let wav = try Data(contentsOf: url)
            var decoder = RingADPCMDecoder()
            try check(!url.path.hasSuffix(".part") && wav.count == 60)
            try check(wav.dropFirst(44) == decoder.decode(hex("12ab9977")))
            transfer.abort(); try check(FileManager.default.fileExists(atPath: url.path))
        }
    }
    try test("mismatched size count gap and truncated final file rejected") {
        let transfer = try RingDownloadTransfer(size: 6, stereo: false)
        _ = try transfer.append(packet(6,3,1,hex("12ab")))
        try rejects { _ = try transfer.append(packet(7,3,2,hex("12ab"))) }
        try rejects { _ = try transfer.append(packet(6,4,2,hex("12ab"))) }
        try rejects { _ = try transfer.append(packet(6,3,3,hex("12ab"))) }
        let short = try RingDownloadTransfer(size: 6, stereo: false)
        _ = try short.append(packet(6,2,1,hex("12ab")))
        try rejects { _ = try short.append(packet(6,2,2,hex("12ab"))) }
    }
    try test("partial cleanup completed WAV retention and minimum duration") {
        let unfinished = try RingWaveFile(); let url = unfinished.url
        try unfinished.append(Data([0,0]))
        try rejects { _ = try unfinished.finish(minimumMs:5000) }
        unfinished.abort(); try check(!FileManager.default.fileExists(atPath:url.path))
        let retained = try RingWaveFile(); try retained.append(Data([0,0]))
        let result = try retained.finish(); let complete = URL(fileURLWithPath:result["path"] as! String)
        defer { try? FileManager.default.removeItem(at:complete.deletingLastPathComponent()) }
        let interrupted = try RingWaveFile()
        RingWaveFile.removeInterruptedAudio()
        try check(!FileManager.default.fileExists(atPath:interrupted.url.path))
        try check(FileManager.default.fileExists(atPath:complete.path))
    }
    try test("1.23 recording feedback commands and strict readback") {
        try check(RingPacket.request(frame: 0, command: 0x8d, subcommand: 2, payload: Data([1,RingPacket.recordingFeedbackStyle])) == hex("00008d020102"))
        try check(RingPacket.request(frame: 1, command: 0x8d, subcommand: 2, payload: Data([2,RingPacket.recordingFeedbackStyle])) == hex("00018d020202"))
        try check(RingPacket.request(frame: 1, command: 0x8e, subcommand: 2, payload: Data([2])) == hex("00018e0202"))
        try RingPacket(hex("00008e020102")).verifyRecordingFeedback(type: 1)
        try RingPacket(hex("00008e020202")).verifyRecordingFeedback(type: 2)
        try rejects { try RingPacket(hex("00008e020101")).verifyRecordingFeedback(type: 1) }
        try rejects { try RingPacket(hex("00008e020201")).verifyRecordingFeedback(type: 1) }
        try rejects { try RingPacket(hex("00008e0201")).verifyRecordingFeedback(type: 1) }
    }
    func healthPacket(_ count: Int, _ index: Int, _ time: Int, steps: UInt16 = 0, hr: UInt8 = 0, oxygen: UInt8 = 0, marker: UInt8 = 0, extra: Data = Data()) throws -> RingPacket {
        var data = hex("00003601")
        for value in [count, index, time] { data += Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        data += Data([UInt8(truncatingIfNeeded: steps),UInt8(truncatingIfNeeded: steps >> 8),hr,oxygen,0,0,0,0,0,0,marker,0,0])
        data += extra
        return try RingPacket(data)
    }
    try test("health history completes only with all indices and latest valid fields") {
        var history = RingHealthHistory()
        let time = 1700000000
        try check(!history.append(healthPacket(3,3,time+20,hr:80)))
        try check(!history.append(healthPacket(3,1,time,hr:65,oxygen:98)))
        try check(history.append(healthPacket(3,2,time+10,hr:75)))
        let values = history.snapshot()["metrics"] as! [String:[String:Any]]
        try check(values["heartRate"]?["value"] as? Int == 80)
        try check(values["oxygen"]?["value"] as? Int == 98)
        try check(values["temperature"] == nil)
    }
    try test("health zero unworn invalid-date and unsupported sleep records do not fabricate metrics") {
        var history = RingHealthHistory()
        try check(!history.append(healthPacket(3,1,1700000000,hr:70,marker:100)))
        try check(!history.append(healthPacket(3,2,0,hr:70)))
        try check(history.append(healthPacket(3,3,1700000001)))
        try check((history.snapshot()["metrics"] as! [String:[String:Any]]).isEmpty)
        var empty = RingHealthHistory(); try check(empty.append(RingPacket(hex("0000360100000000"))))
    }
    try test("health duplicate conflicts count changes and RR truncation are rejected") {
        var history = RingHealthHistory()
        let first = try healthPacket(2,1,1700000000,hr:70)
        try check(!history.append(first)); try check(!history.append(first))
        try rejects { _ = try history.append(healthPacket(2,1,1700000000,hr:71)) }
        try rejects { _ = try history.append(healthPacket(3,2,1700000000)) }
        var bytes = first.bytes; bytes[28] = 1
        try rejects { var h = RingHealthHistory(); _ = try h.append(RingPacket(Data(bytes))) }
    }
    try test("vendor 65535 step sentinel never replaces a valid count") {
        var h = RingHealthHistory()
        try check(!h.append(healthPacket(2,1,1700000000,steps: 4321)))
        try check(h.append(healthPacket(2,2,1700000010,steps: 65535)))
        let values = h.snapshot()["metrics"] as! [String:[String:Any]]
        try check(values["steps"]?["value"] as? Int == 4321)
    }
    try test("clock matches manufacturer's UTC milliseconds example without timezone addition") {
        let payload = try RingClock.payload(milliseconds: 1696670393223, timezoneMinutes: 480)
        try check(RingPacket.request(frame: 0x3f, command: 0x10, subcommand: 0, payload: payload) == hex("003f100087a36f098b01000008"))
        let clock = try RingClock(RingPacket(hex("003f100187a36f098b01000008")))
        try check(clock.milliseconds == 1696670393223 && clock.timezoneHours == 8)
        try clock.verify(milliseconds: 1696670395223, timezoneMinutes: 480)
        try rejects { try clock.verify(milliseconds: 1696670405223, timezoneMinutes: 480) }
        try rejects { try clock.verify(milliseconds: 1696670393223, timezoneMinutes: -480) }
    }
    try test("clock signed west timezones and fractional zones are not silently rounded") {
        try check(RingClock.payload(milliseconds: 1696670393223, timezoneMinutes: -480).last == 0xf8)
        let clock = try RingClock(RingPacket(hex("003f100187a36f098b010000f8")))
        try check(clock.timezoneHours == -8)
        for minutes in [330,345,-210,900,-780] {
            try rejects { _ = try RingClock.payload(milliseconds: 1696670393223, timezoneMinutes: minutes) }
        }
    }
    try test("clock requires complete valid command timestamp and timezone") {
        for data in ["003f1001", "003f100187a36f098b010000", "003f110187a36f098b01000008", "003f100187a36f098b01000008ff", "003f1001000000000000000008", "003f1001ffffffffffffffff08", "003f100187a36f098b01000020"] {
            try rejects { _ = try RingClock(RingPacket(hex(data))) }
        }
    }
    try test("health extensions parse true breathing values and reject truncated fields") {
        var h = RingHealthHistory()
        try check(h.append(healthPacket(1,1,1700000000,extra:hex("030b12640302000a070d64003c002800"))))
        let values = h.snapshot()["metrics"] as! [String:[String:Any]]
        try check(values["breathingRate"]?["value"] as? Int == 18)
        try check(values["calories"]?["value"] as? Int == 100)
        // Do not reproduce the SDK's fabricated respiratory rate = HR / 4.
        try rejects { var bad = RingHealthHistory(); _ = try bad.append(healthPacket(1,1,1700000000,extra:hex("030b12"))) }
    }
    // Optional private hardware fixture stays outside the source tree.
    if CommandLine.arguments.count == 4 {
        try test("accepted 31 second Z62 recording PCM is identical") {
            var decoder = RingADPCMDecoder()
            let encoded = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
            let wav = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3]))
            // The raw log includes ten buffered packets after the SDK closed
            // this accepted WAV. Compare precisely the samples it retained.
            let expected = wav.dropFirst(44)
            try check(expected.count % 4 == 0 && encoded.count >= expected.count / 4)
            try check(decoder.decode(Data(encoded.prefix(expected.count / 4))) == expected)
        }
    }
    print("\(passed) native tests passed")
} catch { fputs("FAIL \(error)\n", stderr); exit(1) }
