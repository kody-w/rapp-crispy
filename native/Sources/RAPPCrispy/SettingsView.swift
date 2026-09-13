import AppKit
import RAPPCrispyCore
import RAPPDesktopSupport
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: CrispyAppModel
    @ObservedObject var consent: NotesConsentStore
    @ObservedObject var models: ModelStore
    @State private var providerName = ""
    @State private var destination = ""
    @State private var providerURL: URL?
    @State private var providerKind: NotesProviderKind = .cloudExecutable
    @State private var acknowledged = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Local models & explicit choices").font(.largeTitle.bold())
                GroupBox("On-device English transcription") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Model downloads contact the named model host, not a transcription service. No meeting audio, screen video or transcript is uploaded.")
                            .font(.callout)
                        ForEach(SpeechModels.all) { speech in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: models.isInstalled(speech) ? "checkmark.shield.fill" : "arrow.down.circle")
                                        .foregroundStyle(models.isInstalled(speech) ? .green : .secondary)
                                    VStack(alignment: .leading) {
                                        Text(speech.title).font(.headline)
                                        Text("\(ByteCountFormatter.string(fromByteCount: speech.bytes, countStyle: .file)) • \(speech.url.host ?? "")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(model.preferences.speechModelID == speech.id ? "Selected" : "Select") {
                                        model.preferences.speechModelID = speech.id
                                        model.savePreferences()
                                    }.disabled(model.preferences.speechModelID == speech.id)
                                        .accessibilityIdentifier("crispy.model.select.\(speech.id)")
                                    if !models.isInstalled(speech) {
                                        Button("Download verified model") {
                                            Task {
                                                do { try await models.download(speech) }
                                                catch { model.errorMessage = error.localizedDescription }
                                            }
                                        }.disabled(models.progress != nil)
                                            .accessibilityIdentifier("crispy.model.download.\(speech.id)")
                                    }
                                }
                                DisclosureGroup("Source, license and integrity") {
                                    Link("Model source", destination: speech.url)
                                    Link("Model license", destination: speech.licenseURL)
                                    Text("SHA-256: \(speech.sha256)").font(.caption.monospaced()).textSelection(.enabled)
                                }.font(.caption)
                            }.padding(.vertical, 8)
                        }
                        if let progress = models.progress {
                            ProgressView(value: progress)
                            Button("Cancel model download") { models.cancel() }.accessibilityIdentifier("crispy.model.cancel")
                        }
                        Text(models.status).font(.caption).textSelection(.enabled)
                        Text(model.speechRuntimeStatus).font(.caption).foregroundStyle(.secondary)
                        Text("The native transcript enforces your personal dictionary after decoding. The legacy CLI additionally supplies a weighted decoding prompt; the shared native transcription API does not expose prompt biasing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                GroupBox("Enhancement — never a silent substitute") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Engine", selection: $model.preferences.engine) {
                            ForEach(EnhancementEngine.allCases) { Text($0.title).tag($0) }
                        }.accessibilityIdentifier("crispy.settings.engine")
                        Text(model.preferences.engine.explanation).font(.callout)
                        if let reason = model.preferences.advancedTools.readiness(for: model.preferences.engine) {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                        }
                        DisclosureGroup("Optional advanced engines (trusted, user-selected tools)") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("No engine executable is downloaded by this app. These existing developer paths remain optional; native capture, Apple voice processing and bundled Whisper do not require Homebrew or Terminal.")
                                    .font(.caption)
                                toolRow("DeepFilterNet3 executable", url: model.preferences.advancedTools.deepFilter) {
                                    model.preferences.advancedTools.deepFilter = $0
                                }
                                toolRow("ffmpeg with arnndn", url: model.preferences.advancedTools.ffmpeg) {
                                    model.preferences.advancedTools.ffmpeg = $0
                                }
                                toolRow("RNNoise .rnnn model", url: model.preferences.advancedTools.rnnoiseModel) {
                                    model.preferences.advancedTools.rnnoiseModel = $0
                                }
                                Text("DeepFilterNet3 is file-to-file, not a native live virtual microphone. CLI noise-floor / speech-retention / RTF metrics are retained and are not relabeled as Apple voice-processing results.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }
                    }.padding(10)
                }
                GroupBox("Notes provider — disabled until approval") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(consent.status).font(.headline).accessibilityIdentifier("crispy.notes.status")
                        if let warning = consent.warning { Text(warning).foregroundStyle(.orange) }
                        Text("The old notes.sh hook can call claude -p and send transcripts to Anthropic. It is not enabled or invoked automatically. Recording and transcription continue without a notes provider.")
                            .font(.callout)
                        TextField("Provider name", text: $providerName).accessibilityIdentifier("crispy.notes.provider-name")
                        Picker("Provider type", selection: $providerKind) {
                            Text("Cloud executable — sends transcript off this Mac").tag(NotesProviderKind.cloudExecutable)
                            Text("Local executable — reviewed by me").tag(NotesProviderKind.localExecutable)
                        }
                        TextField("Exact destination (for example Anthropic, or my local model)", text: $destination)
                            .accessibilityIdentifier("crispy.notes.destination")
                        HStack {
                            Text(providerURL?.path ?? "No executable selected").font(.caption.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button("Choose provider executable…") {
                                model.chooseFile(title: "Choose a trusted notes hook (transcript path as first argument)",
                                    initialDirectory: model.store.root.appendingPathComponent("hooks")) { providerURL = $0; acknowledged = false }
                            }.accessibilityIdentifier("crispy.notes.choose-provider")
                        }
                        Text("Hooks receive the transcript file path as argument 1 and --rappcrispy-explicit-consent as argument 2, and must return real Markdown on stdout. A 'local' label is your review, not a network sandbox. Configure the provider itself outside this app if it needs credentials; no credentials are stored here.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("I have reviewed this executable and authorize it to read transcripts and send them to the destination named above when I request notes.", isOn: $acknowledged)
                            .accessibilityIdentifier("crispy.notes.consent")
                        HStack {
                            Button("Save provider (leave disabled)") { saveProvider(approve: false) }
                                .disabled(providerURL == nil)
                            Button("Approve selected provider") { saveProvider(approve: true) }
                                .disabled(!acknowledged || providerURL == nil || providerName.isEmpty || destination.isEmpty)
                                .accessibilityIdentifier("crispy.notes.approve")
                            Button("Revoke consent") {
                                do { try model.job.revokeNotesConsent(); acknowledged = false; model.requestNotes = false }
                                catch { model.errorMessage = error.localizedDescription }
                            }.accessibilityIdentifier("crispy.notes.revoke")
                        }
                        Text("Consent is bound to this executable's SHA-256 and configuration. Changes require fresh approval. Revocation cancels an active notes job and blocks future sends; it cannot recall content a provider already received.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
            }.padding(28)
        }
        .onAppear {
            if let provider = consent.provider {
                providerName = provider.name
                destination = provider.destination
                providerURL = provider.executable
                providerKind = provider.kind
            }
        }
        .onChange(of: model.preferences.engine) { _, _ in model.savePreferences() }
        .onChange(of: providerName) { _, _ in acknowledged = false }
        .onChange(of: destination) { _, _ in acknowledged = false }
        .onChange(of: providerKind) { _, _ in acknowledged = false }
    }

    private func toolRow(_ name: String, url: URL?, set: @escaping (URL?) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(url?.path ?? "Not configured / not bundled").font(.caption.monospaced()).textSelection(.enabled)
            }
            Spacer()
            Button("Choose…") {
                model.chooseFile(title: name, initialDirectory: model.store.root) { set($0); model.savePreferences() }
            }
            Button("Clear") { set(nil); model.savePreferences() }.disabled(url == nil)
        }
    }

    private func saveProvider(approve: Bool) {
        guard let providerURL else { return }
        do {
            try model.job.revokeNotesConsent()
            try consent.configure(NotesProvider(name: providerName, executable: providerURL, kind: providerKind, destination: destination))
            if approve { try consent.approve() }
            acknowledged = false
            model.requestNotes = false
        } catch { model.errorMessage = error.localizedDescription }
    }
}
