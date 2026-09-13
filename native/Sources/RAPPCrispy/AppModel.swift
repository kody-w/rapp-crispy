import AppKit
import Combine
import Foundation
import RAPPCrispyCore
import RAPPDesktopSupport

enum AppSection: String, CaseIterable, Identifiable {
    case record = "Record", history = "Meetings", settings = "Settings", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .record: return "record.circle"
        case .history: return "text.book.closed"
        case .settings: return "slider.horizontal.3"
        case .diagnostics: return "stethoscope"
        }
    }
}

@MainActor
final class CrispyAppModel: ObservableObject {
    struct Preferences: Codable {
        var engine: EnhancementEngine = .appleVoiceProcessing
        var speechModelID = SpeechModels.all.first?.id ?? ""
        var advancedTools = AdvancedEngineTools()
    }

    let store: MeetingStore
    let recorder: NativeRecorder
    let job: MeetingJob
    let consent: NotesConsentStore
    let models: ModelStore
    @Published var section: AppSection = .record
    @Published var preferences = Preferences()
    @Published var title = ""
    @Published var maximumSeconds: Double = 0
    @Published var selectedDeviceID: UInt32?
    @Published var selectedScreenID: String?
    @Published var includeScreen = false
    @Published var requestNotes = false
    @Published var meetings: [Meeting] = []
    @Published var selectedMeetingID: String?
    @Published var historyIssues: [String] = []
    @Published var diagnostics: DeviceDiagnostics?
    @Published var errorMessage: String?
    @Published var notice: String?
    private let preferencesURL: URL

    init(root: URL = MeetingStore.defaultRoot) throws {
        store = try MeetingStore(root: root)
        recorder = NativeRecorder()
        consent = NotesConsentStore(directory: root)
        job = MeetingJob(store: store, consent: consent, recorder: recorder)
        models = ModelStore(directory: root.appendingPathComponent("models/native-speech", isDirectory: true))
        preferencesURL = root.appendingPathComponent("native-preferences.json")
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            do { preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferencesURL)) }
            catch { errorMessage = "Could not load native preferences: \(error.localizedDescription). Defaults are shown; recordings were not changed." }
        }
        for name in ["deep-filter", "ffmpeg"] {
            do {
                let tool = try RuntimeTools.executable(named: name)
                if name == "deep-filter", preferences.advancedTools.deepFilter == nil { preferences.advancedTools.deepFilter = tool }
                if name == "ffmpeg", preferences.advancedTools.ffmpeg == nil { preferences.advancedTools.ffmpeg = tool }
            } catch {
                // These are optional engines. Their absence is displayed by readiness(for:), never replaced.
            }
        }
        refreshDevices()
    }

    var selectedModel: SpeechModel? { SpeechModels.all.first { $0.id == preferences.speechModelID } }
    var speechRuntimeStatus: String {
        do { return "Local speech runtime: \(try RuntimeTools.executable(named: "whisper-cli").path)" }
        catch { return error.localizedDescription }
    }

    func savePreferences() {
        do {
            try JSONEncoder().encode(preferences).write(to: preferencesURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
        } catch { errorMessage = "Could not save preferences: \(error.localizedDescription)" }
    }

    func refreshDevices() {
        do {
            let snapshot = try AudioDevices.snapshot()
            diagnostics = snapshot
            if !snapshot.devices.contains(where: { $0.id == selectedDeviceID && $0.inputChannels > 0 }) {
                selectedDeviceID = DeviceDiagnostics.preferredInput(snapshot.devices)?.id
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshHistory() async {
        do {
            let listing = try await store.list(activeID: job.isBusy ? job.meeting?.id : nil)
            meetings = listing.meetings
            historyIssues = listing.issues
            if selectedMeetingID == nil { selectedMeetingID = job.meeting?.id ?? meetings.first?.id }
        } catch { errorMessage = "Could not load meetings: \(error.localizedDescription)" }
    }

    func options() throws -> ProcessingOptions {
        let modelURL = selectedModel.flatMap { models.isInstalled($0) ? models.fileURL(for: $0) : nil }
        return ProcessingOptions(engine: preferences.engine, tools: preferences.advancedTools,
            modelURL: modelURL, modelID: selectedModel?.id,
            dictionary: try PersonalDictionary.load(root: store.root), requestNotes: requestNotes)
    }

    func record() {
        do {
            guard selectedDeviceID != nil else { throw CrispyError.unavailable("Choose an available microphone first.") }
            guard !includeScreen || selectedScreenID != nil else {
                throw CrispyError.unavailable("Choose a specific display or window, or turn screen video off.")
            }
            try job.start(title: title,
                capture: CaptureSettings(deviceID: selectedDeviceID, engine: preferences.engine,
                    screenSelectionID: includeScreen ? selectedScreenID : nil,
                    maximumDuration: maximumSeconds == 0 ? nil : maximumSeconds),
                processing: options())
        } catch { errorMessage = error.localizedDescription }
    }

    func stop() {
        do { try job.stop() }
        catch { errorMessage = error.localizedDescription }
    }

    func process(_ meeting: Meeting) {
        do {
            var settings = try options()
            // Reusing previously processed capture is allowed; applying it to original audio is not.
            if settings.engine == .appleVoiceProcessing && meeting.captureEngine != .appleVoiceProcessing {
                throw CrispyError.unavailable("This file was not captured with Apple voice processing. Select Original microphone or an available advanced engine in Settings before processing it.")
            }
            settings.requestNotes = false
            try job.processExisting(meeting, options: settings)
        } catch { errorMessage = error.localizedDescription }
    }

    func notes(_ meeting: Meeting) {
        do { try job.generateNotes(for: meeting) }
        catch { errorMessage = error.localizedDescription }
    }

    func handle(_ url: URL) {
        do {
            switch try NativeCommand.parse(url) {
            case .prepareRecording(let name, let seconds, let screen):
                guard !job.isBusy else { throw CrispyError.busy }
                title = name
                maximumSeconds = Double(seconds ?? 0)
                includeScreen = screen
                selectedScreenID = nil
                requestNotes = false
                section = .record
                notice = "Recording controls prepared. Review the microphone and screen selection, then click Record. Nothing has started."
            case .history: section = .history
            case .meeting(let id): selectedMeetingID = id; section = .history
            case .diagnostics: refreshDevices(); section = .diagnostics
            case .models: section = .settings
            }
            activate()
        } catch { errorMessage = error.localizedDescription }
    }

    func activate() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    func chooseFile(title: String, initialDirectory: URL? = nil, completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }
}

@MainActor
final class AppBootstrap: ObservableObject {
    @Published var model: CrispyAppModel?
    @Published var error: String?
    init() {
        do { model = try CrispyAppModel() }
        catch { self.error = error.localizedDescription }
    }
}
