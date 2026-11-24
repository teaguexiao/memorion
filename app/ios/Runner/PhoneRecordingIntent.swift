import AppIntents
import Flutter
import UIKit

@available(iOS 16.0, *)
struct StartPhoneRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start phone recording"
    static var description = IntentDescription("Open Memorion and start recording with the phone microphone.")
    static var openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PhoneRecordingShortcutBridge.shared.startRecording()
        return .result()
    }
}

/// The implicit Flutter engine is created after launch. Wait for its first
/// rendered frame rather than losing a cold-start request on an unbound channel.
@MainActor
final class PhoneRecordingShortcutBridge {
    static let shared = PhoneRecordingShortcutBridge()
    private var channel: FlutterMethodChannel?
    private var ready = false

    func configure(messenger: FlutterBinaryMessenger) {
        ready = false
        let channel = FlutterMethodChannel(name: "com.memorion.ios/phone_recording", binaryMessenger: messenger)
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "ready":
                self?.ready = true
                result(nil)
            case "notReady":
                self?.ready = false
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    func startRecording() async throws {
        let deadline = Date().addingTimeInterval(30)
        while !ready || channel == nil || UIApplication.shared.applicationState != .active {
            try Task.checkCancellation()
            guard Date() < deadline else { throw PhoneRecordingShortcutError(code: "start_failed") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        guard let channel else { throw PhoneRecordingShortcutError(code: "start_failed") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.invokeMethod("startPhoneRecording", arguments: nil) { result in
                if let error = result as? FlutterError {
                    continuation.resume(throwing: PhoneRecordingShortcutError(code: error.code))
                } else if let started = result as? Bool, started {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhoneRecordingShortcutError(code: "start_failed"))
                }
            }
        }
    }
}

private struct PhoneRecordingShortcutError: LocalizedError {
    let code: String

    var errorDescription: String? {
        switch code {
        case "sign_in_required":
            return String(localized: "Open Memorion and finish signing in and setup before recording.")
        case "microphone_permission":
            return String(localized: "Allow microphone access for Memorion in Settings before recording.")
        case "recording_busy":
            return String(localized: "Finish the current recording before starting phone recording.")
        case "foreground_required":
            return String(localized: "Keep Memorion open to start phone recording.")
        default:
            return String(localized: "Phone recording could not start. Open Memorion and try again.")
        }
    }
}
