import Combine
import Foundation

public struct CaptureSettings: Sendable {
    public var deviceID: UInt32?
    public var engine: EnhancementEngine
    public var screenSelectionID: String?
    public var maximumDuration: Double?

    public init(deviceID: UInt32? = nil, engine: EnhancementEngine = .appleVoiceProcessing,
                screenSelectionID: String? = nil, maximumDuration: Double? = nil) {
        self.deviceID = deviceID
        self.engine = engine
        self.screenSelectionID = screenSelectionID
        self.maximumDuration = maximumDuration
    }
}

public struct RecordingDetails: Sendable {
    public let deviceName: String
    public let audioFilename: String
    public let captureEngine: EnhancementEngine
    public let screenLabel: String?

    public init(deviceName: String, audioFilename: String, captureEngine: EnhancementEngine, screenLabel: String? = nil) {
        self.deviceName = deviceName
        self.audioFilename = audioFilename
        self.captureEngine = captureEngine
        self.screenLabel = screenLabel
    }
}

public struct RecordedAudio: Sendable {
    public let url: URL
    public let duration: Double
    public let captureEngine: EnhancementEngine
    public let screenFilename: String?
    public let warnings: [String]

    public init(url: URL, duration: Double, captureEngine: EnhancementEngine, screenFilename: String? = nil, warnings: [String] = []) {
        self.url = url
        self.duration = duration
        self.captureEngine = captureEngine
        self.screenFilename = screenFilename
        self.warnings = warnings
    }
}

@MainActor
public protocol MeetingRecording: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func start(in directory: URL, settings: CaptureSettings) async throws -> RecordingDetails
    func stop() async throws -> RecordedAudio
    func cancel() async throws -> RecordedAudio?
}

public struct ProcessingOptions: Sendable {
    public var engine: EnhancementEngine
    public var tools: AdvancedEngineTools
    public var modelURL: URL?
    public var modelID: String?
    public var dictionary: PersonalDictionary
    public var requestNotes: Bool

    public init(engine: EnhancementEngine = .none, tools: AdvancedEngineTools = AdvancedEngineTools(),
                modelURL: URL? = nil, modelID: String? = nil,
                dictionary: PersonalDictionary = PersonalDictionary(contents: ""), requestNotes: Bool = false) {
        self.engine = engine
        self.tools = tools
        self.modelURL = modelURL
        self.modelID = modelID
        self.dictionary = dictionary
        self.requestNotes = requestNotes
    }
}

public struct PipelineOperations: Sendable {
    public var enhance: @Sendable (URL, EnhancementEngine, EnhancementEngine, URL, AdvancedEngineTools) async throws -> EnhancedAudio
    public var transcribe: @Sendable (URL, URL, URL, PersonalDictionary) async throws -> String
    public var notes: @Sendable (URL, NotesAuthorization) async throws -> String

    public init(
        enhance: @escaping @Sendable (URL, EnhancementEngine, EnhancementEngine, URL, AdvancedEngineTools) async throws -> EnhancedAudio = {
            try await AudioEnhancer(tools: $4).enhance(source: $0, selected: $1, captured: $2, directory: $3)
        },
        transcribe: @escaping @Sendable (URL, URL, URL, PersonalDictionary) async throws -> String = {
            try await LocalTranscription.transcribe(audio: $0, model: $1, directory: $2, dictionary: $3)
        },
        notes: @escaping @Sendable (URL, NotesAuthorization) async throws -> String = {
            try await NotesRunner.generate(transcript: $0, authorization: $1)
        }
    ) {
        self.enhance = enhance
        self.transcribe = transcribe
        self.notes = notes
    }
}

@MainActor
public final class MeetingJob: ObservableObject {
    @Published public private(set) var phase: MeetingPhase?
    @Published public private(set) var meeting: Meeting?
    @Published public private(set) var status = "Ready. Nothing is being recorded."
    @Published public private(set) var startedAt: Date?
    public var isBusy: Bool { phase?.isWorking == true }
    public var isRecording: Bool { phase == .recording }

    private let store: MeetingStore
    private let consent: NotesConsentStore
    private let recorder: MeetingRecording
    private let operations: PipelineOperations
    private var options = ProcessingOptions()
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var cancelling = false

    public init(store: MeetingStore, consent: NotesConsentStore,
                recorder: MeetingRecording, operations: PipelineOperations = PipelineOperations()) {
        self.store = store
        self.consent = consent
        self.recorder = recorder
        self.operations = operations
        recorder.onFailure = { [weak self] message in self?.cancel(failure: message) }
    }

