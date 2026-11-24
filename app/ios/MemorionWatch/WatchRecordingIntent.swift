import AppIntents

@available(iOS 16.0, watchOS 9.0, *)
struct StartWatchRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start recording"
    static var description = IntentDescription("Open Memorion on your watch and start recording.")
    static var openAppWhenRun = true

    @available(iOS 26.0, watchOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
#if os(watchOS) && !MEMORION_WATCH_WIDGET_EXTENSION
        // Foreground the containing app before starting its microphone. The
        // recorder also defers activation if the scene is still becoming active.
        try await WatchRecorder.shared.startFromShortcut()
#elseif os(iOS)
        // Publish the same action on iPhone for shortcut creation. Recording
        // must execute locally on Watch; a phone cannot activate its microphone.
        throw WatchShortcutRequiresWatch()
#endif
        return .result()
    }
}

@available(iOS 16.0, watchOS 9.0, *)
struct StopWatchRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop recording"
    static var description = IntentDescription("Open Memorion on your watch and stop recording.")
    static var openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor func perform() async throws -> some IntentResult {
#if os(watchOS) && !MEMORION_WATCH_WIDGET_EXTENSION
        WatchRecorder.shared.stopFromShortcut()
#elseif os(iOS)
        throw WatchShortcutRequiresWatch()
#endif
        return .result()
    }
}

/// The session-bound action is only used by rendered widgets, not user shortcuts.
@available(iOS 16.0, watchOS 9.0, *)
struct StopWatchRecordingFromWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop recording"
    static var isDiscoverable = false
    static var openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
    @Parameter(title: "Recording") var sessionID: String
    init() { self.sessionID = "" }
    init(sessionID: String) { self.sessionID = sessionID }

    @MainActor func perform() async throws -> some IntentResult {
#if os(watchOS) && !MEMORION_WATCH_WIDGET_EXTENSION
        WatchRecorder.shared.stopFromQuickEntry(sessionID: sessionID)
#elseif os(iOS)
        throw WatchShortcutRequiresWatch()
#endif
        return .result()
    }
}

@available(iOS 16.0, watchOS 9.0, *)
struct OpenWatchRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Open to check"
    static var isDiscoverable = false
    static var openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
    @MainActor func perform() async throws -> some IntentResult {
#if os(watchOS) && !MEMORION_WATCH_WIDGET_EXTENSION
        WatchRecorder.shared.showFromQuickEntry()
#elseif os(iOS)
        throw WatchShortcutRequiresWatch()
#endif
        return .result()
    }
}

#if !MEMORION_WATCH_WIDGET_EXTENSION
@available(iOS 16.0, watchOS 9.0, *)
struct MemorionWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
#if os(iOS)
        AppShortcut(intent: StartPhoneRecordingIntent(),
                    phrases: ["Start phone recording with \(.applicationName)"],
                    shortTitle: "Start phone recording", systemImageName: "iphone")
#endif
        AppShortcut(intent: StartWatchRecordingIntent(),
                    phrases: ["Start recording with \(.applicationName)"],
                    shortTitle: "Record", systemImageName: "mic.fill")
        AppShortcut(intent: StopWatchRecordingIntent(),
                    phrases: ["Stop recording with \(.applicationName)"],
                    shortTitle: "Stop", systemImageName: "stop.fill")
    }
}

#endif

#if os(iOS)
private struct WatchShortcutRequiresWatch: LocalizedError {
    var errorDescription: String? {
        String(localized: "Run this shortcut on your Apple Watch. Enable Show on Apple Watch in the shortcut details.")
    }
}
#endif
