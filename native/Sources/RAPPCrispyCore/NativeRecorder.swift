import Combine
import Foundation

@MainActor
public final class NativeRecorder: ObservableObject, MeetingRecording {
    @Published public private(set) var level: Double = 0
    public let screen = ScreenCaptureService()
    public var onFailure: ((String) -> Void)?
    private let microphone = MicrophoneCapture()
    private var screenRequested = false
    private var isEnding = false
    private var lastAudio: RecordedAudio?

    public init() {
        microphone.onMeter = { [weak self] in self?.level = $0 }
        microphone.onFailure = { [weak self] error in
            guard let self, !self.isEnding else { return }
            self.onFailure?(error)
        }
        screen.onFailure = { [weak self] error in
            guard let self, !self.isEnding else { return }
            self.onFailure?(error)
        }
    }

    public func start(in directory: URL, settings: CaptureSettings) async throws -> RecordingDetails {
        isEnding = false
        lastAudio = nil
        if let selection = settings.screenSelectionID, screen.label(for: selection) == nil {
            throw CrispyError.unavailable("The requested screen has not been explicitly selected. Choose a display or window in the app.")
        }
        let details = try await microphone.start(in: directory, settings: settings)
        try Task.checkCancellation()
        screenRequested = settings.screenSelectionID != nil
        if let selection = settings.screenSelectionID {
            try await screen.start(selection: selection, directory: directory)
        }
        try Task.checkCancellation()
        return RecordingDetails(deviceName: details.deviceName, audioFilename: details.audioFilename,
            captureEngine: details.captureEngine, screenLabel: screen.label(for: settings.screenSelectionID))
    }

    public func stop() async throws -> RecordedAudio {
        isEnding = true
        async let audioResult = microphone.stop()
        async let videoResult = screen.stop()
        let audio = try await audioResult
        lastAudio = audio
        let video = try await videoResult
        screenRequested = false
        lastAudio = nil
        return RecordedAudio(url: audio.url, duration: audio.duration, captureEngine: audio.captureEngine, screenFilename: video)
    }

    public func cancel() async throws -> RecordedAudio? {
        isEnding = true
        var audio = lastAudio
        var audioError: Error?
        var warnings: [String] = []
        do {
            if let partial = try await microphone.cancel() { audio = partial }
        } catch {
            audioError = error
            warnings.append("Microphone finalization: \(error.localizedDescription)")
        }
        var video: String?
        if screenRequested {
            do { video = try await screen.stop() }
            catch { warnings.append("Screen video was not finalized: \(error.localizedDescription)") }
            screenRequested = false
        }
        if audio == nil, let audioError { throw audioError }
        guard let audio else { return nil }
        lastAudio = nil
        return RecordedAudio(url: audio.url, duration: audio.duration, captureEngine: audio.captureEngine,
                             screenFilename: video ?? audio.screenFilename, warnings: warnings)
    }
}
