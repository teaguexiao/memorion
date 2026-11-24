import AppIntents
import SwiftUI
import WidgetKit

enum RecordingControlMode { case adaptive, start, stop }

struct RecordingWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var familyOverride: WidgetFamily? = nil
    let state: WatchRecordingControlState
    var mode: RecordingControlMode = .adaptive

    private var title: String { mode == .stop ? "Stop recording" : (mode == .start ? "Start recording" : state.actionTitle) }
    private var symbol: String { mode == .stop ? "stop.circle.fill" : (mode == .start ? "mic.fill" : state.symbol) }
    private var color: Color {
        switch state.phase {
        case .recording: return .red
        case .paused, .interrupted: return .orange
        case .idle: return mode == .stop ? .secondary : .blue
        case .unconfirmed: return .secondary
        }
    }

    var body: some View {
        Group {
            switch familyOverride ?? widgetFamily {
            case .accessoryCircular:
                Image(systemName: symbol).font(.title2).foregroundStyle(color)
                    .widgetAccentable(state.phase == .idle && mode != .stop)
                    .accessibilityLabel(Text(LocalizedStringKey(title)))
            case .accessoryInline:
                Label(LocalizedStringKey(title), systemImage: symbol)
            default:
                if #available(watchOS 11.0, *) {
                    actionButton.handGestureShortcut(.primaryAction)
                } else { content }
            }
        }
        .widgetURL(mode == .stop ? URL(string: "memorion-watch://stop")! : (mode == .start ? URL(string: "memorion-watch://record")! : state.actionURL))
        .containerBackground(.black, for: .widget)
    }

    @ViewBuilder private var actionButton: some View {
        if mode == .stop {
            Button(intent: StopWatchRecordingIntent()) { content }.buttonStyle(.plain)
        } else if mode == .start || state.phase == .idle || state.phase == .interrupted {
            // 进程没了 ⇒ 录音确定停了；点一下直接续录（App 里还留着这次的录音请求）。
            Button(intent: StartWatchRecordingIntent()) { content }.buttonStyle(.plain)
        } else if state.phase == .unconfirmed {
            Button(intent: OpenWatchRecordingIntent()) { content }.buttonStyle(.plain)
        } else {
            Button(intent: StopWatchRecordingFromWidgetIntent(sessionID: state.sessionID ?? "")) { content }
                .buttonStyle(.plain)
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(state.statusTitle)).font(.headline)
                Text(LocalizedStringKey(title)).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
