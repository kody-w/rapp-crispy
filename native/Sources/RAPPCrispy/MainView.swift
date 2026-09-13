import AppKit
import RAPPCrispyCore
import SwiftUI

struct MainView: View {
    @ObservedObject var model: CrispyAppModel
    @ObservedObject var job: MeetingJob

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.section) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
                    .accessibilityIdentifier("crispy.section.\(section.id.lowercased())")
            }
            .navigationTitle("RAPP Crispy")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("On-device by default", systemImage: "lock.shield")
                    Text("Version \(CrispyVersion.current)").font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                if job.isBusy {
                    HStack {
                        Image(systemName: job.isRecording ? "record.circle.fill" : "hourglass")
                            .foregroundStyle(job.isRecording ? .red : .orange)
                        Text(job.status).lineLimit(2).font(.callout)
                        Spacer()
                        if job.isRecording {
                            Button("Stop") { model.stop() }.accessibilityIdentifier("crispy.active.stop")
                        }
                        Button("Cancel") { job.cancel() }.accessibilityIdentifier("crispy.active.cancel")
                    }.padding().background(.regularMaterial)
                }
                switch model.section {
                case .record: RecordingView(model: model, job: job, recorder: model.recorder, consent: model.consent)
                case .history: HistoryView(model: model, job: job)
                case .settings: SettingsView(model: model, consent: model.consent, models: model.models)
                case .diagnostics: DiagnosticsView(model: model)
                }
            }
            .frame(minWidth: 690, minHeight: 520)
        }
        .task { await model.refreshHistory() }
        .onChange(of: job.phase) { _, _ in
            NSApp.dockTile.badgeLabel = job.isRecording ? "REC" : nil
            Task { await model.refreshHistory() }
        }
        .alert("RAPP Crispy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct RecordingView: View {
    @ObservedObject var model: CrispyAppModel
    @ObservedObject var job: MeetingJob
    @ObservedObject var recorder: NativeRecorder
    @ObservedObject var consent: NotesConsentStore
    @State private var choosingScreen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your meeting. On your Mac.").font(.largeTitle.bold())
                    Text("Capture your microphone, enhance locally, and keep a readable transcript beside your audio.")
                        .foregroundStyle(.secondary)
                }
                if let notice = model.notice { Text(notice).foregroundStyle(.orange) }
                GroupBox("New meeting") {
                    Form {
                        TextField("Meeting title", text: $model.title).accessibilityIdentifier("crispy.record.title")
                        Picker("Microphone", selection: $model.selectedDeviceID) {
                            Text("Choose an input").tag(Optional<UInt32>.none)
                            ForEach((model.diagnostics?.devices ?? []).filter { $0.inputChannels > 0 }) { device in
                                Text(device.name + (device.isVirtual ? " (virtual — may already be processed)" : ""))
                                    .tag(Optional(device.id))
                            }
                        }.accessibilityIdentifier("crispy.record.microphone")
                        Picker("Enhancement", selection: $model.preferences.engine) {
                            ForEach(EnhancementEngine.allCases) { Text($0.title).tag($0) }
                        }.accessibilityIdentifier("crispy.record.engine")
                        Text(model.preferences.engine.explanation).font(.caption).foregroundStyle(.secondary)
                        if let reason = model.preferences.advancedTools.readiness(for: model.preferences.engine) {
                            Text(reason).foregroundStyle(.orange).font(.caption)
                        }
                        HStack {
                            TextField("Stop automatically after", value: $model.maximumSeconds, format: .number)
                                .accessibilityIdentifier("crispy.record.duration")
                            Text("seconds (0 = use Stop)").foregroundStyle(.secondary)
                        }
                        Toggle("Also record a chosen screen/window (video only)", isOn: $model.includeScreen)
                            .accessibilityIdentifier("crispy.record.screen")
                        if model.includeScreen {
                            HStack {
                                Text(recorder.screen.label(for: model.selectedScreenID) ?? "No screen/window selected")
                                Spacer()
                                Button("Choose screen/window…") { choosingScreen = true }
                                    .accessibilityIdentifier("crispy.record.choose-screen")
                            }
                            Text("Screen Recording permission is requested only for this selection. It does not capture remote participants or system audio.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Request provider notes after transcription", isOn: $model.requestNotes)
                            .disabled(!consent.isApproved)
                            .accessibilityIdentifier("crispy.record.notes")
                        Text(consent.status).font(.caption).foregroundStyle(.secondary)
                    }.padding(8).disabled(job.isBusy)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Circle().fill(job.isRecording ? .red : .secondary.opacity(0.4)).frame(width: 12, height: 12)
                            Text(job.isRecording ? "RECORDING" : job.phase?.rawValue.capitalized ?? "Ready").font(.headline)
                            if job.isRecording, let date = job.startedAt {
                                Text(date, style: .timer).monospacedDigit()
                            }
                            Spacer()
                            if job.isRecording { Text("Input level").font(.caption) }
                        }
                        if job.isRecording {
                            ProgressView(value: min(1, recorder.level * 4))
                                .tint(.green).accessibilityLabel("Microphone input level")
                        }
                        Text(job.status).textSelection(.enabled).accessibilityIdentifier("crispy.job.status")
                        HStack {
                            Button { model.record() } label: { Label("Record", systemImage: "record.circle.fill") }
                                .buttonStyle(.borderedProminent).tint(.red).disabled(job.isBusy)
                                .keyboardShortcut("r", modifiers: [.command, .shift])
                                .accessibilityIdentifier("crispy.record.start")
                            Button { model.stop() } label: { Label("Stop & process", systemImage: "stop.fill") }
                                .disabled(!job.isRecording).accessibilityIdentifier("crispy.record.stop")
                            Button("Cancel job") { job.cancel() }.disabled(!job.isBusy)
                                .accessibilityIdentifier("crispy.record.cancel")
                            Spacer()
                            Button("Models & notes setup") { model.section = .settings }
                        }
                        Text("Cancel keeps captured local files and stops the remaining work. No capture starts automatically. Obtain participants’ permission before recording.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                Text(model.speechRuntimeStatus).font(.caption).foregroundStyle(.secondary)
                Text("No model yet? Recording still works. Download a verified model in Settings, then transcribe from Meetings.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .onChange(of: model.preferences.engine) { _, _ in model.savePreferences() }
        .sheet(isPresented: $choosingScreen) {
            ScreenSelectionView(service: recorder.screen, selection: $model.selectedScreenID)
        }
    }
}

private struct ScreenSelectionView: View {
    @ObservedObject var service: ScreenCaptureService
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var proposed: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose exactly what to capture").font(.title2.bold())
            Text("Screen Recording permission may be requested now. Microphone audio is recorded separately; system audio is not captured.")
            if service.isLoading { ProgressView("Loading shareable displays and windows…") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            List(service.choices, selection: $proposed) { choice in
                VStack(alignment: .leading) {
                    Text(choice.label)
                    Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                }.tag(choice.id)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Use selected screen/window") { selection = proposed; dismiss() }
                    .disabled(proposed == nil).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("crispy.screen.confirm")
            }
        }.padding(24).frame(width: 680, height: 500)
        .task {
            do { try await service.loadChoices() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: CrispyAppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Device diagnostics").font(.largeTitle.bold())
                    Spacer()
                    Button("Refresh") { model.refreshDevices() }.accessibilityIdentifier("crispy.diagnostics.refresh")
                }
                Text(model.diagnostics?.microphonePermission ?? "Device status unavailable")
                Text(model.speechRuntimeStatus).textSelection(.enabled)
                if let diagnostics = model.diagnostics {
                    Text(diagnostics.explanation).padding().background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    Text("Audio devices").font(.headline)
                    ForEach(diagnostics.devices) { device in
                        HStack {
                            Image(systemName: device.isVirtual ? "arrow.triangle.branch" : "mic")
                            VStack(alignment: .leading) {
                                Text(device.name + (device.isDefaultInput ? " — system default" : ""))
                                Text("\(device.inputChannels) input / \(device.outputChannels) output channels" +
                                     (device.isLoopbackCandidate ? " • possible loopback, NOT verified" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(diagnostics.loopbackCandidates.isEmpty
                        ? "No named duplex loopback candidate found. Recording your hardware microphone still works."
                        : "A candidate device exists, but the app has not tested or changed its routing. A driver name is not proof that live virtual-microphone or far-end capture works.")
                        .font(.callout)
                }
                Button("Open microphone privacy settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                }
                Text("This button opens Settings; it does not change permissions. Advanced engine performance must be measured with the existing CLI benchmark; Apple voice processing has no claimed benchmark score.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}
