import AppKit
import AVFoundation
import AVKit
import RAPPCrispyCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: CrispyAppModel
    @ObservedObject var job: MeetingJob
    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Text("Meetings").font(.title2.bold())
                    Spacer()
                    Button { Task { await model.refreshHistory() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh meeting history").accessibilityIdentifier("crispy.history.refresh")
                }.padding()
                List(model.meetings, selection: $model.selectedMeetingID) { meeting in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(meeting.title).font(.headline).lineLimit(2)
                        Text(meeting.createdAt, style: .date).font(.caption)
                        Text(meeting.phase.rawValue.capitalized +
                             (meeting.hasTranscript ? " • Transcript" : "") +
                             (meeting.notesState == .completed ? " • Notes" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(meeting.id)
                }.accessibilityIdentifier("crispy.history.list")
                if !model.historyIssues.isEmpty {
                    DisclosureGroup("Some folders need attention (\(model.historyIssues.count))") {
                        ForEach(model.historyIssues, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    }.padding()
                }
            }.frame(minWidth: 210, idealWidth: 260, maxWidth: 320)
            if let meeting = model.meetings.first(where: { $0.id == model.selectedMeetingID }) {
                MeetingDetailView(model: model, job: job, meeting: meeting)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "waveform",
                    description: Text("Record a meeting, or select an existing folder from your preserved ~/.rappcrispy library."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task { await model.refreshHistory() }
    }
}

private struct MeetingDetailView: View {
    @ObservedObject var model: CrispyAppModel
    @ObservedObject var job: MeetingJob
    let meeting: Meeting
    @State private var transcript: String?
    @State private var notes: String?
    @State private var audioURL: URL?
    @State private var videoURL: URL?
    @StateObject private var playback = MeetingAudioPlayback()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(meeting.title).font(.title2.bold())
            Text(meeting.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let message = meeting.message { Text(message).font(.callout).foregroundStyle(meeting.phase == .failed ? .red : .secondary) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = playback.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button {
                    do {
                        if let audioURL { try playback.toggle(url: audioURL) }
                    } catch { self.error = error.localizedDescription }
                } label: {
                    Label(playback.isPlaying ? "Pause audio" : "Play audio", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                }.disabled(audioURL == nil).accessibilityIdentifier("crispy.meeting.play")
                Button("Stop playback") { playback.stop() }.disabled(!playback.hasAudio)
                Spacer()
                Button("Show files") {
                    Task {
                        do { NSWorkspace.shared.open(try await model.store.directory(for: meeting.id)) }
                        catch { self.error = error.localizedDescription }
                    }
                }.accessibilityIdentifier("crispy.meeting.reveal")
            }
            if let captureEngine = meeting.captureEngine {
                Text("Capture: \(captureEngine.title)").font(.caption).foregroundStyle(.secondary)
            }
            if let report = meeting.enhancement {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.implementation).font(.caption)
                    if let rtf = report.realTimeFactor {
                        Text(String(format: "%.1f s audio • RTF %.4f (processing wall-time / audio duration)", report.audioSeconds, rtf))
                            .font(.caption.monospaced())
                    } else {
                        Text("No offline benchmark score is claimed for this capture.").font(.caption)
                    }
                }.foregroundStyle(.secondary)
            } else if meeting.phase == .legacy {
                Text("The legacy file's enhancement engine is unknown; an engine label has not been invented.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(meeting.hasTranscript ? "Reprocess locally…" : "Transcribe locally") { model.process(meeting) }
                    .disabled(job.isBusy || meeting.audioFilename == nil)
                    .accessibilityIdentifier("crispy.meeting.transcribe")
                Button("Request provider notes") { model.notes(meeting) }
                    .disabled(job.isBusy || !meeting.hasTranscript)
                    .accessibilityIdentifier("crispy.meeting.notes")
            }
            Text("Reprocessing uses the engine/model currently selected in Settings. Replaced transcripts and notes are backed up in .revisions; original recordings are never replaced.")
                .font(.caption).foregroundStyle(.secondary)
            TabView {
                textPage(transcript, missing: "No transcript yet. Select a verified model in Settings and choose Transcribe locally.",
                         empty: "The local recognizer detected no speech.")
                    .tabItem { Label("Transcript", systemImage: "text.alignleft") }
                textPage(notes, missing: "No provider-generated notes file. Notes are disabled until you configure and approve a provider, then explicitly request them.",
                         empty: "The existing notes file is empty; no completed notes are claimed.")
                    .tabItem { Label("Notes", systemImage: "note.text") }
                if let videoURL {
                    ScreenPlaybackView(url: videoURL)
                        .tabItem { Label("Screen video (silent)", systemImage: "display") }
                }
            }
        }.padding(24).frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(meeting.id)|\(meeting.phase.rawValue)|\(meeting.hasTranscript)|\(meeting.notesState.rawValue)") {
            playback.stop()
            do {
                transcript = try await model.store.readText(meetingID: meeting.id, filename: "transcript.txt")
                notes = try await model.store.readText(meetingID: meeting.id, filename: "notes.md")
                if let filename = meeting.preferredAudioFilename {
                    audioURL = try await model.store.fileURL(meetingID: meeting.id, filename: filename)
                } else { audioURL = nil }
                if let filename = meeting.screenFilename {
                    videoURL = try await model.store.fileURL(meetingID: meeting.id, filename: filename)
                } else { videoURL = nil }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { playback.stop() }
    }

    private func textPage(_ text: String?, missing: String, empty: String) -> some View {
        ScrollView {
            Text(text.map { $0.isEmpty ? empty : $0 } ?? missing)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
        }
    }
}

@MainActor
private final class MeetingAudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var hasAudio = false
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var url: URL?

    func toggle(url: URL) throws {
        error = nil
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        if player == nil || self.url != url {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            self.url = url
            hasAudio = true
        }
        guard player?.play() == true else { throw CrispyError.invalidRecording("audio playback could not start") }
        isPlaying = true
    }

    func stop() {
        player?.stop()
        player = nil
        url = nil
        isPlaying = false
        hasAudio = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.player.map(ObjectIdentifier.init) == identifier else { return }
            self.isPlaying = false
            if !flag { self.error = "Audio playback did not finish successfully." }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "The audio file could not be decoded."
        let identifier = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.player.map(ObjectIdentifier.init) == identifier else { return }
            self.isPlaying = false
            self.error = message
        }
    }
}

private struct ScreenPlaybackView: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        VStack(alignment: .leading) {
            Text("Video only. Microphone audio is available in the separate audio player above. This is not a synchronized far-end recording.")
                .font(.caption).padding(8)
            VideoPlayer(player: player)
        }
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause(); player = nil }
    }
}
