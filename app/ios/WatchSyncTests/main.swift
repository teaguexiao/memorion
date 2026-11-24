import Foundation
import AVFoundation
import WatchConnectivity
import Flutter


func expectTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    precondition(value, message, file: file, line: line)
}
func expectFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    precondition(!value, message, file: file, line: line)
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
    precondition(actual == expected, "\(actual) != \(expected) \(message)", file: file, line: line)
}
func requireValue<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        throw NSError(domain: "WatchSyncTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing value at \(file):\(line)"])
    }
    return value
}

final class WatchSyncTests {
    var directory: URL!
    var inbox: URL!
    var defaults: UserDefaults!
    var suite: String!
    var phone: WatchSessionService!
    var watch: WatchTransfer!
    var files: [PendingRecording] = []
    var acknowledgements: [String] = []
    var session: WCSession { WCSession.default }
    var receipts: WatchReceiptStore {
        WatchReceiptStore(defaults: defaults, inbox: inbox,
                          rejected: inbox.appendingPathComponent("rejected"))
    }
    let error = NSError(domain: "transport-test", code: 1)

    func setUpWithError() throws {
        WCSession.default = WCSession()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        inbox = directory.appendingPathComponent("phone")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "watch-sync-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        phone = WatchSessionService(inboxDirectory: inbox, defaults: defaults)
        watch = WatchTransfer()
        files = []
        acknowledgements = []
        watch.pendingRecordings = { [unowned self] in
            self.files.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        watch.onAcknowledged = { [unowned self] name in
            self.acknowledgements.append(name)
            if let file = self.files.first(where: { $0.url.lastPathComponent == name }) {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    func tearDownWithError() throws {
        watch?.setForeground(false)
        session.messageHandler = nil
        drain()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }

    func recording(_ index: Int = 1, finalized: Bool = true) throws -> PendingRecording {
        let date = Date(timeIntervalSince1970: 1_790_000_000 + Double(index) / 1000)
        let url = directory.appendingPathComponent("rec_\(1_790_000_000_000 + index).m4a")
        // Minimal ISO-BMFF boxes, exercising the real finalization parser.
        let bytes: [UInt8] = finalized
            ? [0,0,0,8,109,111,111,118,0,0,0,8,109,100,97,116]
            : [0,0,0,0,109,100,97,116,0,0,0,0,0,0,0,0]
        try Data(bytes).write(to: url)
        let recording = PendingRecording(url: url, startedAt: date, byteCount: bytes.count)
        files.append(recording)
        return recording
    }

    func connectPhone() {
        session.messageHandler = { [unowned self] message, reply, _ in
            if let reply {
                self.phone.session(self.session, didReceiveMessage: message, replyHandler: reply)
            } else {
                self.phone.session(self.session, didReceiveMessage: message)
            }
        }
    }

    func uploaded(_ recording: PendingRecording) {
        phone.session(session, didReceive: WCSessionFile(recording.url))
        phone.handleMethodCall(FlutterMethodCall(method: "markUploaded", arguments: [
            "path": inbox.appendingPathComponent(recording.url.lastPathComponent).path,
        ])) { _ in }
    }

    func testLostReceiptReconcilesUploadedFileAndCancelsRetransfer() throws {
        let file = try recording()
        uploaded(file)
        expectFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(file.id).path))
        session.outstandingUserInfoTransfers = [] // Original receipt was lost.
        expectEqual(watch.enqueue(file), .queued)
        let retransmission = session.outstandingFileTransfers[0]
        connectPhone()
        watch.nudgeCompanion()
        drain()
        expectEqual(acknowledgements, [file.id])
        expectFalse(FileManager.default.fileExists(atPath: file.url.path))
        expectTrue(retransmission.cancelled)
        expectEqual(session.outstandingFileTransfers.count, 1, "No new audio transfer for receipt repair")
        var failures = 0
        watch.onFailed = { _, _ in failures += 1 }
        watch.session(session, didFinish: retransmission, error: error)
        drain()
        expectEqual(failures, 0, "Cancelling a confirmed retransmission is not a sync failure")
    }

    func testLegacyOrMalformedReplyNeverDeletes() throws {
        let file = try recording()
        session.messageHandler = { _, reply, _ in reply?(["unrelated": true]) }
        watch.nudgeCompanion()
        drain()
        expectTrue(FileManager.default.fileExists(atPath: file.url.path))
        expectTrue(acknowledgements.isEmpty)
    }

    func testOnlyRequestedFinalizedFilesCanBeAcknowledged() throws {
        let ready = try recording(1)
        let active = try recording(2, finalized: false)
        session.messageHandler = { _, reply, _ in
            reply?([WatchReceiptProtocol.responseKey: [active.id, "rec_999.m4a", "../rec_1.m4a"]])
        }
        watch.nudgeCompanion()
        watch.session(session, didReceiveUserInfo: [WatchReceiptProtocol.ackKey: active.id])
        drain()
        expectTrue(acknowledgements.isEmpty)
        expectTrue(FileManager.default.fileExists(atPath: active.url.path))
        expectTrue(FileManager.default.fileExists(atPath: ready.url.path))
        expectEqual(session.outstandingFileTransfers.map { $0.file.fileURL }, [ready.url])
    }

    func testUnreceivedFileIsQueuedOnceAndKept() throws {
        let file = try recording()
        connectPhone() // Phone has no receipt or copy.
        watch.nudgeCompanion()
        drain()
        watch.nudgeCompanion()
        drain()
        expectTrue(acknowledgements.isEmpty)
        expectTrue(FileManager.default.fileExists(atPath: file.url.path))
        expectEqual(session.outstandingFileTransfers.count, 1)
    }

    func testFailedQueryQueuesMetadataFallbackWithoutDeleting() throws {
        let file = try recording()
        session.messageHandler = { [unowned self] _, _, failure in failure?(self.error) }
        watch.nudgeCompanion()
        drain()
        watch.nudgeCompanion()
        drain()
        expectTrue(FileManager.default.fileExists(atPath: file.url.path))
        let queries = session.outstandingUserInfoTransfers.filter { $0.userInfo[WatchReceiptProtocol.requestKey] != nil }
        expectEqual(queries.count, 1)
        expectEqual(queries.first?.userInfo[WatchReceiptProtocol.requestKey] as? [String], [file.id])
        expectTrue(session.outstandingFileTransfers.isEmpty)
    }

    func testOfflineQueryAndQueuedReceiptRecoverWithoutInteractiveReachability() throws {
        let file = try recording()
        uploaded(file)
        session.outstandingUserInfoTransfers = []
        session.isReachable = false
        expectFalse(watch.nudgeCompanion())
        let request = try requireValue(session.outstandingUserInfoTransfers.first)
        phone.session(session, didReceiveUserInfo: request.userInfo)
        drain()
        let ack = try requireValue(session.outstandingUserInfoTransfers.first { $0.userInfo[WatchReceiptProtocol.ackKey] != nil })
        watch.session(session, didReceiveUserInfo: ack.userInfo)
        drain()
        expectFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testSystemFileDeliveryAloneNeverDeletesWatchCopy() throws {
        let file = try recording()
        watch.session(session, didFinish: WCSessionFileTransfer(WCSessionFile(file.url)), error: nil)
        drain()
        expectTrue(FileManager.default.fileExists(atPath: file.url.path))
        expectTrue(acknowledgements.isEmpty)
    }

    func testPhoneReceiptSurvivesInactiveSessionAndRestart() throws {
        let file = try recording()
        session.activationState = .notActivated
        phone.session(session, didReceive: WCSessionFile(file.url))
        expectEqual(receipts.pendingNames, [file.id])
        expectTrue(session.outstandingUserInfoTransfers.isEmpty)
        phone = WatchSessionService(inboxDirectory: inbox, defaults: defaults)
        session.activationState = .activated
        phone.session(session, activationDidCompleteWith: .activated, error: nil)
        drain()
        expectEqual(session.outstandingUserInfoTransfers.count, 1)
        phone.session(session, didReceiveMessage: [WatchTransfer.nudgeKey: true])
        drain()
        expectEqual(session.outstandingUserInfoTransfers.count, 1, "Do not queue duplicate receipts")
    }

    func testFailedReceiptDeliveryIsRetriedAfterRestart() throws {
        let file = try recording()
        phone.session(session, didReceive: WCSessionFile(file.url))
        let ack = try requireValue(session.outstandingUserInfoTransfers.first)
        session.outstandingUserInfoTransfers = []
        phone.session(session, didFinish: ack, error: error)
        drain()
        expectEqual(receipts.pendingNames, [file.id])
        phone = WatchSessionService(inboxDirectory: inbox, defaults: defaults)
        phone.sessionReachabilityDidChange(session)
        drain()
        expectEqual(session.outstandingUserInfoTransfers.count, 1)
        phone.session(session, didFinish: session.outstandingUserInfoTransfers[0], error: nil)
        drain()
        expectTrue(receipts.pendingNames.isEmpty)
    }

    func testFailedPhoneCopyCreatesNeitherReceiptNorVisiblePartialFile() throws {
        let missing = directory.appendingPathComponent("rec_1790000000001.m4a")
        phone.session(session, didReceive: WCSessionFile(missing))
        expectTrue(receipts.pendingNames.isEmpty)
        expectTrue(session.outstandingUserInfoTransfers.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
        expectFalse(names.contains(missing.lastPathComponent))
        expectFalse(names.contains { $0.hasSuffix(".incoming") })
    }

    func testDuplicateFileReacksWithoutOverwritingInbox() throws {
        let file = try recording()
        phone.session(session, didReceive: WCSessionFile(file.url))
        let destination = inbox.appendingPathComponent(file.id)
        let before = try Data(contentsOf: destination)
        session.outstandingUserInfoTransfers = []
        phone.session(session, didReceive: WCSessionFile(file.url))
        expectEqual(try Data(contentsOf: destination), before)
        expectEqual(session.outstandingUserInfoTransfers.count, 1)
    }

    func testReceiptStoreRejectsUnknownEmptyDirectoryAndTraversal() throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let valid = "rec_1790000000001.m4a", empty = "rec_1790000000002.m4a", folder = "rec_1790000000003.m4a"
        try Data([1]).write(to: inbox.appendingPathComponent(valid))
        try Data().write(to: inbox.appendingPathComponent(empty))
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent(folder), withIntermediateDirectories: true)
        let rejected = inbox.appendingPathComponent("rejected")
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        try Data([1]).write(to: rejected.appendingPathComponent("rec_4.m4a"))
        expectEqual(receipts.confirmedNames(for: [valid, empty, folder, "rec_4.m4a", "rec_5.m4a", "../rec_6.m4a"]), [valid, "rec_4.m4a"])
    }

    func testPendingReceiptHistorySurvivesPruningAndRestart() {
        receipts.rememberAcknowledgement("rec_1.m4a")
        for index in 1...305 { receipts.markHandled("rec_\(index).m4a") }
        expectTrue(receipts.handledNames.contains("rec_1.m4a"))
        expectEqual(receipts.confirmedNames(for: ["rec_1.m4a"]), ["rec_1.m4a"])
        expectFalse(receipts.handledNames.contains("rec_2.m4a"))
    }

    func testBatchingIncludesAllNamesAndBoundsMessages() {
        let names = (1...237).map { "rec_\($0).m4a" }
        let batches = WatchReceiptProtocol.batches(names + [names[0], "../bad", "rec_-1.m4a", "rec_9223372036854775808.m4a"])
        expectEqual(batches.map(\.count), [100, 100, 37])
        expectEqual(batches.flatMap { $0 }, names)
    }

    func testCleanupFailureRetriesLocallyWithoutAnotherPhoneReceipt() throws {
        let file = try recording()
        receipts.markHandled(file.id)
        var attempts = 0
        watch.onAcknowledged = { _ in
            attempts += 1
            // Simulate a transient removeItem failure on the first receipt.
            if attempts > 1 { try? FileManager.default.removeItem(at: file.url) }
        }
        connectPhone()
        watch.nudgeCompanion()
        drain()
        expectEqual(attempts, 1)
        expectTrue(FileManager.default.fileExists(atPath: file.url.path))
        session.isReachable = false
        session.activationState = .notActivated
        session.messageHandler = nil
        expectFalse(watch.nudgeCompanion())
        drain()
        expectEqual(attempts, 2)
        expectFalse(FileManager.default.fileExists(atPath: file.url.path))
        expectTrue(session.outstandingFileTransfers.isEmpty)
    }

    func testPhoneCopiesOffMainWithoutWaitingForMainQueue() throws {
        let file = try recording()
        let copied = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            self.phone.session(self.session, didReceive: WCSessionFile(file.url))
            copied.signal()
        }
        // The main thread deliberately waits: a main.sync file copy deadlocks here.
        expectEqual(copied.wait(timeout: .now() + 2), .success)
        drain()
        expectTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(file.id).path))
        expectEqual(receipts.pendingNames, [file.id])
    }

    func testConcurrentReceiptUpdatesDoNotLoseNames() {
        let store = receipts
        DispatchQueue.concurrentPerform(iterations: 120) { index in
            store.rememberAcknowledgement("rec_\(index + 1).m4a")
            store.markHandled("rec_\(index + 1).m4a")
        }
        expectEqual(Set(store.pendingNames).count, 120)
        expectEqual(Set(store.handledNames).count, 120)
    }

    func testReceiptQueueIsBoundedAndDrainsOnCompletion() throws {
        for index in 1...125 { receipts.rememberAcknowledgement("rec_\(index).m4a") }
        phone.sessionReachabilityDidChange(session)
        drain()
        expectEqual(session.outstandingUserInfoTransfers.count, 50)
        phone.sessionReachabilityDidChange(session)
        drain()
        expectEqual(session.outstandingUserInfoTransfers.count, 50)
        let delivered = session.outstandingUserInfoTransfers.removeFirst()
        phone.session(session, didFinish: delivered, error: nil)
        drain()
        expectEqual(session.outstandingUserInfoTransfers.count, 50)
        expectEqual(receipts.pendingNames.count, 124)
        expectTrue(session.outstandingUserInfoTransfers.contains {
            $0.userInfo[WatchReceiptProtocol.ackKey] as? String == "rec_51.m4a"
        })
    }

    func testAudioRetryBudgetBacksOffAndStopsAfterThreeAttempts() {
        var budget = WatchAudioRetryBudget()
        let start = Date(timeIntervalSince1970: 1000)
        expectTrue(budget.reserve("rec_1.m4a", now: start))
        expectFalse(budget.reserve("rec_1.m4a", now: start.addingTimeInterval(59)))
        expectTrue(budget.reserve("rec_1.m4a", now: start.addingTimeInterval(60)))
        expectFalse(budget.reserve("rec_1.m4a", now: start.addingTimeInterval(179)))
        expectTrue(budget.reserve("rec_1.m4a", now: start.addingTimeInterval(180)))
        expectFalse(budget.reserve("rec_1.m4a", now: start.addingTimeInterval(10000)))
        budget.reset()
        budget.delivered("rec_1.m4a", now: start)
        expectFalse(budget.reserve("rec_1.m4a", now: start.addingTimeInterval(30)))
        expectTrue(budget.reserve("rec_1.m4a", now: start.addingTimeInterval(60)))
    }

    func testRepeatedNegativeRepliesCannotImmediatelyRetransferAudio() throws {
        let file = try recording()
        connectPhone()
        watch.nudgeCompanion()
        drain()
        let transfer = try requireValue(session.outstandingFileTransfers.first)
        session.outstandingFileTransfers = []
        watch.session(session, didFinish: transfer, error: nil)
        drain()
        for _ in 0..<3 {
            watch.sessionReachabilityDidChange(session)
            drain()
        }
        expectTrue(session.outstandingFileTransfers.isEmpty)
        expectTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testLateReplyDoesNotKeepWatchTransferAlive() throws {
        let file = try recording()
        var reply: (([String: Any]) -> Void)?
        session.messageHandler = { _, handler, _ in if let handler { reply = handler } }
        watch.nudgeCompanion()
        weak var formerWatch = watch
        watch = nil
        expectTrue(formerWatch == nil)
        reply?([WatchReceiptProtocol.responseKey: []])
        drain()
        expectTrue(session.outstandingFileTransfers.isEmpty)
        expectTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testMetadataIsDurableBeforePhoneAcknowledges() throws {
        let file = try recording()
        var capture = WatchRecordingSession()
        capture.mark(at: 2)
        let metadata = capture.metadata(segmentOffset: 0, duration: 4)
        phone.session(session, didReceive: WCSessionFile(file.url, metadata: [
            WatchRecordingMetadata.transferKey: try requireValue(metadata.jsonString),
        ]))
        let destination = inbox.appendingPathComponent(file.id)
        expectEqual(WatchRecordingMetadata.load(for: destination), metadata)
        expectTrue(FileManager.default.fileExists(atPath: destination.path))
        drain()
        expectTrue(session.outstandingUserInfoTransfers.contains { $0.userInfo[WatchTransfer.ackKey] as? String == file.id })
    }

    func testInvalidMetadataCannotAcknowledgeAudio() throws {
        let file = try recording()
        phone.session(session, didReceive: WCSessionFile(file.url, metadata: [
            WatchRecordingMetadata.transferKey: "invalid JSON",
        ]))
        drain()
        expectFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(file.id).path))
        expectTrue(session.outstandingUserInfoTransfers.isEmpty)
        expectTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testLocaleAndMomentContextNeverOverwriteEachOther() throws {
        phone.handleMethodCall(FlutterMethodCall(method: "syncLocale", arguments: ["code": "zh"])) { _ in }
        phone.handleMethodCall(FlutterMethodCall(method: "syncMoments", arguments: ["json": "[]", "accountId": "account"])) { _ in }
        expectEqual(session.applicationContext["uiLocale"] as? String, "zh")
        expectEqual(session.applicationContext["watchMoments"] as? String, "[]")
        phone.handleMethodCall(FlutterMethodCall(method: "syncLocale", arguments: ["code": "en"])) { _ in }
        expectEqual(session.applicationContext["watchMomentsOwner"] as? String, "account")
        expectEqual(session.applicationContext["uiLocale"] as? String, "en")
    }

    func testSelectedMomentRequestSurvivesRestartAndDeduplicates() throws {
        let message: [String: Any] = ["openWatchMoment": "request", "conversationId": "source", "offsetSeconds": 42.0, "accountId": "account"]
        phone.session(session, didReceiveMessage: message)
        drain()
        let restarted = WatchSessionService(inboxDirectory: inbox, defaults: defaults)
        var request: [String: Any]?
        restarted.handleMethodCall(FlutterMethodCall(method: "getOpenMomentRequest", arguments: nil)) { request = $0 as? [String: Any] }
        expectEqual(request?["conversationId"] as? String, "source")
        expectEqual(request?["offsetSeconds"] as? Double, 42)
        restarted.handleMethodCall(FlutterMethodCall(method: "ackOpenMomentRequest", arguments: ["id": "request"])) { _ in }
        restarted.session(session, didReceiveUserInfo: message)
        drain()
        restarted.handleMethodCall(FlutterMethodCall(method: "getOpenMomentRequest", arguments: nil)) { request = $0 as? [String: Any] }
        expectTrue(request == nil, "Delayed queued request must not reopen the same moment")
    }

    func testClearingRejectedRecordingAlsoClearsItsMarks() throws {
        let file = try recording()
        var capture = WatchRecordingSession()
        capture.mark(at: 2)
        phone.session(session, didReceive: WCSessionFile(file.url, metadata: [
            WatchRecordingMetadata.transferKey: try requireValue(capture.metadata(segmentOffset: 0, duration: 4).jsonString),
        ]))
        let source = inbox.appendingPathComponent(file.id)
        phone.handleMethodCall(FlutterMethodCall(method: "markRejected", arguments: ["path": source.path])) { _ in }
        let rejected = inbox.appendingPathComponent("rejected").appendingPathComponent(file.id)
        expectTrue(FileManager.default.fileExists(atPath: WatchRecordingMetadata.sidecarURL(for: rejected).path))
        var removed = 0
        phone.handleMethodCall(FlutterMethodCall(method: "clearRejected", arguments: nil)) { removed = ($0 as? Int) ?? 0 }
        expectEqual(removed, 1)
        expectFalse(FileManager.default.fileExists(atPath: rejected.path))
        expectFalse(FileManager.default.fileExists(atPath: WatchRecordingMetadata.sidecarURL(for: rejected).path))
    }

    func testPreparationFailureIsIsolatedAndOriginalRemainsQueued() throws {
        let first = try recording(1)
        let second = try recording(2)
        phone.session(session, didReceive: WCSessionFile(first.url))
        phone.session(session, didReceive: WCSessionFile(second.url))
        var initialPending: [[String: Any]] = []
        phone.handleMethodCall(FlutterMethodCall(method: "getPendingRecordings", arguments: nil)) {
            initialPending = ($0 as? [[String: Any]]) ?? []
        }
        let failingPath = try requireValue(initialPending.compactMap { $0["path"] as? String }
            .first { URL(fileURLWithPath: $0).lastPathComponent == first.id })
        var attempted: [String] = []
        phone = WatchSessionService(inboxDirectory: inbox, defaults: defaults, prepareRecording: { url, _ in
            attempted.append(url.path)
            if url.path == failingPath { throw self.error }
            return nil
        })
        var failedPaths: [String]?
        phone.handleMethodCall(FlutterMethodCall(method: "prepareLongRecordings", arguments: nil)) {
            failedPaths = $0 as? [String]
        }
        let deadline = Date().addingTimeInterval(5)
        while failedPaths == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        expectEqual(failedPaths, [failingPath])
        expectEqual(attempted.count, 2, "One export failure must not block the next recording")
        var pending: [[String: Any]] = []
        phone.handleMethodCall(FlutterMethodCall(method: "getPendingRecordings", arguments: nil)) {
            pending = ($0 as? [[String: Any]]) ?? []
        }
        expectEqual(pending.count, 2)
        expectTrue(FileManager.default.fileExists(atPath: failingPath))
        expectFalse(receipts.handledNames.contains(first.id), "Failed export must not retire the original")
    }

    func testLongAudioExportsRetainMarksAndOriginalUntilCleanup() throws {
        let recording = try recording()
        try FileManager.default.removeItem(at: recording.url)
        let format = try requireValue(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try requireValue(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        let samples = try requireValue(buffer.floatChannelData)[0]
        for i in 0..<48000 { samples[i] = Float(sin(Double(i) * 0.1) * 0.1) }
        var writer: AVAudioFile? = try AVAudioFile(forWriting: recording.url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer?.write(from: buffer)
        writer = nil
        var capture = WatchRecordingSession()
        let first = try requireValue(capture.mark(at: 0.5))
        let last = try requireValue(capture.mark(at: 2.5, date: Date().addingTimeInterval(3)))
        try capture.metadata(segmentOffset: 0, duration: 3).save(for: recording.url)
        let original = try Data(contentsOf: recording.url)
        var complete = false
        var exported: [URL]?
        var failure: Error?
        Task {
            do { exported = try await WatchAudioPreparation.splitIfNeeded(recording.url, maxDuration: 2, chunkDuration: 1) }
            catch { failure = error }
            complete = true
        }
        let deadline = Date().addingTimeInterval(30)
        while !complete && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        expectTrue(complete, "Native export must finish")
        if let failure { throw failure }
        let clips = try requireValue(exported)
        expectTrue(clips.count >= 3)
        expectEqual(try Data(contentsOf: recording.url), original)
        expectEqual(WatchSessionService.startedAtFromFilename(clips[0]), recording.startedAt)
        let clippedMarks = clips.compactMap { WatchRecordingMetadata.load(for: $0) }.flatMap { $0.marks }
        expectEqual(clippedMarks.map { $0.id }, [first.id, last.id])
        expectTrue(clippedMarks.allSatisfy { abs($0.offsetSeconds - 0.5) < 0.001 })
    }

    static let allTests: [(String, (WatchSyncTests) -> () throws -> Void)] = [
        ("clearing rejected audio also clears its metadata", testClearingRejectedRecordingAlsoClearsItsMarks),
        ("export failure keeps source and continues other recordings", testPreparationFailureIsIsolatedAndOriginalRemainsQueued),
        ("locale and moments retain each other", testLocaleAndMomentContextNeverOverwriteEachOther),
        ("selected moment request survives restart", testSelectedMomentRequestSurvivesRestartAndDeduplicates),
        ("native long audio export retains source and marks", testLongAudioExportsRetainMarksAndOriginalUntilCleanup),
        ("metadata is durable before receipt", testMetadataIsDurableBeforePhoneAcknowledges),
        ("bad metadata keeps Watch audio", testInvalidMetadataCannotAcknowledgeAudio),
        ("file copy stays off the main queue", testPhoneCopiesOffMainWithoutWaitingForMainQueue),
        ("concurrent receipt updates are retained", testConcurrentReceiptUpdatesDoNotLoseNames),
        ("receipt queue is bounded", testReceiptQueueIsBoundedAndDrainsOnCompletion),
        ("audio retries back off and stop", testAudioRetryBudgetBacksOffAndStopsAfterThreeAttempts),
        ("negative replies cannot loop audio transfers", testRepeatedNegativeRepliesCannotImmediatelyRetransferAudio),
        ("late reply does not keep transfer alive", testLateReplyDoesNotKeepWatchTransferAlive),
        ("lost receipt repairs uploaded recording", testLostReceiptReconcilesUploadedFileAndCancelsRetransfer),
        ("old or malformed reply keeps audio", testLegacyOrMalformedReplyNeverDeletes),
        ("only requested finalized files are confirmed", testOnlyRequestedFinalizedFilesCanBeAcknowledged),
        ("missing file resumes without duplicate transfer", testUnreceivedFileIsQueuedOnceAndKept),
        ("failed query uses metadata fallback", testFailedQueryQueuesMetadataFallbackWithoutDeleting),
        ("offline request and receipt recover", testOfflineQueryAndQueuedReceiptRecoverWithoutInteractiveReachability),
        ("system delivery is not an app receipt", testSystemFileDeliveryAloneNeverDeletesWatchCopy),
        ("inactive session and restart retain receipts", testPhoneReceiptSurvivesInactiveSessionAndRestart),
        ("failed receipt retries after restart", testFailedReceiptDeliveryIsRetriedAfterRestart),
        ("failed copy cannot acknowledge a partial file", testFailedPhoneCopyCreatesNeitherReceiptNorVisiblePartialFile),
        ("duplicate file reacks without overwrite", testDuplicateFileReacksWithoutOverwritingInbox),
        ("receipt evidence is validated", testReceiptStoreRejectsUnknownEmptyDirectoryAndTraversal),
        ("pending receipt survives history pruning", testPendingReceiptHistorySurvivesPruningAndRestart),
        ("large queues are batched without loss", testBatchingIncludesAllNamesAndBoundsMessages),
        ("failed cleanup retries locally while offline", testCleanupFailureRetriesLocallyWithoutAnotherPhoneReceipt),
    ]
}
for (name, body) in WatchSyncTests.allTests {
    let test = WatchSyncTests()
    do {
        try test.setUpWithError()
        try body(test)()
        try test.tearDownWithError()
        print("PASS: \(name)")
    } catch {
        try? test.tearDownWithError()
        fatalError("FAIL: \(name): \(error)")
    }
}
print("Passed \(WatchSyncTests.allTests.count) Watch synchronization behavioral tests (deterministic transport).")

// A delayed receipt must not downgrade processed content; account switches clear old text.
do {
    let suite = "watch-moment-cache-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WatchMomentStore(defaults: defaults)
    let ready = WatchMoment(id: "mark", markedAtMs: 1000, offsetSeconds: 2,
                            status: "ready", text: "Actual source words", conversationId: "source")
    store.merge([ready], owner: "first")
    store.merge([WatchMoment(id: "mark", markedAtMs: 1000, offsetSeconds: 2, status: "waitingForUpload")])
    expectEqual(store.moments.first, ready)
    store.merge([], owner: "second")
    expectTrue(store.moments.isEmpty)
    print("PASS: delayed receipts preserve processed moments and account changes clear cached words")
}

// Audio-relative context survives segment rotation, retries, and process restart.
do {
    var session = WatchRecordingSession(startedAt: Date(timeIntervalSince1970: 1000))
    let first = try requireValue(session.mark(at: 12, date: Date(timeIntervalSince1970: 1012)))
    expectEqual(session.mark(at: 13, date: Date(timeIntervalSince1970: 1013))?.id, first.id, "rapid taps must not duplicate marks")
    session.completedDuration = 30
    expectEqual(session.capturedSegmentDuration(liveCounter: 0, lastKnownTotal: 42), 12,
                "A system stop must retain the last known segment duration, excluding earlier audio")
    expectEqual(session.capturedSegmentDuration(liveCounter: 90, lastKnownTotal: 42), 90,
                "The live recorder includes background capture missed by the UI timer")
    let second = try requireValue(session.mark(at: 42, date: Date(timeIntervalSince1970: 1100)))
    let metadata = session.metadata(segmentOffset: 30, duration: 20)
    expectEqual(metadata.marks.map { $0.id }, [second.id])
    expectEqual(metadata.marks.first?.offsetSeconds, 12)
    expectEqual(metadata.marks.first?.markedAtMs, 1100000)
    let restored = try JSONDecoder().decode(WatchRecordingSession.self, from: JSONEncoder().encode(session))
    expectTrue(restored.requested, "system interruption must not cancel user intent")
    expectEqual(restored.marks, session.marks)
    session.requested = false
    expectEqual(session.mark(at: 44), nil, "manual stop cancels further marking")
    expectEqual(session.mark(at: .infinity), nil)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = dir.appendingPathComponent("rec_1000000.m4a")
    try metadata.save(for: audio)
    expectEqual(WatchRecordingMetadata.load(for: audio), metadata)
    expectEqual(try JSONDecoder().decode(WatchRecordingMetadata.self, from: Data(metadata.jsonString!.utf8)), metadata)
    print("PASS: persistent recording intent, marks, segment offsets, and metadata recovery")
}

// Crash-safe capture: a killed recorder leaves ADTS that is salvaged, never deleted.
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PendingRecordingStore(directory: root)
    func frame(_ payload: Int) -> Data {
        let length = payload + 7
        // AAC-LC, 16 kHz, mono, no CRC — the header AVAudioRecorder writes on Watch.
        var bytes: [UInt8] = [0xFF, 0xF1, 0x60, 0x40, 0, 0, 0xFC]
        bytes[3] |= UInt8((length >> 11) & 0x03)
        bytes[4] = UInt8((length >> 3) & 0xFF)
        bytes[5] = UInt8((length & 0x07) << 5) | 0x1F
        return Data(bytes) + Data(repeating: 0x21, count: payload)
    }
    func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }

    let frames = (0..<3000).reduce(Data()) { $0 + frame(90 + $1 % 40) } // spans several read chunks
    let intact = try write("rec_1790000000001.aac", frames)
    let killed = try write("rec_1790000000002.aac", frames + frame(120).prefix(50))
    let empty = try write("rec_1790000000003.aac", frame(120).prefix(30))
    let capturing = try write("rec_1790000000004.aac", frames + frame(120).prefix(50))
    let legacyBroken = try write("rec_1790000000005.m4a", Data([0,0,0,0,109,100,97,116,0,0,0,0]))
    let legacyGood = try write("rec_1790000000006.m4a", Data([0,0,0,8,109,111,111,118,0,0,0,8,109,100,97,116]))

    expectEqual(store.pending().count, 6, "both the new and the legacy extension stay queued")
    expectTrue(PendingRecordingStore.isFinalized(at: intact))
    PendingRecordingStore.beginCapture(capturing)
    expectFalse(PendingRecordingStore.isFinalized(at: capturing), "an open capture must never be transferred")

    let salvage = store.salvageUnfinalized()
    expectEqual(salvage.recovered.map(\.lastPathComponent), [killed.lastPathComponent])
    expectEqual(salvage.dropped, 2, "only the frameless ADTS file and the moov-less m4a are unrecoverable")
    expectEqual(size(killed), frames.count, "the partial trailing frame is trimmed, every complete frame kept")
    expectEqual(size(intact), frames.count)
    expectEqual(size(capturing), frames.count + 50, "salvage must not touch the file being written")
    expectFalse(FileManager.default.fileExists(atPath: empty.path))
    expectFalse(FileManager.default.fileExists(atPath: legacyBroken.path))
    expectTrue(FileManager.default.fileExists(atPath: legacyGood.path))
    expectTrue(PendingRecordingStore.isFinalized(at: killed))
    expectEqual(PendingRecordingStore.trimToCompleteADTSFrames(at: killed), .intact, "salvage is idempotent")

    PendingRecordingStore.endCapture(capturing)
    expectEqual(store.salvageUnfinalized().recovered.map(\.lastPathComponent), [capturing.lastPathComponent],
                "after its process is gone, the same file is salvaged like any other")
    expectTrue(WatchReceiptProtocol.validName("rec_1790000000002.aac"))
    expectTrue(WatchReceiptProtocol.validName("rec_1790000000002.m4a"))
    expectFalse(WatchReceiptProtocol.validName("rec_1790000000002.wav"))
    print("PASS: killed ADTS captures are trimmed and kept; open captures are never transferred or trimmed")
}
