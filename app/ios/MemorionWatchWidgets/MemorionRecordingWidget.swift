import AppIntents
import SwiftUI
import WidgetKit

struct RecordingEntry: TimelineEntry {
    let date: Date
    let state: WatchRecordingControlState
}

struct RecordingProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordingEntry {
        RecordingEntry(date: .now, state: WatchRecordingControlState())
    }
    func getSnapshot(in context: Context, completion: @escaping (RecordingEntry) -> Void) {
        completion(RecordingEntry(date: .now, state: WatchRecordingControlStore().read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingEntry>) -> Void) {
        let entry = RecordingEntry(date: .now, state: WatchRecordingControlStore().read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct MemorionRecordingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MemorionRecording", provider: RecordingProvider()) { entry in
            RecordingWidgetView(state: entry.state)
        }
        .configurationDisplayName("Memorion Recording")
        .description("Start or stop recording on your watch.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct MemorionStartRecordingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MemorionStartRecording", provider: RecordingProvider()) { entry in
            RecordingWidgetView(state: entry.state, mode: .start)
        }
        .configurationDisplayName("Memorion Start Recording")
        .description("Tap to start recording on your watch.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct MemorionStopRecordingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MemorionStopRecording", provider: RecordingProvider()) { entry in
            RecordingWidgetView(state: entry.state, mode: .stop)
        }
        .configurationDisplayName("Memorion Stop Recording")
        .description("Stop recording on your watch.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main struct MemorionRecordingWidgets: WidgetBundle {
    var body: some Widget {
        MemorionRecordingWidget()
        MemorionStartRecordingWidget()
        MemorionStopRecordingWidget()
    }
}
