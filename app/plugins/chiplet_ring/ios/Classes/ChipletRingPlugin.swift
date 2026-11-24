import Flutter
import Foundation
import CoreBluetooth

/// A separate central owns only ring peripherals. Existing device transports
/// and their DFU implementations remain independent of this adapter.
public final class ChipletRingPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let service = CBUUID(string: RingAdvertisement.recordingService)
    private static let tx = CBUUID(string: "BAE80010-4F05-4503-8E65-3AF1F7329D1F")
    private static let rx = CBUUID(string: "BAE80011-4F05-4503-8E65-3AF1F7329D1F")
    private var central: CBCentralManager!
    private var sink: FlutterEventSink?
    private var scanning = false
    // Opt-in physical-probe counters. Never emit other devices' identities.
    private var scanDiagnostics = false
    private var protocolDiagnostics = false
    private var diagnosticResponseCount = 0
    private var scanDiagnosticPulse: DispatchWorkItem?
    private var advertisedPeripherals = Set<UUID>()
    private var advertisementCount = 0
    private var hidAdvertisementCount = 0
    private var recordingAdvertisementCount = 0
    private var ringAdvertisementCount = 0
    private var peripherals = [String: CBPeripheral]()
    private var discoveries = [String: [String: Any]]()
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var connectingID: UUID?
    private var awaitingDisconnect = false
    private var ready = false
    private var connectionWarmup: DispatchWorkItem?
    private var frame: UInt8 = 0
    private var firmware = ""
    private var hardware = ""
    private var feedbackConfigured = false
    private var feedbackReadbackVerified = false
    private var operation: UUID?
    private var pending: FlutterResult?
    private var timeout: DispatchWorkItem?
    private var cleanup: (() -> Void)?
    private var response: ((RingPacket) throws -> Void)?
    private var expected: (frame: UInt8, command: UInt8, subcommand: UInt8)?
    private var capture: RingWaveFile?
    private var captureDecoder = RingADPCMDecoder()
    private var captureSequence = RingSequence()
    private var captureFrame: UInt8?
    private var captureStartToken: UUID?
    private var captureWatchdog: DispatchWorkItem?
    private var stopping = false
    private var stopAcknowledged = false
    private var stopDrain: DispatchWorkItem?
    private var stopWrite: (() -> Void)?
    private var queuedWrite: (Data, CBCharacteristic, CBCharacteristicWriteType)?
    private var writeCompletions = [() -> Void]()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = ChipletRingPlugin()
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "memorion/chiplet_ring", binaryMessenger: registrar.messenger()))
        FlutterEventChannel(name: "memorion/chiplet_ring/events", binaryMessenger: registrar.messenger()).setStreamHandler(plugin)
    }
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
    private func emit(_ value: [String: Any]) { sink?(value) }
    private func trace(_ phase: String, _ value: [String: Any]) {
        guard protocolDiagnostics else { return }
        emit(value.merging(["event": "protocolDiagnostics", "phase": phase]) { _, new in new })
    }
    private func error(_ code: String, _ message: String) -> FlutterError { FlutterError(code: code, message: message, details: nil) }
    private func initialize() {
        guard central == nil else { return }
        RingWaveFile.removeInterruptedAudio()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    private func finish(_ value: Any?) {
        if pending != nil, let failure = value as? FlutterError { trace("error", ["code": failure.code, "message": failure.message ?? ""]) }
        timeout?.cancel(); timeout = nil
        response = nil; expected = nil; queuedWrite = nil; stopWrite = nil
        cleanup?(); cleanup = nil
        let result = pending; pending = nil; operation = nil
        result?(value)
    }
    private func begin(_ result: @escaping FlutterResult) -> UUID? {
        guard operation == nil else { result(error("busy", "Ring operation in progress")); return nil }
        let token = UUID(); operation = token; pending = result
        armTimeout(token, seconds: 30); return token
    }
    private func armTimeout(_ token: UUID, seconds: Double) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.operation == token else { return }
            self.fail("timeout", "Ring did not finish the operation")
        }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func retire() {
        connectionWarmup?.cancel(); connectionWarmup = nil
        let previous = peripheral
        ready = false; feedbackConfigured = false; feedbackReadbackVerified = false; firmware = ""; hardware = ""; peripheral = nil; connectingID = nil; awaitingDisconnect = false
        writeCompletions.removeAll()
        writeCharacteristic = nil; notifyCharacteristic = nil
        abortCapture()
        if let previous = previous {
            previous.delegate = nil
            central.cancelPeripheralConnection(previous)
            emit(["event": "connection", "id": previous.identifier.uuidString, "connected": false])
        }
    }
    private func fail(_ code: String, _ message: String) {
        if capture != nil { emit(["event": "captureError", "message": message]) }
        finish(error(code, message)); retire()
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        if call.method == "stopScan" { stopScanning("stopped"); result(nil); return }
        initialize()
        if call.method == "disconnect" {
            stopScanning("disconnected")
            finish(error("cancelled", "Ring operation cancelled")); retire()
            protocolDiagnostics = false; result(nil); return
        }
        if call.method == "scan" {
            scanDiagnosticPulse?.cancel(); scanDiagnosticPulse = nil
            scanDiagnostics = args["diagnostics"] as? Bool == true
            protocolDiagnostics = scanDiagnostics; diagnosticResponseCount = 0
            advertisedPeripherals.removeAll()
            advertisementCount = 0; hidAdvertisementCount = 0
            recordingAdvertisementCount = 0; ringAdvertisementCount = 0
            scanning = true; discoveries.removeAll()
            startScanIfPowered(); scheduleScanDiagnostics(); result(nil); return
        }
        trace("operation", ["method": call.method])
        if capture != nil && !["stopRecording", "battery"].contains(call.method) {
            result(error("recording", "Stop recording before synchronizing files")); return
        }
        guard let token = begin(result) else { return }
        if call.method == "connect" {
            guard let value = args["id"] as? String, let id = UUID(uuidString: value) else {
                finish(error("identity", "An iOS peripheral UUID is required")); return
            }
            stopScanning("connecting")
            if ready && peripheral?.identifier == id { finish(nil); return }
            retire(); connectingID = id
            connectIfPowered(); return
        }
        guard ready, peripheral?.state == .connected else { finish(error("disconnected", "Connect to the ring first")); return }
        do {
            switch call.method {
            case "battery":
                try request(0x12, 0) { [weak self] packet in
                    self?.finish(try packet.battery())
                }
            case "synchronizeClock":
                guard let timezone = args["timezoneMinutes"] as? Int,
                      timezone % 60 == 0, (-12...14).contains(timezone / 60) else {
                    finish(error("timezone", "Ring clock supports only whole-hour time zones")); return
                }
                let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
                let payload = try RingClock.payload(milliseconds: milliseconds, timezoneMinutes: timezone)
                try request(0x10, 0, payload: payload) { [weak self] packet in
                    guard packet.bytes.count == 4 else { throw RingProtocolError.invalid("Invalid clock acknowledgment") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self, self.operation == token else { return }
                        do {
                            try self.request(0x10, 1) { [weak self] packet in
                                let clock = try RingClock(packet)
                                try clock.verify(milliseconds: Int64(Date().timeIntervalSince1970 * 1000), timezoneMinutes: timezone)
                                self?.finish(clock.result)
                            }
                        } catch { self.fail("clock", String(describing: error)) }
                    }
                }
            case "firmware", "hardware":
                try request(0x11, call.method == "firmware" ? 0 : 1) { [weak self] packet in
                    let value = try packet.text(4)
                    if call.method == "firmware" { self?.firmware = value } else { self?.hardware = value }
                    self?.finish(value)
                }
            case "configureRecordingFeedback":
                try configureFeedback(token) { [weak self] in
                    guard let self = self else { return }
                    self.finish(["start": Int(RingPacket.recordingFeedbackStyle), "stop": Int(RingPacket.recordingFeedbackStyle), "readbackVerified": self.feedbackReadbackVerified ? 1 : 0])
                }
            case "diagnosticImmediateVibration", "diagnosticMotorInfo", "diagnosticReminderInfo":
                // Physical interoperability probe only. No alarm/configuration
                // is changed, and normal app connections cannot use this path.
                let width = args["payloadWidth"] as? Int ?? 2
                let query = args["query"] as? Int ?? 6
                let reminderInfo = call.method == "diagnosticReminderInfo"
                guard protocolDiagnostics, [1, 2].contains(width),
                      (reminderInfo ? query == 8 : [6, 10].contains(query)) else {
                    finish(error("diagnostics", "Enable the physical ring probe first")); return
                }
                var acknowledged = false
                stopWrite = { [weak self] in
                    guard let self = self, self.operation == token else { return }
                    acknowledged = true
                    // Missing firmware replies are evidence, not success. Keep
                    // this temporary diagnostic session available for the next
                    // documented SDK variant after the GATT write completes.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self = self, self.operation == token else { return }
                        self.finish(["writeAcknowledged": true, "responseReceived": false])
                    }
                }
                // SDK 1.2.6 iOS encodes UInt16 LE; Android Lite encodes UInt8.
                let immediate = call.method == "diagnosticImmediateVibration"
                let payload = immediate ? (width == 2 ? Data([1, 0]) : Data([1])) : Data()
                try request(reminderInfo ? 0x8b : 0x83, immediate ? 4 : UInt8(query), payload: payload) { [weak self] packet in
                    var value: [String: Any] = ["writeAcknowledged": acknowledged, "responseReceived": true,
                                               "bytes": packet.bytes.count,
                                               "hex": packet.bytes.prefix(32).map { String(format: "%02x", $0) }.joined()]
                    // Z62 replied with only the four-byte header. Preserve the
                    // evidence without inventing a missing success/status byte.
                    if immediate, packet.bytes.count >= 5 { value["status"] = Int(packet.bytes[4]) }
                    self?.finish(value)
                }
            case "diagnosticFindRing":
                guard protocolDiagnostics else {
                    finish(error("diagnostics", "Enable the physical ring probe first")); return
                }
                var active = true
                var responseHex = ""
                // Best effort stop even if the user cancels this two-second
                // temporary reminder. Do not modify alarms or the DND setting.
                cleanup = { [weak self] in
                    guard active, let self = self, self.ready else { return }
                    active = false
                    let data = RingPacket.request(frame: self.frame, command: 0x8b, subcommand: 1)
                    self.frame &+= 1; try? self.write(data)
                }
                stopWrite = { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self = self, self.operation == token else { return }
                        do {
                            self.response = nil; self.expected = nil
                            self.stopWrite = { [weak self] in
                                guard let self = self, self.operation == token else { return }
                                active = false
                                self.finish(["startWriteAcknowledged": true, "stopWriteAcknowledged": true,
                                             "startResponseHex": responseHex])
                            }
                            let data = RingPacket.request(frame: self.frame, command: 0x8b, subcommand: 1)
                            self.frame &+= 1; try self.write(data)
                        } catch { self.fail("reminder", String(describing: error)) }
                    }
                }
                armTimeout(token, seconds: 6)
                try request(0x8b, 0) { packet in
                    responseHex = packet.bytes.prefix(32).map { String(format: "%02x", $0) }.joined()
                }
            case "healthSnapshot":
                let since = Int(Date().timeIntervalSince1970) - 7 * 86400
                let payload = Data((0..<4).map { UInt8(truncatingIfNeeded: since >> ($0 * 8)) })
                var history = RingHealthHistory()
                // ALL history from the timestamp: does not advance the vendor's
                // unuploaded-data cursor, delete records, or contact its cloud.
                try request(0x36, 1, payload: payload) { [weak self] packet in
                    let previousCount = history.receivedCount
                    if try history.append(packet) { self?.finish(history.snapshot()) }
                    else if history.receivedCount > previousCount { self?.armTimeout(token, seconds: 30) }
                }
            case "storageInfo": try request(0x36, 0x14) { [weak self] packet in self?.finish(try packet.capacity()) }
            case "formatFileSystem":
                guard args["confirmed"] as? Bool == true else { finish(error("confirmation", "Confirm deletion while connected to the ring")); return }
                try request(0x36, 0x13) { [weak self] packet in
                    guard try packet.integer(4, 1) == 1 else { throw RingProtocolError.invalid("Ring did not confirm clearing its files") }
                    self?.finish(nil)
                }
            case "files":
                var files = [Int: [String: Any]](), names = Set<String>(); var count: Int?
                try request(0x36, 0x10) { [weak self] packet in
                    let item = try packet.directory()
                    guard count == nil || count == item.count else { throw RingProtocolError.invalid("File count changed") }
                    count = item.count
                    if let file = item.file, let name = file["name"] as? String {
                        if let previous = files[item.index] {
                            guard NSDictionary(dictionary: previous).isEqual(to: file) else { throw RingProtocolError.invalid("Conflicting directory entry") }
                        } else {
                            guard names.insert(name).inserted else { throw RingProtocolError.invalid("Duplicate file identity") }
                            files[item.index] = file
                            self?.armTimeout(token, seconds: 30)
                        }
                    }
                    if files.count == item.count { self?.finish(files.keys.sorted().compactMap { files[$0] }) }
                }
            case "download": try download(args, token: token)
            case "startRecording":
                if hardware.uppercased().contains("V1.23."), !feedbackConfigured {
                    try configureFeedback(token) { [weak self] in
                        do { try self?.startCapture(token) } catch { self?.fail("feedback", String(describing: error)) }
                    }
                } else { try startCapture(token) }
            case "stopRecording": try stopCapture(token)
            default: finish(FlutterMethodNotImplemented)
            }
        } catch { fail("integrity", String(describing: error)) }
    }

    private func startScanIfPowered() {
        if central.state == .poweredOn, scanning {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else if central.state != .unknown && central.state != .resetting && scanning {
            emit(["event": "scanError", "message": "Bluetooth unavailable (\(central.state.rawValue))"])
        }
        emitScanDiagnostics("state")
    }
    private func stopScanning(_ reason: String) {
        scanning = false; central?.stopScan()
        emitScanDiagnostics(reason)
        scanDiagnostics = false
        scanDiagnosticPulse?.cancel(); scanDiagnosticPulse = nil
        advertisedPeripherals.removeAll()
    }
    private func emitScanDiagnostics(_ reason: String) {
        guard scanDiagnostics else { return }
        let state = central?.state ?? .unknown
        let label: String
        switch state {
        case .unknown: label = "unknown"
        case .resetting: label = "resetting"
        case .unsupported: label = "unsupported"
        case .unauthorized: label = "unauthorized"
        case .poweredOff: label = "poweredOff"
        case .poweredOn: label = "poweredOn"
        @unknown default: label = "unknown"
        }
        emit(["event": "scanDiagnostics", "reason": reason,
              "bluetoothState": label, "scanning": central?.isScanning ?? false,
              "advertisements": advertisementCount,
              "uniquePeripherals": advertisedPeripherals.count,
              "uniqueCountCapped": advertisedPeripherals.count >= 4096,
              "hidAdvertisements": hidAdvertisementCount,
              "recordingAdvertisements": recordingAdvertisementCount,
              "ringAdvertisements": ringAdvertisementCount])
    }
    private func scheduleScanDiagnostics() {
        guard scanDiagnostics, scanning else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.scanDiagnostics, self.scanning else { return }
            self.emitScanDiagnostics("progress")
            self.scheduleScanDiagnostics()
        }
        scanDiagnosticPulse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }
    private func connectIfPowered() {
        guard let id = connectingID else { return }
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting { fail("bluetooth", "Bluetooth unavailable (\(central.state.rawValue))") }
            return
        }
        guard let found = peripherals[id.uuidString] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            finish(error("identity", "Scan for the ring before connecting")); connectingID = nil; return
        }
        peripheral = found; found.delegate = self
        if found.state == .disconnecting { awaitingDisconnect = true; return }
        central.connect(found, options: nil)
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startScanIfPowered(); connectIfPowered() }
        else if central.state != .unknown && central.state != .resetting {
            startScanIfPowered()
            if peripheral != nil || operation != nil { fail("bluetooth", "Bluetooth unavailable (\(central.state.rawValue))") }
        }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if scanDiagnostics {
            advertisementCount += 1
            if advertisedPeripherals.count < 4096 { advertisedPeripherals.insert(peripheral.identifier) }
            if services.contains(CBUUID(string: "1812")) { hidAdvertisementCount += 1 }
            if services.contains(Self.service) { recordingAdvertisementCount += 1 }
        }
        guard let ring = RingAdvertisement(
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            cachedName: peripheral.name, services: services.map { $0.uuidString },
            manufacturer: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        ) else { return }
        if scanDiagnostics { ringAdvertisementCount += 1 }
        let id = peripheral.identifier.uuidString
        peripherals[id] = peripheral
        discoveries[id] = ["id": id, "name": ring.name, "mac": ring.mac, "rssi": RSSI.intValue]
        emit(["event": "devices", "devices": discoveries.keys.sorted().compactMap { discoveries[$0] }])
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, connectingID == peripheral.identifier else { return }
        let token = operation
        // Delay service discovery for the 603 connection race seen with the SDK.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral, self.peripheral === peripheral,
                  self.operation == token, peripheral.state == .connected else { return }
            peripheral.discoverServices([Self.service])
        }
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }; fail("connection", error.map(String.init(describing:)) ?? "Ring connection failed")
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if awaitingDisconnect && connectingID == peripheral.identifier && !ready {
            awaitingDisconnect = false
            central.connect(peripheral, options: nil); return
        }
        fail("disconnected", error.map(String.init(describing:)) ?? "Ring disconnected")
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            fail("service", error.map(String.init(describing:)) ?? "Ring service unavailable"); return
        }
        peripheral.discoverCharacteristics([Self.tx, Self.rx], for: service)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil,
              let tx = service.characteristics?.first(where: { $0.uuid == Self.tx }),
              let rx = service.characteristics?.first(where: { $0.uuid == Self.rx }),
              tx.properties.contains(.write) || tx.properties.contains(.writeWithoutResponse),
              rx.properties.contains(.notify) || rx.properties.contains(.indicate) else {
            fail("service", "Ring write/notify characteristics unavailable"); return
        }
        writeCharacteristic = tx; notifyCharacteristic = rx
        #if DEBUG
        NSLog("[RING_BLE] service=%@ tx=%@ rx=%@ properties=%lu/%lu", service.uuid.uuidString, tx.uuid.uuidString, rx.uuid.uuidString, tx.properties.rawValue, rx.properties.rawValue)
        #endif
        peripheral.setNotifyValue(true, for: rx)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === notifyCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else { fail("notify", "Cannot subscribe to ring notifications"); return }
        guard connectingID != nil else { return }
        // The command FAQ recommends three seconds before the first command.
        // Start that interval after notifications are ready, not just didConnect.
        connectionWarmup?.cancel()
        let token = operation
        let warmup = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral,
                  self.peripheral === peripheral, peripheral.state == .connected,
                  self.operation == token, self.connectingID == peripheral.identifier else { return }
            self.connectionWarmup = nil
            self.ready = true; self.connectingID = nil
            self.emit(["event": "connection", "id": peripheral.identifier.uuidString, "connected": true])
            self.finish(nil)
        }
        connectionWarmup = warmup
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: warmup)
    }
    private func request(_ command: UInt8, _ subcommand: UInt8, payload: Data = Data(), receive: @escaping (RingPacket) throws -> Void) throws {
        response = receive; expected = (frame, command, subcommand)
        let data = RingPacket.request(frame: frame, command: command, subcommand: subcommand, payload: payload)
        frame &+= 1; try write(data)
    }
    private func write(_ data: Data) throws {
        guard let peripheral = peripheral, let tx = writeCharacteristic, ready else { throw RingProtocolError.invalid("Ring not ready") }
        let type: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
        guard data.count <= peripheral.maximumWriteValueLength(for: type) else { throw RingProtocolError.invalid("Command exceeds ring MTU") }
        trace("write", ["hex": data.prefix(24).map { String(format: "%02x", $0) }.joined(), "bytes": data.count])
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { queuedWrite = (data, tx, type); return }
        let callback = stopWrite; stopWrite = nil
        if type == .withResponse { writeCompletions.append(callback ?? {}) }
        peripheral.writeValue(data, for: tx, type: type)
        if type == .withoutResponse { callback?() }
    }
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, let queued = queuedWrite else { return }
        queuedWrite = nil; peripheral.writeValue(queued.0, for: queued.1, type: queued.2)
        let callback = stopWrite; stopWrite = nil; callback?()
    }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === writeCharacteristic else { return }
        if let error = error { fail("write", String(describing: error)); return }
        if !writeCompletions.isEmpty { writeCompletions.removeFirst()() }
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === notifyCharacteristic else { return }
        guard error == nil, let data = characteristic.value else { fail("read", "Ring notification failed"); return }
        do {
            let packet = try RingPacket(data)
            if protocolDiagnostics && packet.command != 0x71 && diagnosticResponseCount < 24 {
                diagnosticResponseCount += 1
                trace("notification", ["hex": data.prefix(24).map { String(format: "%02x", $0) }.joined(), "bytes": data.count])
            }
            #if DEBUG
            if packet.command != 0x71 && packet.bytes.count <= 80 {
                NSLog("[RING_BLE] response=%@", data.prefix(21).map { String(format: "%02x", $0) }.joined())
            }
            #endif
            if packet.command == 0x12 && packet.subcommand == 2 {
                let value = try packet.battery()
                emit(["event": "battery", "id": peripheral.identifier.uuidString, "value": value]); return
            }
            if packet.command == 0x71 && capture != nil && packet.frame == captureFrame && packet.bytes.count > 5 {
                guard packet.subcommand == 8 else { throw RingProtocolError.invalid("Unverified live audio codec") }
                let audio = try packet.audio()
                if try captureSequence.accept(audio.sequence, encoded: audio.encoded) {
                    try capture?.append(captureDecoder.decode(audio.encoded))
                    if stopping {
                        if stopAcknowledged { armStopDrain() }
                    } else { armCaptureWatchdog() }
                    if operation == captureStartToken { finish(nil); captureStartToken = nil }
                    emit(["event": "recording", "durationMs": capture?.durationMs ?? 0])
                }
                return
            }
            if let expected = expected, packet.frame == expected.frame, packet.command == 0x36,
               expected.command == 0x36, expected.subcommand == 1,
               [UInt8(3), UInt8(255)].contains(packet.subcommand) {
                finish(self.error("health_unavailable", "Ring cannot provide health history now")); return
            }
            guard let expected = expected, packet.frame == expected.frame,
                  packet.command == expected.command, packet.subcommand == expected.subcommand else { return }
            try response?(packet)
        } catch { fail("integrity", String(describing: error)) }
    }

    private func download(_ args: [String: Any], token: UUID) throws {
        guard let name = args["name"] as? String, !name.isEmpty, name.utf8.count <= 240,
              !name.contains("\0"), let type = args["type"] as? String, ["8", "B", "D"].contains(type.uppercased()),
              let size = (args["size"] as? NSNumber)?.intValue, size > 0 else {
            finish(error("unsupported_codec", "This recording format has not been verified (ADPCM 8/B/D supported)")); return
        }
        let transfer = try RingDownloadTransfer(size: size, stereo: type.uppercased() == "D")
        cleanup = { transfer.abort() }
        try request(0x36, 0x11, payload: Data(name.utf8)) { [weak self] packet in
            guard let self = self else { return }
            let update = try transfer.append(packet.download())
            if case .duplicate = update { return }
            self.armTimeout(token, seconds: 30)
            self.emit(["event": "progress", "name": name, "bytes": transfer.rawBytes, "total": size])
            if case .complete(let audio) = update {
                self.cleanup = nil; self.finish(audio)
            }
        }
    }
    /// Request the documented 1.23 recording feedback settings. A GATT
    /// acknowledgment does not establish motor support or physical vibration.
    /// The observed Z62 firmware does not reply to GET_RING_MOTOR_MODE.
    /// Require acknowledged writes for that variant; report readback separately.
    private func configureFeedback(_ token: UUID, complete: @escaping () -> Void) throws {
        guard hardware.uppercased().contains("V1.23.") else {
            finish(error("unsupported_feedback", "Recording feedback is unverified on this hardware")); return
        }
        let writeOnly = firmware.uppercased().contains("Z62")
        if writeOnly, writeCharacteristic?.properties.contains(.write) != true {
            throw RingProtocolError.invalid("Ring cannot acknowledge feedback configuration")
        }
        feedbackReadbackVerified = false
        func set(_ type: UInt8) throws {
            response = nil; expected = nil
            stopWrite = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self, self.operation == token else { return }
                    do {
                        if writeOnly {
                            self.trace("feedbackWriteAcknowledged", ["type": Int(type), "style": Int(RingPacket.recordingFeedbackStyle)])
                            if type == 1 { try set(2) }
                            else { self.feedbackConfigured = true; complete() }
                            return
                        }
                        try self.request(0x8e, 2, payload: Data([type])) { [weak self] packet in
                            guard let self = self, self.operation == token else { return }
                            try packet.verifyRecordingFeedback(type: type)
                            if type == 1 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                                    guard let self = self, self.operation == token else { return }
                                    do { try set(2) } catch { self.fail("feedback", String(describing: error)) }
                                }
                            } else { self.feedbackConfigured = true; self.feedbackReadbackVerified = true; complete() }
                        }
                    } catch { self.fail("feedback", String(describing: error)) }
                }
            }
            let data = RingPacket.request(frame: frame, command: 0x8d, subcommand: 2, payload: Data([type, RingPacket.recordingFeedbackStyle]))
            frame &+= 1; try write(data)
        }
        try set(1)
    }

    private func startCapture(_ token: UUID) throws {
        guard capture == nil else { finish(error("recording", "Ring is already recording")); return }
        capture = try RingWaveFile(); captureDecoder = RingADPCMDecoder(); captureSequence = RingSequence()
        captureFrame = frame; captureStartToken = token
        let mode: UInt8 = firmware.uppercased().contains("Z62") ? 1 : 8
        try request(0x71, mode, payload: Data([1])) { packet in
            if packet.bytes.count == 5, packet.bytes[4] != 1 { throw RingProtocolError.invalid("Ring rejected recording") }
        }
        armCaptureWatchdog()
    }
    private func stopCapture(_ token: UUID) throws {
        guard capture != nil else { finish(error("audio", "No active recording")); return }
        stopping = true; stopAcknowledged = false; captureWatchdog?.cancel(); captureWatchdog = nil
        armTimeout(token, seconds: 5)
        // 603/Z62 sends no stop reply. The SDK fabricates a local reply.
        // Wait for the GATT write, then drain buffered audio until 500 ms quiet.
        stopWrite = { [weak self] in
            guard let self = self, self.operation == token else { return }
            self.stopAcknowledged = true; self.armStopDrain()
        }
        let mode: UInt8 = firmware.uppercased().contains("Z62") ? 1 : 8
        let data = RingPacket.request(frame: frame, command: 0x71, subcommand: mode, payload: Data([0]))
        frame &+= 1; try write(data)
    }
    private func armStopDrain() {
        stopDrain?.cancel()
        let token = operation
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.stopping, self.operation == token, let capture = self.capture else { return }
            do {
                let audio = try capture.finish(minimumMs: 5000)
                self.capture = nil; self.abortCapture(); self.finish(audio)
            } catch { self.fail("audio", String(describing: error)) }
        }
        stopDrain = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    private func armCaptureWatchdog() {
        captureWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fail("audio", "No audio received for 15 seconds") }
        captureWatchdog = work; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    private func abortCapture() {
        captureWatchdog?.cancel(); captureWatchdog = nil; stopDrain?.cancel(); stopDrain = nil
        capture?.abort(); capture = nil; captureFrame = nil; captureStartToken = nil; stopping = false; stopAcknowledged = false
    }
}
