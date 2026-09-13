import AVFoundation
import Foundation
import XCTest
@testable import RAPPCrispyCore

final class AudioAndStorageTests: XCTestCase {
    func testGeneratedWAVResamplesToWhisperPCMAndChunksWithoutLosingFrames() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let source = fixture.root.appendingPathComponent("source.wav")
        let destination = fixture.root.appendingPathComponent("speech.wav")
        try Fixtures.wav(at: source, rate: 48_000, seconds: 0.5)
        try await AudioFiles.convertToWAV(source: source, destination: destination)
        let info = try AudioFiles.describe(destination)
        XCTAssertEqual(info.sampleRate, 16_000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.duration, 0.5, accuracy: 0.001)
        let file = try AVAudioFile(forReading: destination)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        let header = try Data(contentsOf: destination)
        XCTAssertEqual(String(data: header.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: header.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        let chunks = try await AudioFiles.splitWAV(destination, into: fixture.root.appendingPathComponent("chunks"), seconds: 0.2)
        XCTAssertEqual(chunks.count, 3)
        let total = try chunks.map { try AudioFiles.describe($0).frames }.reduce(0, +)
        XCTAssertEqual(total, info.frames)
    }

    func testEmptyAndCorruptAudioAreErrorsNotSuccess() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let empty = fixture.root.appendingPathComponent("empty.wav")
        try Fixtures.wav(at: empty, seconds: 0)
        XCTAssertThrowsError(try AudioFiles.describe(empty))
        let bad = fixture.root.appendingPathComponent("invalid.wav")
        try Data("not a wave".utf8).write(to: bad)
        do {
            try await AudioFiles.convertToWAV(source: bad, destination: fixture.root.appendingPathComponent("out.wav"))
            XCTFail("Corrupt audio was accepted")
        } catch {}
    }

    func testMetricsKeepCLISignAndRealTimeFactorSemantics() {
        XCTAssertEqual(AudioMetrics.rmsDB([0.1, -0.1])!, -20, accuracy: 0.00001)
        XCTAssertNil(AudioMetrics.rmsDB([]))
        XCTAssertEqual(AudioMetrics.noiseReductionDB(inputGapDB: -25, outputGapDB: -53.1), 28.1, accuracy: 0.001)
        XCTAssertEqual(AudioMetrics.speechRetentionDB(inputSpeechDB: -10, outputSpeechDB: -13.9), -3.9, accuracy: 0.001)
        XCTAssertEqual(EnhancementReport(engine: .rnnoise, implementation: "fixture", processedSeconds: 0.14, audioSeconds: 10).realTimeFactor!, 0.014, accuracy: 0.0001)
        XCTAssertNil(EnhancementReport(engine: .appleVoiceProcessing, implementation: "capture", processedSeconds: nil, audioSeconds: 10).realTimeFactor)
    }

    func testLegacyMeetingsLoadWithoutBeingRewritten() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let store = try MeetingStore(root: fixture.root)
        let id = "2026-01-01_010101_existing"
        let directory = try await store.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let audio = directory.appendingPathComponent("mic.wav")
        try Fixtures.wav(at: audio)
        let original = try Data(contentsOf: audio)
        try Data("Synthetic old transcript".utf8).write(to: directory.appendingPathComponent("transcript.txt"))
        let meeting = try await store.load(id)
        XCTAssertEqual(meeting.phase, .legacy)
        XCTAssertTrue(meeting.hasTranscript)
        XCTAssertNil(meeting.enhancement)
        XCTAssertNil(meeting.captureEngine)
        XCTAssertEqual(try Data(contentsOf: audio), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-meeting.json").path))
    }

    func testTextRevisionsAndInterruptedJobReporting() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let store = try MeetingStore(root: fixture.root)
        let meeting = try await store.create(title: "../../Demo", engine: .none)
        XCTAssertTrue(MeetingStore.validID(meeting.id))
        try await store.writeText("first", meetingID: meeting.id, filename: "transcript.txt")
        try await store.writeText("second", meetingID: meeting.id, filename: "transcript.txt")
        try await store.writeText("third", meetingID: meeting.id, filename: "transcript.txt")
        let current = try await store.readText(meetingID: meeting.id, filename: "transcript.txt")
        XCTAssertEqual(current, "third")
        let directory = try await store.directory(for: meeting.id)
        let revisions = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent(".revisions"), includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(try revisions.map { try String(contentsOf: $0) }), ["first", "second"])
        let inactive = try await store.list()
        let active = try await store.list(activeID: meeting.id)
        XCTAssertEqual(inactive.meetings.first?.phase, .interrupted)
        XCTAssertEqual(active.meetings.first?.phase, .preparing)
        let persisted = try await store.load(meeting.id)
        XCTAssertEqual(persisted.phase, .preparing, "Listing must not rewrite history")
    }

    func testTraversalSymlinksAndCorruptMetadataAreNotSilentlyAccepted() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let store = try MeetingStore(root: fixture.root)
        do { _ = try await store.directory(for: "../outside"); XCTFail("Traversal accepted") } catch {}
        let meeting = try await store.create(title: "safe", engine: .none)
        let directory = try await store.directory(for: meeting.id)
        let other = try fixture.directory("outside")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("transcript.txt"),
                                                   withDestinationURL: other.appendingPathComponent("private.txt"))
        do { _ = try await store.readText(meetingID: meeting.id, filename: "transcript.txt"); XCTFail("Symlink accepted") } catch {}
        try Data("not json".utf8).write(to: directory.appendingPathComponent("native-meeting.json"))
        let listing = try await store.list()
        XCTAssertTrue(listing.meetings.isEmpty)
        XCTAssertEqual(listing.issues.count, 1)
    }

    func testDictionaryPreservesCanonicalRewritesAndNoFuzzyMatching() throws {
        let dictionary = PersonalDictionary(contents: """
        # personal terms
        OpenRappter
        Kody Wildflower
        C++
        F#
        GPT-4
        Open Raptor => OpenRappter
        price => $amount\\literal
        """)
        XCTAssertEqual(try dictionary.apply(to: "we use open raptor and c++ and f# with gpt-4"),
                       "we use OpenRappter and C++ and F# with GPT-4")
        XCTAssertEqual(try dictionary.apply(to: "a velociraptor is not a term"), "a velociraptor is not a term")
        XCTAssertEqual(try dictionary.apply(to: "price"), "$amount\\literal")
        XCTAssertTrue(dictionary.weightedPrompt.contains("OpenRappter. OpenRappter."))
    }
}
