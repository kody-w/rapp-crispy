import Foundation
import XCTest
@testable import RAPPCrispyCore

final class ConsentAndEngineTests: XCTestCase {
    @MainActor
    func testConsentStartsDisabledPersistsAndBindsToExecutableAndDestination() throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let executable = try fixture.executable("printf '## Summary\\nSynthetic provider response\\n'")
        let consent = NotesConsentStore(directory: fixture.root)
        XCTAssertFalse(consent.isApproved)
        XCTAssertThrowsError(try consent.authorize())
        try consent.configure(NotesProvider(name: "Fixture provider", executable: executable, kind: .cloudExecutable, destination: "Fixture only — no network"))
        XCTAssertFalse(consent.isApproved)
        try consent.approve()
        let authorization = try consent.authorize()
        XCTAssertTrue(NotesConsentStore(directory: fixture.root).isApproved)
        try Data("#!/bin/sh\nprintf 'changed'\n".utf8).write(to: executable)
        XCTAssertThrowsError(try consent.check(authorization)) { XCTAssertEqual($0 as? NotesConsentError, .providerChanged) }
        try consent.approve()
        try consent.revoke()
        XCTAssertFalse(consent.isApproved)
        XCTAssertFalse(NotesConsentStore(directory: fixture.root).isApproved)
        XCTAssertThrowsError(try consent.check(authorization))
    }

    @MainActor
    func testCorruptConsentNeverEnablesProviderOrBlocksLocalStorage() throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        try Data("bad config".utf8).write(to: fixture.root.appendingPathComponent("native-notes-consent.json"))
        let consent = NotesConsentStore(directory: fixture.root)
        XCTAssertNotNil(consent.warning)
        XCTAssertFalse(consent.isApproved)
        XCTAssertNoThrow(try MeetingStore(root: fixture.root))
    }

    @MainActor
    func testRealLocalFixtureHookReturnsOnlyItsActualOutputAndRejectsFailure() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let transcript = fixture.root.appendingPathComponent("transcript.txt")
        try Data("Synthetic meeting transcript.".utf8).write(to: transcript)
        let executable = try fixture.executable("""
        test "$2" = "--rappcrispy-explicit-consent"
        printf '## Summary\\n'
        cat "$1"
        """)
        let consent = NotesConsentStore(directory: fixture.root)
        try consent.configure(NotesProvider(name: "Local fixture", executable: executable, kind: .localExecutable, destination: "Local fixture stdout"))
        try consent.approve()
        let text = try await NotesRunner.generate(transcript: transcript, authorization: consent.authorize())
        XCTAssertEqual(text, "## Summary\nSynthetic meeting transcript.")
        for body in ["exit 0", "printf 'failure' >&2\nexit 7"] {
            let bad = try fixture.executable(body)
            try consent.configure(NotesProvider(name: "Failure fixture", executable: bad, kind: .localExecutable, destination: "Local only"))
            try consent.approve()
            do {
                _ = try await NotesRunner.generate(transcript: transcript, authorization: consent.authorize())
                XCTFail("Empty/nonzero provider result was accepted")
            } catch {}
        }
    }

    func testDeviceDiagnosticsDoNotConfuseDuplexHardwareWithWorkingLoopback() {
        let devices = [
            AudioDeviceInfo(id: 1, uid: "usb", name: "USB Audio", inputChannels: 2, outputChannels: 2),
            AudioDeviceInfo(id: 2, uid: "loop", name: "BlackHole 2ch", inputChannels: 2, outputChannels: 2, isDefaultInput: true),
            AudioDeviceInfo(id: 3, uid: "input-only", name: "Loopback source", inputChannels: 2, outputChannels: 0)
        ]
        let diagnostics = DeviceDiagnostics(devices: devices, permission: "fixture")
        XCTAssertEqual(diagnostics.loopbackCandidates.map(\.id), [2])
        XCTAssertEqual(DeviceDiagnostics.preferredInput(devices)?.id, 1)
        XCTAssertFalse(diagnostics.nativeVirtualMicrophoneRunning)
        XCTAssertFalse(diagnostics.farEndAudioCaptured)
        XCTAssertNil(DeviceDiagnostics.preferredInput(Array(devices.dropFirst())))
        XCTAssertNil(DeviceDiagnostics.preferredInput([
            AudioDeviceInfo(id: 4, uid: "third-party", name: "Krisp Microphone", inputChannels: 1, outputChannels: 0, isDefaultInput: true)
        ]))
    }

    func testMissingAdvancedEngineNeverFallsBackAndAppleIsCaptureOnly() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let source = fixture.root.appendingPathComponent("mic.wav")
        try Fixtures.wav(at: source)
        let enhancer = AudioEnhancer(tools: AdvancedEngineTools())
        for engine in [EnhancementEngine.rnnoise, .deepFilterNet, .appleVoiceProcessing] {
            do {
                _ = try await enhancer.enhance(source: source, selected: engine, captured: .none, directory: fixture.root)
                XCTFail("Unavailable engine \(engine) silently fell back")
            } catch {}
        }
        let original = try Data(contentsOf: source)
        let unchanged = try await enhancer.enhance(source: source, selected: .none, captured: .none, directory: fixture.root)
        XCTAssertEqual(unchanged.report.engine, .none)
        XCTAssertEqual(try Data(contentsOf: unchanged.url), original)
        let alreadyProcessed = try await enhancer.enhance(source: source, selected: .appleVoiceProcessing,
            captured: .appleVoiceProcessing, directory: fixture.root)
        XCTAssertEqual(alreadyProcessed.report.engine, .appleVoiceProcessing)
        XCTAssertNil(alreadyProcessed.report.realTimeFactor)
        XCTAssertFalse(alreadyProcessed.report.implementation.contains("RNNoise"))
        let notProcessedAgain = try await enhancer.enhance(source: source, selected: .none,
            captured: .appleVoiceProcessing, directory: fixture.root)
        XCTAssertTrue(notProcessedAgain.report.implementation.contains("Apple voice-processed capture retained"))
    }

    func testAdvancedDFNAdapterUsesFileToFileNoPostFilterAndPreservesInput() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let source = fixture.root.appendingPathComponent("mic.wav")
        try Fixtures.wav(at: source)
        // A contract fixture, NOT a denoising quality measurement or a substitute shipped engine.
        let tool = try fixture.executable("""
        if [ "$1" = "--version" ]; then printf 'deep-filter 0.5.6\\n'; exit 0; fi
        test "$#" = 3
        test "$1" = "-o"
        cp "$3" "$2/fixture-result.wav"
        """, name: "deep-filter-fixture")
        let enhancer = AudioEnhancer(tools: AdvancedEngineTools(deepFilter: tool))
        let original = try Data(contentsOf: source)
        let result = try await enhancer.enhance(source: source, selected: .deepFilterNet, captured: .none, directory: fixture.root)
        XCTAssertEqual(result.report.engine, .deepFilterNet)
        XCTAssertEqual(try AudioFiles.describe(result.url).sampleRate, 48_000)
        XCTAssertNotNil(result.report.realTimeFactor)
        XCTAssertEqual(result.report.executableSHA256?.count, 64)
        XCTAssertNotEqual(result.url, source)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".enhancement-") })
    }

    func testDifferentDeepFilterVersionIsNeverMislabeledDFN3() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let source = fixture.root.appendingPathComponent("mic.wav")
        try Fixtures.wav(at: source)
        let tool = try fixture.executable("printf 'deep-filter 0.2.0\\n'")
        do {
            _ = try await AudioEnhancer(tools: AdvancedEngineTools(deepFilter: tool))
                .enhance(source: source, selected: .deepFilterNet, captured: .none, directory: fixture.root)
            XCTFail("Different engine version was silently mislabeled")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("0.5.6"))
        }
    }

    func testRNNoiseAdapterPreservesFilterModelAnd48kPCMContract() async throws {
        let fixture = try Fixtures()
        defer { fixture.clean() }
        let source = fixture.root.appendingPathComponent("mic.wav")
        try Fixtures.wav(at: source)
        let model = fixture.root.appendingPathComponent("chosen model's path.rnnn")
        try Data("test model, not an inference model".utf8).write(to: model)
        // This executable checks invocation only; it makes no audio quality claim.
        let tool = try fixture.executable("""
        if [ "$2" = "-filters" ]; then printf ' .. arnndn A->A\\n'; exit 0; fi
        test -f model.rnnn
        test "$1" = "-nostdin"
        test "$5" = "-i"
        source="$6"
        test "$7" = "-af"
        test "$8" = "arnndn=m=model.rnnn"
        test "$9" = "-ar"
        shift 9
        test "$1" = "48000"
        test "$2" = "-ac"
        test "$3" = "1"
        test "$4" = "-c:a"
        test "$5" = "pcm_s16le"
        test "$6" = "-n"
        cp "$source" "$7"
        """)
        let result = try await AudioEnhancer(tools: AdvancedEngineTools(ffmpeg: tool, rnnoiseModel: model))
            .enhance(source: source, selected: .rnnoise, captured: .none, directory: fixture.root)
        XCTAssertEqual(result.report.engine, .rnnoise)
        XCTAssertEqual(result.report.modelSHA256?.count, 64)
        XCTAssertEqual(try AudioFiles.describe(result.url).sampleRate, 48_000)
    }
}
