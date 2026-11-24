import SwiftUI

private enum WatchDestination: Hashable { case moments, queue, moment(String) }
private let watchBlue = Color(red: 84/255, green: 164/255, blue: 253/255)
private let watchSurface = Color(red: 28/255, green: 28/255, blue: 30/255)

struct RecorderView: View {
    @ObservedObject var recorder: WatchRecorder
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var path: [WatchDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    if recorder.recordingRequested { recordingControls } else { idleControls }
                    if let notice = recorder.notice {
                        Text(notice).font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    NavigationLink(value: WatchDestination.moments) {
                        Label(WatchText.pick(en: "My moments", zh: "我的时刻"), systemImage: "star.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    NavigationLink(value: WatchDestination.queue) {
                        HStack {
                            Text(WatchText.pick(en: "Recording queue", zh: "录音队列"))
                            Spacer()
                            Text("\(recorder.pending.count)").foregroundStyle(.secondary)
                        }.font(.caption)
                    }.buttonStyle(.plain)
                    versionFooter
#if targetEnvironment(simulator)
                    if ProcessInfo.processInfo.environment["MEMORION_SCREENSHOT"] != "1" {
                        Button("Inject test audio") { recorder.injectFixture() }.font(.caption2)
                    }
#endif
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle("Memorion")
            .toolbarTitleDisplayMode(.inline)
            .navigationDestination(for: WatchDestination.self) { destination in
                switch destination {
                case .moments: WatchMomentsView(recorder: recorder)
                case .queue: WatchQueueView(recorder: recorder)
                case .moment(let id): WatchMomentDetail(recorder: recorder, momentID: id)
                }
            }
            .onChange(of: recorder.quickEntryGeneration) { _, _ in path = [] }
            .onOpenURL { url in
                guard url.scheme == "memorion-watch" else { return }
                path = []
                recorder.handleQuickEntryURL(url)
            }
        }
        .tint(watchBlue)
#if targetEnvironment(simulator)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("memorion.simulator.navigate"))) { event in
            guard ProcessInfo.processInfo.environment["MEMORION_SIM_FLOW"] == "recording" else { return }
            switch event.userInfo?["route"] as? String {
            case "moments": path = [.moments]
            case "detail":
                if let mark = recorder.moments.first { path = [.moments, .moment(mark.id)] }
            case "queue": path = [.queue]
            default: path = []
            }
        }
        .onChange(of: path) { _, route in
            switch route.last {
            case .moments: recorder.simulatorRoute = "moments"
            case .queue: recorder.simulatorRoute = "queue"
            case .moment: recorder.simulatorRoute = "detail"
            case nil: recorder.simulatorRoute = "root"
            }
        }
#endif
    }