    public func start(title: String, capture: CaptureSettings, processing: ProcessingOptions) throws {
        guard !isBusy else { throw CrispyError.busy }
        if let duration = capture.maximumDuration,
           !duration.isFinite || duration <= 0 || duration > 86_400 {
            throw CrispyError.invalidCommand("recording duration must be greater than zero and no more than 86400 seconds")
        }
        guard capture.engine == processing.engine else {
            throw CrispyError.unavailable("Capture and processing engine selections must agree.")
        }
        if let reason = processing.tools.readiness(for: capture.engine) {
            throw CrispyError.unavailable(reason)
        }
        generation = UUID()
        let token = generation
        options = processing
        meeting = nil
        phase = .preparing
        status = "Preparing capture. Microphone permission belongs to RAPP Crispy."
        task = Task {
            do {
                let created = try await store.create(title: title, engine: capture.engine)
                // Keep the newly created directory visible even if cancellation raced its creation.
                meeting = created
                try check(token)
                let directory = try await store.directory(for: created.id)
                let details = try await recorder.start(in: directory, settings: capture)
                try check(token)
                meeting?.deviceName = details.deviceName
                meeting?.audioFilename = details.audioFilename
                meeting?.captureEngine = details.captureEngine
                meeting?.screenLabel = details.screenLabel
                try await store.writeText(details.deviceName + "\n", meetingID: created.id, filename: "device.txt")
                startedAt = Date()
                try await transition(.recording, message: "Recording \(details.deviceName). \(details.captureEngine.title).", token: token)
                if let duration = capture.maximumDuration {
                    deadline = Task { [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(duration))
                            guard let self, self.generation == token, self.isRecording else { return }
                            try self.stop()
                        } catch is CancellationError {
                            return
                        } catch {
                            self?.cancel(failure: error.localizedDescription)
                        }
                    }
                }
            } catch {
                if generation == token { await fail(error, token: token) }
            }
        }
    }

    public func stop() throws {
        guard phase == .recording else { throw CrispyError.noActiveRecording }
        deadline?.cancel()
        let token = generation
        phase = .stopping
        status = "Stopping capture and finalizing local audio…"
        task = Task {
            do {
                let recorded = try await recorder.stop()
                try check(token)
                apply(recorded)
                try await process(token: token)
            } catch {
                if generation == token { await fail(error, token: token) }
            }
        }
    }

    public func processExisting(_ existing: Meeting, options: ProcessingOptions) throws {
        guard !isBusy else { throw CrispyError.busy }
        guard existing.audioFilename != nil else { throw CrispyError.invalidRecording("this meeting has no microphone file") }
        generation = UUID()
        let token = generation
        meeting = existing
        self.options = options
        phase = .enhancing
        status = "Processing stored audio locally…"
        task = Task {
            do { try await process(token: token) }
            catch { if generation == token { await fail(error, token: token) } }
        }
    }

    public func generateNotes(for existing: Meeting) throws {
        guard !isBusy else { throw CrispyError.busy }
        generation = UUID()
        let token = generation
        meeting = existing
        phase = .writingNotes
        status = "Checking notes provider consent…"
        task = Task {
            do {
                try await writeNotes(token: token)
            } catch {
                if generation == token {
                    meeting?.notesState = .failed
                    await fail(error, token: token)
                }
            }
        }
    }

    public func revokeNotesConsent() throws {
        // Revoke in memory before stopping the job; even a failed disk write cannot authorize another send.
        do {
            try consent.revoke()
        } catch {
            if phase == .writingNotes { cancel(failure: "Notes consent revoked, but saving that preference failed: \(error.localizedDescription)") }
            throw error
        }
        if phase == .writingNotes { cancel() }
    }

    public func cancel(failure: String? = nil) {
        guard isBusy, !cancelling, phase != .stopping || failure == nil else { return }
        cancelling = true
        generation = UUID()
        let token = generation
        deadline?.cancel()
        let previous = task
        previous?.cancel()
        let wasNotes = phase == .writingNotes
        phase = .stopping
        status = "Cancelling. Capture is being stopped; completed local files will be kept."
        task = Task {
            await previous?.value
            var cleanupFailure: String?
            do {
                if let partial = try await recorder.cancel() { apply(partial) }
            } catch {
                cleanupFailure = error.localizedDescription
            }
            if wasNotes { meeting?.notesState = .cancelled }
            let message = failure ?? "Cancelled. Existing local audio and text were kept. No further processing will run."
            do {
                try await transition(failure == nil && cleanupFailure == nil ? .cancelled : .failed,
                    message: message + (cleanupFailure.map { " Cleanup: \($0)" } ?? ""), token: token)
            } catch {
                phase = .failed
                status = "Capture stopped, but saving cancellation failed: \(error.localizedDescription)"
            }
            startedAt = nil
            cancelling = false
        }
    }

    public func waitForCurrentOperation() async { await task?.value }

    private func apply(_ recorded: RecordedAudio) {
        meeting?.audioFilename = recorded.url.lastPathComponent
        meeting?.duration = recorded.duration
        meeting?.captureEngine = recorded.captureEngine
        meeting?.screenFilename = recorded.screenFilename
        meeting?.captureWarnings = recorded.warnings
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func transition(_ phase: MeetingPhase, message: String, token: UUID) async throws {
        try check(token)
        let status = message + (meeting?.captureWarnings?.isEmpty == false
            ? " Capture warning: " + (meeting?.captureWarnings ?? []).joined(separator: " ") : "")
        var updated = meeting
        updated?.phase = phase
        updated?.message = status
        if let updated { try await store.save(updated) }
        try check(token)
        meeting = updated
        self.status = status
        self.phase = phase
    }

    private func process(token: UUID) async throws {
        guard let current = meeting, let filename = current.audioFilename else {
            throw CrispyError.invalidRecording("no stored audio")
        }
        let directory = try await store.directory(for: current.id)
        let source = try await store.fileURL(meetingID: current.id, filename: filename)
        try await transition(.enhancing, message: options.engine == .none
            ? "Keeping captured audio — no additional enhancement requested."
            : "Using \(options.engine.title)…", token: token)
        let enhanced = try await operations.enhance(source, options.engine, current.captureEngine ?? .none, directory, options.tools)
        try check(token)
        guard enhanced.report.engine == options.engine else {
            throw CrispyError.unavailable("The enhancer returned a different engine than the one selected. The result was rejected.")
        }
        _ = try await store.fileURL(meetingID: current.id, filename: enhanced.url.lastPathComponent)
        guard enhanced.url.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path else {
            throw CrispyError.unsafePath(enhanced.url.path)
        }
        meeting?.enhancement = enhanced.report
        meeting?.engine = options.engine
        meeting?.enhancedAudioFilename = enhanced.url == source ? nil : enhanced.url.lastPathComponent
        meeting?.duration = enhanced.report.audioSeconds
        guard let model = options.modelURL else {
            try await transition(.recorded, message: "Audio saved locally. Download and select a verified speech model in Settings, then choose Transcribe.", token: token)
            startedAt = nil
            return
        }
        try await transition(.transcribing, message: "Transcribing locally with \(options.modelID ?? model.lastPathComponent). No audio is sent to a server.", token: token)
        let transcript = try await operations.transcribe(enhanced.url, model, directory, options.dictionary)
        try check(token)
        try await store.writeText(transcript, meetingID: current.id, filename: "transcript.txt")
        meeting?.hasTranscript = true
        meeting?.speechModelID = options.modelID
        if options.requestNotes && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await writeNotes(token: token)
        } else {
            try await transition(.completed, message: transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Local transcription finished: no speech detected. No notes were generated."
                : "Audio and transcript saved locally. Notes were not requested.", token: token)
        }
        startedAt = nil
    }

    private func writeNotes(token: UUID) async throws {
        try check(token)
        guard let current = meeting,
              let transcript = try await store.readText(meetingID: current.id, filename: "transcript.txt"),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CrispyError.noTranscript
        }
        let authorization: NotesAuthorization
        do {
            authorization = try consent.authorize()
        } catch {
            meeting?.notesState = .needsConsent
            try await transition(.completed, message: "Local transcript kept. \(error.localizedDescription)", token: token)
            return
        }
        meeting?.notesState = .pending
        try await transition(.writingNotes,
            message: "Requested notes: \(authorization.provider.name) → \(authorization.provider.destination). You can revoke consent in Settings.", token: token)
        let path = try await store.fileURL(meetingID: current.id, filename: "transcript.txt")
        let text: String
        do {
            text = try await operations.notes(path, authorization)
            try check(token)
            try consent.check(authorization)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CrispyError.emptyNotes }
        } catch {
            meeting?.notesState = .failed
            throw error
        }
        try await store.writeText(text, meetingID: current.id, filename: "notes.md")
        meeting?.notesState = .completed
        try await transition(.completed, message: "Provider-generated notes saved. Review against the transcript; they may contain errors.", token: token)
    }

    private func fail(_ error: Error, token: UUID) async {
        var message = error.localizedDescription
        do {
            if let partial = try await recorder.cancel() { apply(partial) }
        } catch {
            message += " Capture cleanup: \(error.localizedDescription)"
        }
        do {
            try await transition(.failed, message: "\(message) Existing local files were kept.", token: token)
        } catch {
            phase = .failed
            status = "\(message) Saving job state also failed: \(error.localizedDescription)"
        }
        startedAt = nil
    }
}
