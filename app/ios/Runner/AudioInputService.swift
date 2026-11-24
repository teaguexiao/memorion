import AVFoundation
import Flutter

/// 音频输入设备管理服务
/// 通过 MethodChannel 向 Flutter 提供 iOS 音频输入设备列表、切换和监听功能
class AudioInputService: NSObject {
    private var channel: FlutterMethodChannel?
    private var sessionActivated = false
    private var isQuerying = false  // 防止查询触发路由通知的循环

    func setChannel(_ channel: FlutterMethodChannel) {
        self.channel = channel
        // 监听音频路由变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getAvailableInputs":
            result(getAvailableInputs())
        case "setPreferredInput":
            if let args = call.arguments as? [String: Any],
               let portId = args["id"] as? String {
                setPreferredInput(portId: portId, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'id' argument", details: nil))
            }
        case "getCurrentInput":
            result(getCurrentInput())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 获取可用输入设备列表

    private func getAvailableInputs() -> [[String: Any]] {
        let session = AVAudioSession.sharedInstance()

        // 只在首次调用时激活 session，避免每次查询都触发路由变化通知
        if !sessionActivated {
            do {
                // allowBluetooth: 允许 HFP（蓝牙耳机麦克风）
                // defaultToSpeaker: 没有外设时用扬声器输出
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
                try session.setActive(true)
                sessionActivated = true
            } catch {
                NSLog("AudioInputService: Failed to activate session: \(error)")
            }
        }

        guard let inputs = session.availableInputs else { return [] }

        return inputs.map { port in
            return [
                "id": port.uid,
                "name": port.portName,
                "type": mapPortType(port.portType),
                "isConnected": true, // availableInputs 只包含已连接设备
                "portType": port.portType.rawValue, // 传原始类型供 debug
            ]
        }
    }

    // MARK: - 设置首选输入设备

    private func setPreferredInput(portId: String, result: @escaping FlutterResult) {
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs else {
            result(FlutterError(code: "NO_INPUTS", message: "No available inputs", details: nil))
            return
        }

        guard let targetPort = inputs.first(where: { $0.uid == portId }) else {
            result(FlutterError(code: "NOT_FOUND", message: "Input device not found: \(portId)", details: nil))
            return
        }

        do {
            // 蓝牙 HFP 设备需要重新配置 category 确保蓝牙 SCO 链路激活
            // 每次切换都重新 setCategory，因为 flutter_sound 的 startRecorder 可能会覆盖
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setPreferredInput(targetPort)
            // 强制覆盖当前输出路由，确保立即生效
            try session.overrideOutputAudioPort(.none)

            NSLog("AudioInputService: setPreferredInput OK → \(targetPort.portName) (\(targetPort.portType.rawValue))")
            NSLog("AudioInputService: current route inputs = \(session.currentRoute.inputs.map { $0.portName })")
            result(true)
        } catch {
            NSLog("AudioInputService: setPreferredInput FAILED: \(error)")
            result(FlutterError(code: "SET_FAILED", message: "Failed to set preferred input: \(error.localizedDescription)", details: nil))
        }
    }

    // MARK: - 获取当前输入设备

    private func getCurrentInput() -> [String: Any]? {
        let session = AVAudioSession.sharedInstance()
        guard let input = session.currentRoute.inputs.first else { return nil }

        return [
            "id": input.uid,
            "name": input.portName,
            "type": mapPortType(input.portType),
            "isConnected": true,
        ]
    }

    // MARK: - 音频路由变化通知

    @objc private func handleRouteChange(notification: Notification) {
        // 如果正在查询设备列表，忽略此通知（防止循环）
        if isQuerying { return }

        // 路由变化时通知 Flutter 刷新设备列表
        isQuerying = true
        let inputs = getAvailableInputs()
        let current = getCurrentInput()
        isQuerying = false

        channel?.invokeMethod("onRouteChange", arguments: [
            "availableInputs": inputs,
            "currentInput": current as Any,
        ])
    }

    // MARK: - 端口类型映射

    private func mapPortType(_ portType: AVAudioSession.Port) -> String {
        switch portType {
        case .builtInMic:
            return "phone"
        case .bluetoothHFP, .bluetoothLE:
            return "bluetooth"
        case .headsetMic, .headphones:
            return "headphones"
        case .usbAudio:
            return "external"
        default:
            return "external"
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