    private var idleControls: some View {
        VStack(spacing: 8) {
            Button(action: recorder.startRecording) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(watchBlue)
                    .frame(width: 86, height: 86)
                    .background(watchBlue.opacity(0.12), in: Circle())
                    .overlay(Circle().stroke(watchBlue.opacity(0.35), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .recordingGesture()
            .accessibilityLabel(WatchText.pick(en: "Start recording", zh: "开始录音"))
            Text(WatchText.pick(en: "Start recording", zh: "开始录音"))
                .font(.headline)
            Text(WatchText.pick(en: "Today · \(recorder.todayReadyCount) moments", zh: "今日 · \(recorder.todayReadyCount) 个时刻"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var recordingControls: some View {
        VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 0 : 10) {
            HStack(spacing: 6) {
                Circle().fill(recorder.isRecording ? .red : .orange).frame(width: 7, height: 7)
                Text(WatchFormat.elapsed(recorder.elapsed))
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    // Keep the timer compact enough for the actions on a small Watch.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .minimumScaleFactor(0.75)
            }
            Text(recorder.recordingStatusText)
                .font(.caption2).foregroundStyle(recorder.isRecording ? watchBlue : .orange)
                .lineLimit(1).minimumScaleFactor(0.75)
            HStack(spacing: 18) {
                if recorder.isRecording {
                    Button(action: recorder.markMoment) {
                        VStack(spacing: 3) {
                            Image(systemName: "star.fill").font(.system(size: 26)).foregroundStyle(.yellow)
                                .frame(width: 48, height: 48).background(.yellow.opacity(0.12), in: Circle())
                            Text(WatchText.pick(en: "Mark", zh: "标记")).font(.caption2).foregroundStyle(.yellow)
                                .lineLimit(1).minimumScaleFactor(0.5)
                        }
                        .frame(width: 48)
                    }
                    .buttonStyle(.plain).recordingGesture()
                    .accessibilityLabel(WatchText.pick(en: "Mark this moment", zh: "标记此刻"))
                } else {
                    Button(action: recorder.startRecording) {
                        VStack(spacing: 3) {
                            Image(systemName: "mic.fill").font(.system(size: 26))
                                .frame(width: 48, height: 48)
                                .background(watchBlue.opacity(0.12), in: Circle())
                            Text(WatchText.pick(en: "Resume", zh: "继续")).font(.caption2)
                                .lineLimit(1).minimumScaleFactor(0.5)
                        }.frame(width: 48)
                    }.buttonStyle(.plain).recordingGesture()
                        .accessibilityLabel(WatchText.pick(en: "Resume recording", zh: "继续录音"))
                }
                Button(action: recorder.stopRecording) {
                    VStack(spacing: 3) {
                        Image(systemName: "stop.fill").font(.system(size: 26)).foregroundStyle(watchBlue)
                            .frame(width: 58, height: 58)
                            .overlay(Circle().stroke(watchBlue, lineWidth: 1.5))
                        Text(WatchText.pick(en: "Stop", zh: "停止")).font(.caption2).foregroundStyle(watchBlue)
                            .lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .frame(width: 58)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(WatchText.pick(en: "Stop recording", zh: "停止录音"))
            }
            Text(WatchText.pick(en: "\(recorder.markCount) marked · processed after sync", zh: "已标记 \(recorder.markCount) 处 · 同步后生成时刻"))
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var versionFooter: some View {
        Text("v\(Bundle.main.infoDictionary?["MemorionWatchVersion"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
            .font(.caption2).foregroundStyle(.tertiary)
    }
}

private struct WatchMomentsView: View {
    @ObservedObject var recorder: WatchRecorder
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                RecordingBanner(recorder: recorder)
                if recorder.moments.isEmpty {
                    Text(WatchText.pick(en: "Mark while recording. Your words appear here after your iPhone processes the audio.", zh: "录音时点一下标记。iPhone 处理音频后，原话会出现在这里。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(recorder.moments) { moment in
                    NavigationLink(value: WatchDestination.moment(moment.id)) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(WatchFormat.date(moment.date)).font(.caption2).foregroundStyle(.secondary)
                            Text(moment.isReady ? moment.text! : WatchText.pick(en: "Marked moment", zh: "已标记的时刻"))
                                .font(.headline).lineLimit(2)
                            if !moment.isReady { Text(WatchFormat.status(moment.status)).font(.caption2).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(watchSurface, in: RoundedRectangle(cornerRadius: 17))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 6)
        }.navigationTitle(WatchText.pick(en: "My moments", zh: "我的时刻"))
    }
}

private struct WatchMomentDetail: View {
    @ObservedObject var recorder: WatchRecorder
    let momentID: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                RecordingBanner(recorder: recorder)
                if let moment = recorder.moments.first(where: { $0.id == momentID }) {
                    Text(WatchFormat.date(moment.date)).font(.caption).foregroundStyle(.secondary)
                    if moment.isReady {
                        Text("“\(moment.text!)”").font(.body)
                        Button(WatchText.pick(en: "View on iPhone", zh: "在 iPhone 查看")) { recorder.openOnPhone(moment) }
                            .buttonStyle(.bordered)
                    } else {
                        Text(WatchFormat.status(moment.status)).font(.body)
                        Text(WatchText.pick(en: "The timestamp is saved. No text is generated before the audio is processed.", zh: "时间点已保存。音频处理完成后才会生成可回看的内容。"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let notice = recorder.notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
                }
            }.padding(.horizontal, 8)
        }.navigationTitle(WatchText.pick(en: "Moment", zh: "时刻"))
    }
}

private struct WatchQueueView: View {
    @ObservedObject var recorder: WatchRecorder
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                RecordingBanner(recorder: recorder)
                Text(WatchText.pick(en: "\(recorder.pending.count) saved on watch", zh: "手表已保存 \(recorder.pending.count) 段"))
                    .font(.headline)
                if recorder.pending.isEmpty {
                    Text(WatchText.pick(en: "No audio waiting on your watch. Received recordings may still be processing on iPhone.", zh: "手表没有待传录音。手机收到的录音可能仍在处理中。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(WatchText.pick(en: "\(recorder.inFlightCount) queued · waiting for iPhone receipt", zh: "\(recorder.inFlightCount) 段已入队 · 等待手机回执"))
                        .font(.caption2).foregroundStyle(.secondary)
                    if !recorder.companionReachable {
                        Text(WatchText.pick(en: "iPhone unavailable now. Delivery will retry automatically.", zh: "iPhone 暂不可达，系统会自动补传。"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(recorder.pending) { audio in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(WatchFormat.date(audio.startedAt)).font(.headline)
                            Text(recorder.queueStatus(for: audio)).font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(watchSurface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button(WatchText.pick(en: "Retry sync", zh: "重试同步")) { recorder.retryPending() }
                    Text(WatchText.pick(en: "Watch originals are kept until the iPhone confirms saving them.", zh: "手机确认保存前，手表会保留原件。"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 6)
        }.navigationTitle(WatchText.pick(en: "Recording queue", zh: "录音队列"))
    }
}

private struct RecordingBanner: View {
    @ObservedObject var recorder: WatchRecorder
    var body: some View {
        if recorder.recordingRequested {
            HStack {
                Image(systemName: recorder.isRecording ? "waveform" : "pause.fill")
                Text(WatchFormat.elapsed(recorder.elapsed)).monospacedDigit()
                Spacer()
                Button(action: recorder.stopRecording) { Image(systemName: "stop.fill").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel(WatchText.pick(en: "Stop recording", zh: "停止录音"))
            }.font(.caption).foregroundStyle(recorder.isRecording ? watchBlue : .orange)
            .accessibilityElement(children: .contain)
        }
    }
}

private extension View {
    @ViewBuilder func recordingGesture() -> some View {
        if #available(watchOS 11.0, *) { self.handGestureShortcut(.primaryAction) }
        else { self }
    }
}

private enum WatchFormat {
    static func elapsed(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t/3600, t/60%60, t%60) : String(format: "%02d:%02d", t/60, t%60)
    }
    static func date(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: value)
    }
    static func status(_ state: String) -> String {
        switch state {
        case "ready": return WatchText.pick(en: "Ready", zh: "可回看")
        case "processing": return WatchText.pick(en: "iPhone received · processing", zh: "手机已收到 · 处理中")
        case "waitingForUpload": return WatchText.pick(en: "iPhone received · awaiting upload", zh: "手机已收到 · 待上传")
        case "audioUnavailable": return WatchText.pick(en: "Recording ended unexpectedly · audio could not be recovered", zh: "录音意外结束 · 音频未能恢复")
        case "failed": return WatchText.pick(en: "Could not process · check on iPhone", zh: "未能处理 · 请在手机查看")
        case "noSpeech": return WatchText.pick(en: "No recognized speech near this mark", zh: "此标记附近未识别到原话")
        default: return WatchText.pick(en: "Timestamp saved · waiting for iPhone", zh: "时间点已保存 · 等待手机接收")
        }
    }
}
