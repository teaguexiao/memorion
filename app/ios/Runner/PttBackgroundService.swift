import AVFoundation
import Flutter
import UIKit

/// PTT 后台保活服务
///
/// 背景:BLE Push-to-Talk 的整条链路(按钮事件回调、转发设备音频、维持 Talk API
/// WebSocket、等待转写返回)全部跑在 Flutter/Dart 层。当 app 进入后台后,iOS 会很快
/// 冻结 Dart isolate,导致长按期间收不到音频、WebSocket 被挂起。
///
/// 常规对话录音之所以能后台工作,是因为 FlutterSound 录音会激活一个 AVAudioSession,
/// 配合 Info.plist 里的 `audio` UIBackgroundMode 让 app 持续活跃。PTT 路径只是转发
/// 蓝牙字节,自身从不激活 audio session,因此得不到这份保活。
///
/// 本服务在长按 PTT 期间显式补上这份保活:
///   1. 激活一个 playAndRecord 的 AVAudioSession;
///   2. 用 AVAudioEngine + AVAudioPlayerNode 持续播放一段静音 buffer —— iOS 要求有
///      "真实的音频活动" 才会保住 `audio` background mode,仅 setActive(true) 不够;
///   3. 同时 beginBackgroundTask 兜底,覆盖从 suspended 被 BLE 唤醒后的执行窗口。
/// 松手后 end() 停止引擎并释放,避免长期占用音频焦点 / 耗电。
class PttBackgroundService: NSObject {
    private var channel: FlutterMethodChannel?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var silenceBuffer: AVAudioPCMBuffer?

    private var isActive = false
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    // 用串行队列保护 isActive / engine 的并发访问(MethodChannel 在主线程,
    // 但 AVAudioEngine 的回调可能在其他线程)。
    private let stateQueue = DispatchQueue(label: "me.memorion.ptt.keepalive")

    func setChannel(_ channel: FlutterMethodChannel) {
        self.channel = channel
    }

    func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "begin":
            begin(result: result)
        case "end":
            end(result: result)
        case "isActive":
            stateQueue.sync { result(isActive) }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 保活开始

    private func begin(result: @escaping FlutterResult) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isActive {
                NSLog("[PttKeepAlive] begin: already active, noop")
                DispatchQueue.main.async { result(true) }
                return
            }

            // 兜底:申请后台执行时间。即便音频保活因某些机型策略失效,这个 task 也能
            // 在 app 刚转后台 / 被 BLE 唤醒后争取到一段执行窗口。
            self.beginBackgroundTask()

            do {
                try self.activateAudioSession()
                try self.startSilenceEngine()
                self.isActive = true
                NSLog("[PttKeepAlive] begin: keep-alive active")
                DispatchQueue.main.async { result(true) }
            } catch {
                NSLog("[PttKeepAlive] begin failed: \(error.localizedDescription)")
                self.teardown()
                DispatchQueue.main.async {
                    result(FlutterError(code: "PTT_KEEPALIVE_FAILED",
                                        message: error.localizedDescription,
                                        details: nil))
                }
            }
        }
    }

    // MARK: - 保活结束

    private func end(result: @escaping FlutterResult) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.isActive {
                DispatchQueue.main.async { result(true) }
                return
            }
            self.teardown()
            self.isActive = false
            NSLog("[PttKeepAlive] end: keep-alive released")
            DispatchQueue.main.async { result(true) }
        }
    }

    // MARK: - AVAudioSession

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + allowBluetooth:与现有 AudioInputService 一致,确保不会和
        // 蓝牙 HFP / 录音路由冲突。mixWithOthers 让我们的静音不会打断其他音频。
        try session.setCategory(.playAndRecord,
                                mode: .default,
                                options: [.allowBluetooth, .mixWithOthers, .defaultToSpeaker])
        try session.setActive(true, options: [])
    }

    // MARK: - 静音引擎

    private func startSilenceEngine() throws {
        let format = engine.outputNode.inputFormat(forBus: 0)

        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }

        // 准备一段 ~0.5s 的静音 buffer,循环播放。
        let frameCount = AVAudioFrameCount(format.sampleRate * 0.5)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "PttKeepAlive", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate silence buffer"])
        }
        buffer.frameLength = frameCount // 全零 = 静音
        silenceBuffer = buffer

        engine.prepare()
        try engine.start()
        scheduleSilence()
        player.play()
    }

    private func scheduleSilence() {
        guard let buffer = silenceBuffer else { return }
        // .loops 让 buffer 自动循环,无需反复回调重排。
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    // MARK: - 清理

    private func teardown() {
        if player.isPlaying {
            player.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
        silenceBuffer = nil

        // 释放音频焦点,让系统/其他 app 恢复正常路由。失败不致命。
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            NSLog("[PttKeepAlive] setActive(false) failed: \(error.localizedDescription)")
        }

        endBackgroundTask()
    }

    // MARK: - 后台任务兜底

    private func beginBackgroundTask() {
        endBackgroundTask()
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "PttKeepAlive") { [weak self] in
            // 系统即将回收时被调用 —— 主动结束,避免被强杀。该过期回调由 iOS 在
            // 任意线程触发,而 bgTaskId 同时被 stateQueue 上的 teardown() 访问,
            // 故统一派发到 stateQueue,避免对 bgTaskId 的数据竞争。
            self?.stateQueue.async {
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }
}
