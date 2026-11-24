#if targetEnvironment(simulator)
import AVFoundation
import Foundation

/// 模拟器专用：不经过麦克风，直接造一条待同步录音。
///
/// **为什么需要它。** watchOS 模拟器**不透传 Mac 的麦克风**（iOS 模拟器会），所以在模拟器里
/// 点「开始录音」只会得到一个空文件。而这条链路上真正容易接错的部分恰恰不在麦克风：
/// `transferFile` → iPhone 收件箱 → 搬出 inbox → MethodChannel → Flutter →
/// `upload-audio`（含 `started_at` 一路带过来）。这几跳在模拟器里是**真的**（两台模拟器
/// 会配对，WatchConnectivity 正常工作），只有采音不是。
///
/// 所以这里把「采音」这一跳换成一个文件，让其余六跳可以在模拟器上验证。
///
/// ## 两种 fixture，判据不同 —— 别混
///
/// 1. **用户自己放进去的真人声 m4a**（优先）：
///    ```sh
///    xcrun simctl get_app_container <watch-udid> me.memorion.api.watchkitapp data
///    # 把 xxx.m4a 拷进 <container>/Documents/fixtures/
///    ```
///    判据是后端真出一条对话、transcript 非空、`started_at` 等于注入时刻。
///
/// 2. **合成音（回退）**：一段调制正弦波。它**必然被后端 VAD 判成无语音**，返回
///    `400 no detectable speech`。⚠️ **这个 400 就是它的通过判据**，因为它证明了文件真的
///    走完了七跳、鉴权和路由都对。把它当失败去查是浪费时间；反过来，拿合成音得到 200
///    才是真出了问题。
///
/// 刻意**不往仓库里塞一段真人语音**：手上唯一现成的样本是真实用户的声纹素材，
/// 把它编进 App bundle 等于把用户录音发布出去。
enum WatchSimulatorFixture {
    /// 找一条可注入的音频。优先用户放进 `Documents/fixtures/` 的真人声，否则合成。
    /// 返回实际写出的文件；nil 表示连合成都失败了（不该发生）。
    ///
    /// ⚠️ 真人声 fixture 沿用它自己的扩展名：把 m4a 拷成 `.aac` 名字，容器和扩展名对不上，
    /// `isFinalized` 会按 ADTS 去判而拒绝它。
    static func makeFile(at destination: URL) -> URL? {
        if let real = firstDroppedFixture() {
            let target = destination.deletingPathExtension().appendingPathExtension(real.pathExtension.lowercased())
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: real, to: target)
                NSLog("[Fixture] using dropped fixture \(real.lastPathComponent)")
                return target
            } catch {
                NSLog("[Fixture] copy failed: \(error.localizedDescription)")
            }
        }
        return synthesize(to: destination) ? destination : nil
    }

    /// 描述这次用的是哪种 fixture，UI 直接显示 —— 否则「模拟器上得到 400」会看起来
    /// 像个 bug。
    /// 这里刻意只有英文：整个 fixture 通道是 `#if targetEnvironment(simulator)`，
    /// 只有开发者会看到，不需要走 `WatchText`。
    static var kind: String {
        firstDroppedFixture() != nil ? "dropped fixture (real speech)"
                                     : "synthetic tone (backend will say no speech — expected)"
    }

    private static func firstDroppedFixture() -> URL? {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("fixtures", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // 只认手表队列认的容器（`PendingRecordingStore.acceptedExtensions`）。wav 拷进去
        // `pending()` 列不到，注入会静默什么都不做。
        return urls.filter { PendingRecordingStore.acceptedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// 12 秒调制正弦波，编码参数与真实录音完全一致（16kHz / AAC 32kbps / 单声道），
    /// 这样格式相关的问题在模拟器上也能暴露出来。时长取 12s 是为了越过后端 5s 下限 ——
    /// 否则会先被时长校验拦下，根本走不到 VAD，也就验不到后面几跳。
    private static func synthesize(to destination: URL) -> Bool {
        let sampleRate = 16000.0
        let seconds = 12.0

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return false }

        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = frames

        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            // 载波在 220Hz 上下摆动，避免是一条纯直流似的单音。
            let carrier = 220.0 + 60.0 * sin(2 * .pi * 0.7 * t)
            channel[i] = Float(0.25 * sin(2 * .pi * carrier * t))
        }

        do {
            try? FileManager.default.removeItem(at: destination)
            let file = try AVAudioFile(forWriting: destination, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,
            ])
            try file.write(from: buffer)
            NSLog("[Fixture] synthesized \(Int(seconds))s tone at \(destination.lastPathComponent)")
            return true
        } catch {
            NSLog("[Fixture] synthesize failed: \(error.localizedDescription)")
            return false
        }
    }
}
#endif
