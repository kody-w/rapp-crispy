import Foundation
import XCTest
@testable import RAPPCrispyCore

struct Fixtures {
    let root: URL
    init() throws {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = native.appendingPathComponent(".build/test-artifacts/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func directory(_ name: String) throws -> URL {
        let path = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    func executable(_ body: String, name: String = UUID().uuidString) throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(("#!/bin/sh\nset -eu\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    func model() throws -> URL {
        let file = root.appendingPathComponent("fixture-model-not-for-inference.bin")
        try Data([1, 2, 3]).write(to: file)
        return file
    }
    static func wav(at url: URL, rate: Int = 48_000, seconds: Double = 0.2, amplitude: Double = 0.15) throws {
        let count = Int(Double(rate) * seconds)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); u32(UInt32(36 + count * 2)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(count * 2))
        for frame in 0..<count {
            let sample = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(rate)) * amplitude * Double(Int16.max))
            u16(UInt16(bitPattern: sample))
        }
        try data.write(to: url)
    }
}

@MainActor
final class FixtureRecorder: MeetingRecording {
    var onFailure: ((String) -> Void)?
    var starts = 0
    var stops = 0
    var cancels = 0
    var delay: Duration = .zero
    var active = false
    var startError: Error?
    var stopError: Error?
    private var url: URL?
    private var engine: EnhancementEngine = .none

    func start(in directory: URL, settings: CaptureSettings) async throws -> RecordingDetails {
        starts += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        if let startError { throw startError }
        url = directory.appendingPathComponent("mic.wav")
        try Fixtures.wav(at: url!)
        active = true
        engine = settings.engine == .appleVoiceProcessing ? .appleVoiceProcessing : .none
        return RecordingDetails(deviceName: "Synthetic test microphone (not a device)", audioFilename: "mic.wav", captureEngine: engine)
    }
    func stop() async throws -> RecordedAudio {
        stops += 1
        active = false
        if let stopError { throw stopError }
        guard let url else { throw CrispyError.noActiveRecording }
        return RecordedAudio(url: url, duration: 0.2, captureEngine: engine)
    }
    func cancel() async throws -> RecordedAudio? {
        cancels += 1
        active = false
        guard let url else { return nil }
        return RecordedAudio(url: url, duration: 0.2, captureEngine: engine)
    }
}

actor PipelineCounter {
    var transcriptions = 0
    var notes = 0
    func transcribed() { transcriptions += 1 }
    func noted() { notes += 1 }
}

@MainActor
func eventually(_ condition: @escaping @MainActor () async -> Bool,
                file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Condition did not become true", file: file, line: line)
}
