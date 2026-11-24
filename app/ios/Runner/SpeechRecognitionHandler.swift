import Foundation
import Flutter
import Speech
import AVFoundation

class SpeechRecognitionHandler {
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var resultChannel: FlutterMethodChannel?
    private var isStreaming = false
    private var currentSampleRate: Int = 16000

    // Track the last sent text to avoid duplicate callbacks
    private var lastSentText = ""
    // Restart counter for managing the 60s Apple limit
    private var segmentCounter = 0

    func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "transcribe":
            handleTranscribe(call: call, result: result)
        case "startStreaming":
            handleStartStreaming(call: call, result: result)
        case "appendAudio":
            handleAppendAudio(call: call, result: result)
        case "stopStreaming":
            handleStopStreaming(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Set the method channel for sending streaming results back to Flutter
    func setChannel(_ channel: FlutterMethodChannel) {
        self.resultChannel = channel
    }

    // MARK: - Legacy file-based transcription (kept for compatibility)

    private func handleTranscribe(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String,
              let language = args["language"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing filePath or language", details: nil))
            return
        }

        let locale = Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            result(FlutterError(code: "NO_RECOGNIZER", message: "No recognizer for locale: \(language)", details: nil))
            return
        }

        if #available(iOS 13, *) {
            recognizer.supportsOnDeviceRecognition = true
        }

        SFSpeechRecognizer.requestAuthorization { authStatus in
            guard authStatus == .authorized else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NOT_AUTHORIZED", message: "Speech recognition not authorized: \(authStatus.rawValue)", details: nil))
                }
                return
            }

            let fileUrl = URL(fileURLWithPath: filePath)
            let request = SFSpeechURLRecognitionRequest(url: fileUrl)

            if #available(iOS 13, *) {
                request.requiresOnDeviceRecognition = true
            }

            recognizer.recognitionTask(with: request) { recognitionResult, error in
                guard let recognitionResult = recognitionResult else {
                    if let error = error {
                        NSLog("[SpeechRecognition] Error: \(error.localizedDescription)")
                    }
                    DispatchQueue.main.async {
                        result(nil)
                    }
                    return
                }

                if recognitionResult.isFinal {
                    let text = recognitionResult.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        result(text)
                    }
                }
            }
        }
    }

    // MARK: - Streaming recognition

    private func handleStartStreaming(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let language = args["language"] as? String,
              let sampleRate = args["sampleRate"] as? Int else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing language or sampleRate", details: nil))
            return
        }

        if isStreaming {
            stopRecognitionInternal()
        }

        self.currentSampleRate = sampleRate

        let locale = Locale(identifier: language)
        guard let rec = SFSpeechRecognizer(locale: locale) else {
            result(FlutterError(code: "NO_RECOGNIZER", message: "No recognizer for locale: \(language)", details: nil))
            return
        }

        if #available(iOS 13, *) {
            rec.supportsOnDeviceRecognition = true
        }
        self.recognizer = rec

        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            guard let self = self else { return }
            guard authStatus == .authorized else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NOT_AUTHORIZED", message: "Speech recognition not authorized", details: nil))
                }
                return
            }

            self.startRecognitionSession(sampleRate: sampleRate)

            DispatchQueue.main.async {
                result(true)
            }
        }
    }

    private func startRecognitionSession(sampleRate: Int) {
        let request = SFSpeechAudioBufferRecognitionRequest()

        if #available(iOS 13, *) {
            request.requiresOnDeviceRecognition = true
        }
        // Enable partial (interim) results for real-time feedback
        request.shouldReportPartialResults = true

        self.recognitionRequest = request
        self.lastSentText = ""

        guard let rec = self.recognizer else { return }

        self.recognitionTask = rec.recognitionTask(with: request) { [weak self] recognitionResult, error in
            guard let self = self else { return }

            if let recognitionResult = recognitionResult {
                let transcription = recognitionResult.bestTranscription
                let text = transcription.formattedString
                let isFinal = recognitionResult.isFinal

                // Only send if text actually changed
                if text != self.lastSentText {
                    self.lastSentText = text

                    // Extract segment timestamps from the transcription
                    var segStart: Double = 0
                    var segEnd: Double = 0

                    let segments = transcription.segments
                    if let firstSeg = segments.first {
                        segStart = firstSeg.timestamp
                    }
                    if let lastSeg = segments.last {
                        segEnd = lastSeg.timestamp + lastSeg.duration
                    }

                    DispatchQueue.main.async {
                        self.resultChannel?.invokeMethod("onSpeechResult", arguments: [
                            "text": text,
                            "isFinal": isFinal,
                            "segmentStart": segStart,
                            "segmentEnd": segEnd,
                        ])
                    }
                }

                if isFinal {
                    // Apple Speech has a ~60s limit per recognition task.
                    // When we get a final result, restart the session to continue.
                    NSLog("[SpeechRecognition] Final result received, restarting session")
                    self.restartRecognitionSession(sampleRate: sampleRate)
                }
            }

            if let error = error {
                let nsError = error as NSError
                // Error code 216 = "kAFAssistantErrorDomain" recognition cancelled — expected on restart
                // Error code 1110 = no speech detected — not an error for our use case
                if nsError.code != 216 && nsError.code != 1110 {
                    NSLog("[SpeechRecognition] Error: \(error.localizedDescription) (code: \(nsError.code))")
                }
            }
        }

        self.isStreaming = true
        NSLog("[SpeechRecognition] Streaming session started (sampleRate: \(sampleRate))")
    }

    private func restartRecognitionSession(sampleRate: Int) {
        // End the current request so the task finishes cleanly
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        // Slight delay to let the system release resources
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isStreaming else { return }
            self.segmentCounter += 1
            NSLog("[SpeechRecognition] Restarting session (segment #\(self.segmentCounter))")
            self.startRecognitionSession(sampleRate: sampleRate)
        }
    }

    private func handleAppendAudio(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let audioBytes = args["audioData"] as? FlutterStandardTypedData,
              let sampleRate = args["sampleRate"] as? Int else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing audioData or sampleRate", details: nil))
            return
        }

        guard let request = recognitionRequest else {
            // Session not active — silently ignore
            result(nil)
            return
        }

        // Convert raw PCM16 bytes to Float32 AVAudioPCMBuffer for Apple Speech
        let data = audioBytes.data
        let sampleCount = data.count / 2  // 16-bit = 2 bytes per sample

        guard sampleCount > 0 else {
            result(nil)
            return
        }

        // Apple Speech works best with Float32 format
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            result(nil)
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)

        // Convert Int16 PCM to Float32 — Apple Speech requires normalized [-1.0, 1.0] samples
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            result(nil)
            return
        }

        data.withUnsafeBytes { rawBufferPointer in
            let int16Ptr = rawBufferPointer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                floatChannelData[0][i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        request.append(pcmBuffer)
        result(nil)
    }

    private func handleStopStreaming(result: @escaping FlutterResult) {
        stopRecognitionInternal()
        result(true)
    }

    private func stopRecognitionInternal() {
        isStreaming = false
        segmentCounter = 0
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
        lastSentText = ""
        NSLog("[SpeechRecognition] Streaming stopped")
    }
}
