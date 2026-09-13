@preconcurrency import AVFoundation
import Foundation

public struct AudioSummary: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: UInt32
    public let frames: Int64
    public var duration: Double { Double(frames) / sampleRate }
}

public enum AudioFiles {
    public static func describe(_ url: URL) throws -> AudioSummary {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.fileFormat.sampleRate > 0, file.fileFormat.channelCount > 0 else {
            throw CrispyError.invalidRecording("no audio frames were captured")
        }
        return AudioSummary(sampleRate: file.fileFormat.sampleRate,
                            channels: file.fileFormat.channelCount, frames: file.length)
    }

    public static func pcmSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    @discardableResult
    public static func convertToWAV(source: URL, destination: URL, sampleRate: Double = 16_000) async throws -> AudioSummary {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw CrispyError.invalidRecording("input and output must differ")
        }
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0 else { throw CrispyError.invalidRecording("empty capture") }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384) else {
            throw CrispyError.invalidRecording("audio format conversion is unavailable")
        }
        converter.downmix = true
        let output = try AVAudioFile(forWriting: destination, settings: pcmSettings(sampleRate: sampleRate),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        var readFailure: Error?
        var emptyPasses = 0
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, inputStatus in
                do {
                    let remaining = input.length - input.framePosition
                    guard remaining > 0 else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    guard requested > 0 else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    try input.read(into: inputBuffer, frameCount: min(requested, inputBuffer.frameCapacity, AVAudioFrameCount(min(remaining, Int64(UInt32.max)))))
                    inputStatus.pointee = inputBuffer.frameLength == 0 ? .endOfStream : .haveData
                    return inputBuffer.frameLength == 0 ? nil : inputBuffer
                } catch {
                    readFailure = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readFailure { throw readFailure }
            if let conversionError { throw conversionError }
            if status == .error { throw CrispyError.invalidRecording("AVAudioConverter failed") }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
                emptyPasses = 0
            } else {
                emptyPasses += 1
            }
            if status == .endOfStream { break }
            guard emptyPasses < 4 else { throw CrispyError.invalidRecording("audio converter stopped making progress") }
        }
        guard output.length > 0 else { throw CrispyError.invalidRecording("conversion produced no audio") }
        return AudioSummary(sampleRate: sampleRate, channels: 1, frames: output.length)
    }

    public static func splitWAV(_ source: URL, into directory: URL, seconds: Double = 300) async throws -> [URL] {
        guard seconds > 0, seconds.isFinite, seconds <= 3600 else {
            throw CrispyError.invalidRecording("chunk duration must be between 0 and 3600 seconds")
        }
        let input = try AVAudioFile(forReading: source)
        guard input.fileFormat.sampleRate == 16_000, input.fileFormat.channelCount == 1,
              input.length > 0 else {
            throw CrispyError.invalidRecording("transcription requires nonempty 16 kHz mono WAV audio")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else {
            throw CrispyError.invalidRecording("could not allocate a chunk buffer")
        }
        let framesPerChunk = max(1, Int64(seconds * 16_000))
        var chunks: [URL] = []
        while input.framePosition < input.length {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(String(format: "c%04d.wav", chunks.count))
            let output = try AVAudioFile(forWriting: url, settings: pcmSettings(sampleRate: 16_000),
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            var remaining = min(framesPerChunk, input.length - input.framePosition)
            while remaining > 0 {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 8192)))
                guard buffer.frameLength > 0 else { throw CrispyError.invalidRecording("unexpected end of audio") }
                try output.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
            }
            chunks.append(url)
        }
        return chunks
    }
}

public enum AudioMetrics {
    public static func rmsDB(_ samples: [Float]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let meanSquare = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return meanSquare > 0 ? 10 * log10(meanSquare) : -.infinity
    }
    public static func noiseReductionDB(inputGapDB: Double, outputGapDB: Double) -> Double {
        inputGapDB - outputGapDB
    }
    public static func speechRetentionDB(inputSpeechDB: Double, outputSpeechDB: Double) -> Double {
        outputSpeechDB - inputSpeechDB
    }
}
