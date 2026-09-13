import Foundation
import XCTest
@testable import RAPPCrispyCore

final class MeetingJobTests: XCTestCase {
    @MainActor
    func testExplicitScreenChoiceIsRequiredBeforeAnyMicrophonePermissionRequest() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let recorder = NativeRecorder()
        do {
            _ = try await recorder.start(in: fixture.root, settings: CaptureSettings(screenSelectionID: "not-selected"))
            XCTFail("An unselected screen reached capture")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not been explicitly selected"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    @MainActor
    func testAutomaticStopUsesTheSameStopPipeline() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let recorder = FixtureRecorder()
        let job = MeetingJob(store: try MeetingStore(root: fixture.root),
            consent: NotesConsentStore(directory: fixture.root), recorder: recorder)
        try job.start(title: "Timed fixture", capture: CaptureSettings(engine: .none, maximumDuration: 0.05),
                      processing: ProcessingOptions())
        await job.waitForCurrentOperation()
        try await eventually { job.phase == .recorded }
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertFalse(recorder.active)
    }

    @MainActor
    func testRecordStopPersistAndNoNotesByDefault() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let store = try MeetingStore(root: fixture.root)
        let recorder = FixtureRecorder()
        let counter = PipelineCounter()
        let consent = NotesConsentStore(directory: fixture.root)
        let job = MeetingJob(store: store, consent: consent, recorder: recorder, operations: PipelineOperations(
            transcribe: { _, _, _, _ in await counter.transcribed(); return "A synthetic decision. Alex will test the app." },
            notes: { _, _ in await counter.noted(); return "This must not run by default." }
        ))
        XCTAssertFalse(job.isBusy)
        XCTAssertEqual(recorder.starts, 0)
        try job.start(title: "Generated meeting", capture: CaptureSettings(engine: .none),
            processing: ProcessingOptions(modelURL: fixture.model(), modelID: "fixture"))
        await job.waitForCurrentOperation()
        XCTAssertEqual(job.phase, .recording)
        XCTAssertTrue(recorder.active)
        XCTAssertThrowsError(try job.start(title: "duplicate", capture: CaptureSettings(engine: .none), processing: ProcessingOptions()))
        try job.stop()
        XCTAssertThrowsError(try job.stop())
        await job.waitForCurrentOperation()
        XCTAssertFalse(recorder.active)
        XCTAssertEqual(job.phase, .completed)
        XCTAssertEqual(recorder.stops, 1)
        let meeting = try XCTUnwrap(job.meeting)
        let saved = try await store.load(meeting.id)
        let text = try await store.readText(meetingID: meeting.id, filename: "transcript.txt")
        let notes = try await store.readText(meetingID: meeting.id, filename: "notes.md")
        let count = await counter.notes
        XCTAssertEqual(saved.phase, .completed)
        XCTAssertEqual(saved.speechModelID, "fixture")
        XCTAssertTrue(saved.hasTranscript)
        XCTAssertEqual(text, "A synthetic decision. Alex will test the app.")
        XCTAssertNil(notes)
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testCancelWhilePermissionPendingNeverStartsCapture() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let recorder = FixtureRecorder()
        recorder.delay = .seconds(60)
        let store = try MeetingStore(root: fixture.root)
        let job = MeetingJob(store: store, consent: NotesConsentStore(directory: fixture.root), recorder: recorder)
        try job.start(title: "Permission fixture", capture: CaptureSettings(engine: .none), processing: ProcessingOptions())
        try await eventually { recorder.starts == 1 }
        job.cancel()
        await job.waitForCurrentOperation()
        XCTAssertEqual(job.phase, .cancelled)
        XCTAssertFalse(recorder.active)
        XCTAssertNil(job.meeting?.audioFilename)
        let listing = try await store.list()
        XCTAssertEqual(listing.meetings.first?.phase, .cancelled)
    }

    @MainActor
    func testCancellationDuringTranscriptionKeepsAudioButNeverWritesPartialSuccess() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let counter = PipelineCounter()
        let store = try MeetingStore(root: fixture.root)
        let job = MeetingJob(store: store, consent: NotesConsentStore(directory: fixture.root), recorder: FixtureRecorder(),
            operations: PipelineOperations(transcribe: { _, _, _, _ in
                await counter.transcribed()
                try await Task.sleep(for: .seconds(60))
                return "This cancelled output must not be saved."
            }))
        try job.start(title: "Cancel fixture", capture: CaptureSettings(engine: .none),
                      processing: ProcessingOptions(modelURL: fixture.model()))
        await job.waitForCurrentOperation()
        try job.stop()
        try await eventually { await counter.transcriptions == 1 }
        job.cancel()
        await job.waitForCurrentOperation()
        XCTAssertEqual(job.phase, .cancelled)
        let current = try XCTUnwrap(job.meeting)
        XCTAssertNotNil(current.audioFilename)
        let transcript = try await store.readText(meetingID: current.id, filename: "transcript.txt")
        XCTAssertNil(transcript)
        XCTAssertFalse(current.hasTranscript)
    }

    @MainActor
    func testMissingModelIsVisibleAndAudioIsPreserved() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let store = try MeetingStore(root: fixture.root)
        let job = MeetingJob(store: store, consent: NotesConsentStore(directory: fixture.root), recorder: FixtureRecorder())
        try job.start(title: "No model", capture: CaptureSettings(engine: .none), processing: ProcessingOptions())
        await job.waitForCurrentOperation()
        try job.stop()
        await job.waitForCurrentOperation()
        XCTAssertEqual(job.phase, .recorded)
        XCTAssertTrue(job.status.contains("Download and select"))
        XCTAssertNotNil(job.meeting?.audioFilename)
        XCTAssertFalse(job.meeting?.hasTranscript ?? true)
    }

    @MainActor
    func testMissingConsentSkipsProviderWithoutLosingTranscript() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let store = try MeetingStore(root: fixture.root)
        let counter = PipelineCounter()
        let job = MeetingJob(store: store, consent: NotesConsentStore(directory: fixture.root), recorder: FixtureRecorder(),
            operations: PipelineOperations(transcribe: { _, _, _, _ in "Synthetic transcript for consent test." },
                notes: { _, _ in await counter.noted(); return "Must not be called" }))
        try job.start(title: "No consent", capture: CaptureSettings(engine: .none),
                      processing: ProcessingOptions(modelURL: fixture.model(), requestNotes: true))
        await job.waitForCurrentOperation()
        try job.stop()
        await job.waitForCurrentOperation()
        XCTAssertEqual(job.phase, .completed)
        XCTAssertEqual(job.meeting?.notesState, .needsConsent)
        XCTAssertTrue(job.meeting?.hasTranscript ?? false)
        let notesCalls = await counter.notes
        XCTAssertEqual(notesCalls, 0)
        let text = try await store.readText(meetingID: job.meeting!.id, filename: "notes.md")
        XCTAssertNil(text)
    }

    @MainActor
    func testRevocationCancelsInFlightNotesAndRejectsTheirResult() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let store = try MeetingStore(root: fixture.root)
        let consent = NotesConsentStore(directory: fixture.root)
        let executable = try fixture.executable("printf 'unused fixture'")
        try consent.configure(NotesProvider(name: "Fixture", executable: executable, kind: .cloudExecutable, destination: "No network test fixture"))
        try consent.approve()
        let counter = PipelineCounter()
        let job = MeetingJob(store: store, consent: consent, recorder: FixtureRecorder(),
            operations: PipelineOperations(transcribe: { _, _, _, _ in "Synthetic transcript." }, notes: { _, _ in
                await counter.noted()
                try await Task.sleep(for: .seconds(60))
                return "Must not be persisted after revocation."
            }))
        try job.start(title: "Revoke fixture", capture: CaptureSettings(engine: .none),
                      processing: ProcessingOptions(modelURL: fixture.model(), requestNotes: true))
        await job.waitForCurrentOperation()
        try job.stop()
        try await eventually { await counter.notes == 1 }
        try job.revokeNotesConsent()
        await job.waitForCurrentOperation()
        XCTAssertFalse(consent.isApproved)
        XCTAssertEqual(job.phase, .cancelled)
        XCTAssertEqual(job.meeting?.notesState, .cancelled)
        let notes = try await store.readText(meetingID: job.meeting!.id, filename: "notes.md")
        let transcript = try await store.readText(meetingID: job.meeting!.id, filename: "transcript.txt")
        XCTAssertNil(notes)
        XCTAssertEqual(transcript, "Synthetic transcript.")
    }

    @MainActor
    func testProcessingFailureDoesNotFabricateTranscriptOrNotes() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let store = try MeetingStore(root: fixture.root)
        let job = MeetingJob(store: store, consent: NotesConsentStore(directory: fixture.root), recorder: FixtureRecorder(),
            operations: PipelineOperations(transcribe: { _, _, _, _ in throw CrispyError.unavailable("synthetic whisper process failed") }))
        try job.start(title: "Error fixture", capture: CaptureSettings(engine: .none),
                      processing: ProcessingOptions(modelURL: fixture.model(), requestNotes: true))
        await job.waitForCurrentOperation()
        try job.stop()
        await job.waitForCurrentOperation()
        XCTAssertEqual(job.phase, .failed)
        XCTAssertTrue(job.status.contains("synthetic whisper process failed"))
        XCTAssertNotNil(job.meeting?.audioFilename)
        XCTAssertFalse(job.meeting?.hasTranscript ?? true)
        let notes = try await store.readText(meetingID: job.meeting!.id, filename: "notes.md")
        XCTAssertNil(notes)
    }

    @MainActor
    func testProviderFailureKeepsPreviousNotesAndTranscript() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let store = try MeetingStore(root: fixture.root)
        var meeting = try await store.create(title: "Existing notes fixture", engine: .none)
        meeting.hasTranscript = true
        meeting.phase = .completed
        try await store.writeText("Synthetic existing transcript.", meetingID: meeting.id, filename: "transcript.txt")
        try await store.writeText("Original reviewed notes.", meetingID: meeting.id, filename: "notes.md")
        try await store.save(meeting)
        let consent = NotesConsentStore(directory: fixture.root)
        let executable = try fixture.executable("exit 8")
        try consent.configure(NotesProvider(name: "Failing fixture", executable: executable, kind: .localExecutable, destination: "No network"))
        try consent.approve()
        let job = MeetingJob(store: store, consent: consent, recorder: FixtureRecorder())
        try job.generateNotes(for: meeting)
        await job.waitForCurrentOperation()
        XCTAssertEqual(job.phase, .failed)
        XCTAssertEqual(job.meeting?.notesState, .failed)
        let notes = try await store.readText(meetingID: meeting.id, filename: "notes.md")
        let transcript = try await store.readText(meetingID: meeting.id, filename: "transcript.txt")
        XCTAssertEqual(notes, "Original reviewed notes.")
        XCTAssertEqual(transcript, "Synthetic existing transcript.")
    }

    @MainActor
    func testPermissionDenialAndCaptureFailureAreVisible() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let recorder = FixtureRecorder()
        recorder.startError = CrispyError.unavailable("Synthetic permission denied")
        let job = MeetingJob(store: try MeetingStore(root: fixture.root),
            consent: NotesConsentStore(directory: fixture.root), recorder: recorder)
        try job.start(title: "Denied", capture: CaptureSettings(engine: .none), processing: ProcessingOptions())
        await job.waitForCurrentOperation()
        XCTAssertEqual(job.phase, .failed)
        XCTAssertTrue(job.status.contains("permission denied"))
        XCTAssertFalse(recorder.active)
        recorder.startError = nil
        try job.start(title: "Disconnected", capture: CaptureSettings(engine: .none), processing: ProcessingOptions())
        await job.waitForCurrentOperation()
        recorder.onFailure?("Synthetic device disconnected")
        await job.waitForCurrentOperation()
        XCTAssertFalse(recorder.active)
        XCTAssertEqual(job.phase, .failed)
        XCTAssertTrue(job.status.contains("device disconnected"))
    }

    @MainActor
    func testEnhancementIdentityMismatchIsRejected() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let job = MeetingJob(store: try MeetingStore(root: fixture.root),
            consent: NotesConsentStore(directory: fixture.root), recorder: FixtureRecorder(),
            operations: PipelineOperations(enhance: { source, _, _, _, _ in
                EnhancedAudio(url: source, report: EnhancementReport(engine: .rnnoise,
                    implementation: "Deliberately mismatched test double", processedSeconds: 0, audioSeconds: 0.2))
            }))
        try job.start(title: "Mismatch", capture: CaptureSettings(engine: .none), processing: ProcessingOptions())
        await job.waitForCurrentOperation()
        try job.stop()
        await job.waitForCurrentOperation()
        XCTAssertEqual(job.phase, .failed)
        XCTAssertTrue(job.status.contains("different engine"))
        XCTAssertNil(job.meeting?.enhancement)
    }
}
