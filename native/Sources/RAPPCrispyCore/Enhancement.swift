import Foundation
import CryptoKit
import RAPPDesktopSupport

public struct AdvancedEngineTools: Codable, Equatable, Sendable {
    public var deepFilter: URL?
    public var ffmpeg: URL?
    public var rnnoiseModel: URL?

    public init(deepFilter: URL? = nil, ffmpeg: URL? = nil, rnnoiseModel: URL? = nil) {
        self.deepFilter = deepFilter
        self.ffmpeg = ffmpeg
        self.rnnoiseModel = rnnoiseModel
    }

    public func readiness(for engine: EnhancementEngine) -> String? {
        switch engine {
        case .none, .appleVoiceProcessing: return nil
        case .deepFilterNet:
            guard let deepFilter, FileManager.default.isExecutableFile(atPath: deepFilter.path) else {
                return "DeepFilterNet3 is not bundled in this build. Select a trusted deep-filter executable in Settings, or explicitly choose Apple voice processing."
            }
        case .rnnoise:
            guard let ffmpeg, FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
                return "RNNoise requires a selected ffmpeg executable with the arnndn filter."
            }
            guard let rnnoiseModel, FileManager.default.isReadableFile(atPath: rnnoiseModel.path) else {
                return "RNNoise requires a selected .rnnn model. No substitute engine will be used."
            }
        }
        return nil
    }
}

public struct EnhancedAudio: Sendable {
    public let url: URL
    public let report: EnhancementReport
    public init(url: URL, report: EnhancementReport) {
        self.url = url
        self.report = report
    }
}

public struct AudioEnhancer: Sendable {
    public let tools: AdvancedEngineTools
    public init(tools: AdvancedEngineTools) { self.tools = tools }

    public func enhance(source: URL, selected: EnhancementEngine,
                        captured: EnhancementEngine, directory: URL) async throws -> EnhancedAudio {
        try Task.checkCancellation()
        let info = try AudioFiles.describe(source)
        if let reason = tools.readiness(for: selected) { throw CrispyError.unavailable(reason) }
        switch selected {
        case .none:
            return EnhancedAudio(url: source, report: EnhancementReport(engine: .none,
                implementation: captured == .appleVoiceProcessing
                    ? "Apple voice-processed capture retained; no additional offline enhancement"
                    : "Captured audio retained; no Crispy enhancement requested",
                processedSeconds: nil, audioSeconds: info.duration))
        case .appleVoiceProcessing:
            guard captured == .appleVoiceProcessing else {
                throw CrispyError.unavailable("Apple voice processing is a capture-time engine. It cannot be applied to a stored file; select an available advanced engine instead.")
            }
            return EnhancedAudio(url: source, report: EnhancementReport(engine: selected,
                implementation: "AVAudioEngine voice processing, enabled and verified during capture",
                processedSeconds: nil, audioSeconds: info.duration))
        case .deepFilterNet, .rnnoise: break
        }

        let start = ContinuousClock.now
        let work = directory.appendingPathComponent(".enhancement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let normalized = work.appendingPathComponent("normalized.wav")
        let implementation: String
        let executableDigest: String
        var modelDigest: String?
        if selected == .deepFilterNet {
            guard let tool = tools.deepFilter else { throw CrispyError.unavailable("deep-filter is not configured") }
            let version = try await ProcessRunner.run(executable: tool, arguments: ["--version"], directory: work)
            let identity = (version.stdout + version.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            guard identity.range(of: #"\b0\.5\.6\b"#, options: .regularExpression) != nil else {
                throw CrispyError.unavailable("The native DFN3 adapter supports deep-filter 0.5.6 with its default DFN3 model. This executable reported '\(identity.prefix(160))'; no differently versioned engine was silently substituted. The legacy CLI remains available for other versions.")
            }
            executableDigest = try Self.sha256(tool)
            let input = work.appendingPathComponent("input.wav")
            try await AudioFiles.convertToWAV(source: source, destination: input, sampleRate: 48_000)
            let outputDirectory = work.appendingPathComponent("dfn-output", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
            _ = try await ProcessRunner.run(executable: tool, arguments: ["-o", outputDirectory.path, input.path], directory: work)
            let produced = try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "wav" }
            guard produced.count == 1, let wav = produced.first else {
                throw CrispyError.invalidRecording("deep-filter did not produce exactly one WAV")
            }
            try await AudioFiles.convertToWAV(source: wav, destination: normalized, sampleRate: 48_000)
            implementation = "DeepFilterNet3 file-to-file, deep-filter 0.5.6 default model, no --pf; user-selected executable: \(tool.lastPathComponent)"
        } else {
            guard let ffmpeg = tools.ffmpeg, let model = tools.rnnoiseModel else {
                throw CrispyError.unavailable("ffmpeg and a .rnnn model are required")
            }
            let filters = try await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-filters"], directory: work)
            guard filters.stdout.range(of: #"\barnndn\b"#, options: .regularExpression) != nil else {
                throw CrispyError.unavailable("The selected ffmpeg does not advertise arnndn. RNNoise cannot run; no alternative engine was selected.")
            }
            executableDigest = try Self.sha256(ffmpeg)
            modelDigest = try Self.sha256(model)
            try FileManager.default.copyItem(at: model, to: work.appendingPathComponent("model.rnnn"))
            _ = try await ProcessRunner.run(executable: ffmpeg, arguments: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-i", source.path,
                "-af", "arnndn=m=model.rnnn", "-ar", "48000", "-ac", "1",
                "-c:a", "pcm_s16le", "-n", normalized.path
            ], directory: work)
            implementation = "RNNoise via ffmpeg arnndn; model: \(model.lastPathComponent)"
        }
        try Task.checkCancellation()
        _ = try AudioFiles.describe(normalized)
        let destination = directory.appendingPathComponent("mic.denoised.\(UUID().uuidString.prefix(8)).wav")
        try FileManager.default.moveItem(at: normalized, to: destination)
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return EnhancedAudio(url: destination, report: EnhancementReport(engine: selected,
            implementation: implementation, processedSeconds: seconds, audioSeconds: info.duration,
            executableSHA256: executableDigest, modelSHA256: modelDigest))
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
