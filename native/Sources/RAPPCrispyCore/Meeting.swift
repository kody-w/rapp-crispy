import Foundation

public enum CrispyVersion {
    public static let current = "1.5.1"
    public static let bundleID = "io.rapp.crispy"
}

public enum EnhancementEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleVoiceProcessing
    case none
    case deepFilterNet
    case rnnoise

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .appleVoiceProcessing: return "Apple voice processing (during capture)"
        case .none: return "Original microphone — no enhancement"
        case .deepFilterNet: return "DeepFilterNet3 (advanced, after capture)"
        case .rnnoise: return "RNNoise (advanced, after capture)"
        }
    }
    public var explanation: String {
        switch self {
        case .appleVoiceProcessing:
            return "AVFoundation voice processing runs locally while recording. This is NOT DeepFilterNet or RNNoise, and the CLI benchmark numbers do not apply. An unprocessed original is not available in this mode."
        case .none:
            return "Records the selected microphone without requesting an enhancement algorithm. A virtual input may already be processed by its owning application."
        case .deepFilterNet:
            return "Runs the existing DeepFilterNet3 file-to-file algorithm, without its rejected --pf post-filter. Requires a separately selected or bundled deep-filter executable."
        case .rnnoise:
            return "Runs the existing ffmpeg arnndn algorithm with your selected .rnnn model. Requires a compatible ffmpeg executable and model. Neither advanced engine reliably removes other voices."
        }
    }
}

public enum MeetingPhase: String, Codable, Sendable, CaseIterable {
    case preparing, recording, stopping, enhancing, transcribing, writingNotes
    case recorded, completed, cancelled, failed, interrupted, legacy

    public var isWorking: Bool {
        switch self {
        case .preparing, .recording, .stopping, .enhancing, .transcribing, .writingNotes: return true
        default: return false
        }
    }
}

public enum NotesState: String, Codable, Sendable {
    case disabled, needsConsent, pending, completed, failed, cancelled
}

public struct EnhancementReport: Codable, Equatable, Sendable {
    public var engine: EnhancementEngine
    public var implementation: String
    public var processedSeconds: Double?
    public var audioSeconds: Double
    public var executableSHA256: String?
    public var modelSHA256: String?
    public var realTimeFactor: Double? {
        guard let processedSeconds, audioSeconds > 0 else { return nil }
        return processedSeconds / audioSeconds
    }

    public init(engine: EnhancementEngine, implementation: String,
                processedSeconds: Double?, audioSeconds: Double,
                executableSHA256: String? = nil, modelSHA256: String? = nil) {
        self.engine = engine
        self.implementation = implementation
        self.processedSeconds = processedSeconds
        self.audioSeconds = audioSeconds
        self.executableSHA256 = executableSHA256
        self.modelSHA256 = modelSHA256
    }
}

public struct Meeting: Identifiable, Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var title: String
    public var createdAt: Date
    public var phase: MeetingPhase
    public var engine: EnhancementEngine
    public var captureEngine: EnhancementEngine?
    public var captureWarnings: [String]?
    public var deviceName: String?
    public var audioFilename: String?
    public var enhancedAudioFilename: String?
    public var duration: Double?
    public var screenLabel: String?
    public var screenFilename: String?
    public var speechModelID: String?
    public var hasTranscript = false
    public var notesState: NotesState = .disabled
    public var message: String?
    public var enhancement: EnhancementReport?

    public init(id: String, title: String, createdAt: Date = Date(),
                phase: MeetingPhase = .preparing, engine: EnhancementEngine = .none) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.phase = phase
        self.engine = engine
    }

    public var preferredAudioFilename: String? { enhancedAudioFilename ?? audioFilename }
}

public struct MeetingListing: Sendable {
    public let meetings: [Meeting]
    public let issues: [String]
}

public enum CrispyError: LocalizedError, Equatable {
    case invalidMeetingID
    case unsafePath(String)
    case invalidRecording(String)
    case unavailable(String)
    case noActiveRecording
    case busy
    case invalidCommand(String)
    case noTranscript
    case emptyNotes

    public var errorDescription: String? {
        switch self {
        case .invalidMeetingID: return "The meeting identifier is invalid."
        case .unsafePath(let path): return "Refusing a path outside this meeting or a symbolic link: \(path)"
        case .invalidRecording(let reason): return "The recording is not usable: \(reason)"
        case .unavailable(let reason): return reason
        case .noActiveRecording: return "There is no active recording to stop."
        case .busy: return "Finish or cancel the current job first."
        case .invalidCommand(let reason): return "Unsupported native command: \(reason)"
        case .noTranscript: return "This meeting has no speech transcript to summarize."
        case .emptyNotes: return "The provider returned no notes. No notes file was written."
        }
    }
}
