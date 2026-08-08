import Foundation
import AVFoundation

/// Decodes a track's audio and runs `AudioFeatureExtractor` on it — the iOS
/// equivalent of `playlist_mixer.py`'s `get_or_analyze_features`/`analyze_track`.
/// This is what the first-run background scan (`BGContinuedProcessingTask` /
/// `BGProcessingTask`, per CLAUDE.md's "First-Run Library Analysis — UX")
/// calls once per unanalyzed track.
///
/// Compiles clean as of the 2026-08-07 Codemagic build (CLAUDE.md Version
/// History 0.13.6). Still unverified against real audio, though: CI's
/// `swift test` run has no real music files to decode, only the synthetic
/// signals `AudioFeatureExtractorTests` generates in-memory. The
/// `AVAudioConverter` downmix/resample path here is standard but real-world
/// accuracy against actual library tracks — the Python-vs-Swift comparison
/// described in "Audio Analysis Pipeline — iOS DSP Design" — is still
/// outstanding and needs a path that isn't just `swift test` in CI.
public enum TrackAnalyzer {

    /// Matches Phase 1's `analysis_sr` — fast analysis pass, distinct from
    /// the 44.1kHz stereo decode used for the actual mix (see the mixing
    /// engine design).
    public static let analysisSampleRate: Double = 22050

    public enum AnalysisError: Error {
        case couldNotOpenFile
        case couldNotCreateConverter
        case decodeFailed
        case tooShort
    }

    /// - Parameters:
    ///   - url: a local file URL with a usable `assetURL` — the caller is
    ///     responsible for having already excluded DRM-protected tracks
    ///     (`has_raw_audio_access == false`) per the DRM-exclusion UX; this
    ///     function assumes it was handed a real, decodable file.
    ///   - tempoDebugLog: passthrough to `AudioFeatureExtractor.extract` —
    ///     see its doc comment. Defaults to `nil`; no production caller
    ///     should need this.
    public static func analyze(fileAt url: URL, tempoDebugLog: ((String) -> Void)? = nil) throws -> AnalysisFeatures {
        let samples = try decodeMonoSamples(fileAt: url, targetSampleRate: analysisSampleRate)
        guard samples.count >= Int(analysisSampleRate) * 3 else {
            // Mirrors Python's "too short or empty" skip (< 3 seconds).
            throw AnalysisError.tooShort
        }
        return AudioFeatureExtractor.extract(samples: samples, sampleRate: analysisSampleRate, tempoDebugLog: tempoDebugLog)
    }

    /// Also returns duration in seconds, matching the `duration_sec` column —
    /// callers writing a fresh `Track` row need both the features and this.
    public static func duration(ofFileAt url: URL) throws -> Double {
        // Uses the synchronous `duration` property rather than the newer
        // `load(.duration)` async API, to match the rest of this file (and
        // its callers, per the not-yet-written background-scan wiring) being
        // plain synchronous `throws` functions, not `async`.
        let asset = AVURLAsset(url: url)
        return CMTimeGetSeconds(asset.duration)
    }

    /// Decodes `url` to mono Float32 PCM at `targetSampleRate`, using
    /// `AVAudioConverter` for the resample + channel downmix in one step.
    static func decodeMonoSamples(fileAt url: URL, targetSampleRate: Double) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AnalysisError.couldNotOpenFile
        }

        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AnalysisError.couldNotCreateConverter
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AnalysisError.couldNotCreateConverter
        }
        // Let the converter downmix multi-channel sources to mono itself
        // rather than hand-averaging channels — matches librosa's `mono=True`
        // behavior closely enough for analysis purposes.
        converter.downmix = true

        let sourceFrameCount = AVAudioFrameCount(file.length)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
            throw AnalysisError.decodeFailed
        }
        try file.read(into: sourceBuffer)

        let outputCapacity = AVAudioFrameCount(Double(sourceFrameCount) * (targetSampleRate / sourceFormat.sampleRate) + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw AnalysisError.decodeFailed
        }

        var error: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, error == nil, let channelData = outputBuffer.floatChannelData else {
            throw AnalysisError.decodeFailed
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
