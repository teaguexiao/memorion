import Foundation
import Darwin

@main struct ControlStateTests {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--crash-owner" {
            let store = WatchRecordingControlStore(container: URL(fileURLWithPath: CommandLine.arguments[2]))
            _ = try store.publish(WatchRecordingControlState(phase: .recording, sessionID: "one"))
            _exit(0)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = WatchRecordingControlStore(container: root)
        precondition(reader.read().phase == .idle)
        var owner: WatchRecordingControlStore? = WatchRecordingControlStore(container: root)
        let capturing = WatchRecordingControlState(phase: .recording, sessionID: "one")
        let first = try owner!.publish(capturing)
        precondition(first)
        precondition(reader.read() == capturing)
        let repeated = try owner!.publish(capturing)
        precondition(!repeated)
        precondition(capturing.actionURL.host == "stop")
        precondition(URLComponents(url: capturing.actionURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "one")
        _ = try owner!.publish(WatchRecordingControlState(phase: .paused, sessionID: "one"))
        precondition(reader.read().phase == .paused)
        owner = nil
        // Lease released ⇒ capture definitely stopped; the widget offers resume, not "?".
        precondition(reader.read().phase == .interrupted)
        precondition(reader.read().actionURL.host == "record")
        precondition(reader.read().symbol != WatchRecordingControlState(phase: .unconfirmed).symbol)
        owner = WatchRecordingControlStore(container: root)
        _ = try owner!.publish(WatchRecordingControlState())
        precondition(reader.read().phase == .idle)
        owner = nil

        // A real child owns the lease and terminates without Swift cleanup.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--crash-owner", root.path]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationStatus == 0)
        precondition(reader.read().phase == .interrupted)
        try Data("broken".utf8).write(to: root.appendingPathComponent("recording-control.json"), options: .atomic)
        precondition(reader.read().phase == .unconfirmed)
        precondition(WatchRecordingControlStore(container: nil).read().phase == .unconfirmed)
        // Only a real activation failure published by a live owner stays "open to check".
        owner = WatchRecordingControlStore(container: root)
        _ = try owner!.publish(WatchRecordingControlState(phase: .unconfirmed, sessionID: "one"))
        precondition(reader.read().phase == .unconfirmed)
        precondition(reader.read().actionURL.host == "open")
        owner = nil
        print("PASS: shared control state, stop routing, unchanged publication, lease exit ⇒ interrupted, crashed owner ⇒ interrupted, corrupt state and live failure ⇒ unconfirmed")
    }
}
