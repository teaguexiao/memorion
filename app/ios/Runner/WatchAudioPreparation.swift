import AVFoundation
import Foundation

/// Split a long background capture on iPhone, where exporting never interrupts the Watch mic.
/// Originals stay intact until every clip and its metadata have been published durably.
enum WatchAudioPreparation {
    static func withFileLock<T>(_ lock: NSRecursiveLock?, _ operation: () throws -> T) rethrows -> T {
        lock?.lock()
        defer { lock?.unlock() }
        return try operation()
    }
    static func splitIfNeeded(_ audio: URL, maxDuration: Double = 8 * 3600,
                              chunkDuration: Double = 2 * 3600, fileLock: NSRecursiveLock? = nil) async throws -> [URL]? {
        guard let file = try? AVAudioFile(forReading: audio), file.processingFormat.sampleRate > 0 else { return nil }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > maxDuration else { return nil }
        guard let startedAt = WatchSessionService.startedAtFromFilename(audio) else {
            throw NSError(domain: "WatchAudioPreparation", code: 1)
        }
        let metadata = WatchRecordingMetadata.load(for: audio)
        let asset = AVURLAsset(url: audio)
        var clips: [URL] = []
        var offset = 0.0
        while offset < duration {
            var length = min(chunkDuration, duration - offset)
            if duration - offset - length < 1 { length = duration - offset }
            let millis = Int64(((startedAt.timeIntervalSince1970 + offset) * 1000).rounded())
            let destination = audio.deletingLastPathComponent().appendingPathComponent("rec_\(millis).m4a")
            // The first clip's timestamp is the original timestamp, so use a stable WAV-free suffix.
            let clip = destination == audio
                ? audio.deletingLastPathComponent().appendingPathComponent("rec_\(millis)_part.m4a") : destination
            if !FileManager.default.fileExists(atPath: clip.path) {
                let temporary = audio.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw NSError(domain: "WatchAudioPreparation", code: 2)
                }
                exporter.outputURL = temporary
                exporter.outputFileType = .m4a
                exporter.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 16000),
                                                duration: CMTime(seconds: length, preferredTimescale: 16000))
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    exporter.exportAsynchronously { continuation.resume() }
                }
                guard exporter.status == .completed else {
                    throw exporter.error ?? NSError(domain: "WatchAudioPreparation", code: 3)
                }
                try withFileLock(fileLock) {
                    if FileManager.default.fileExists(atPath: clip.path) { return }
                    if let metadata { try metadata.slice(offset: offset, duration: length).save(for: clip) }
                    do { try FileManager.default.moveItem(at: temporary, to: clip) }
                    catch {
                        try? FileManager.default.removeItem(at: WatchRecordingMetadata.sidecarURL(for: clip))
                        throw error
                    }
                }
            }
            clips.append(clip)
            offset += length
        }
        return clips
    }
}
