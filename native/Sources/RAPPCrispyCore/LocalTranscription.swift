import Foundation
import RAPPDesktopSupport

public enum LocalTranscription {
    public static func transcribe(audio: URL, model: URL, directory: URL,
                                  dictionary: PersonalDictionary,
                                  progress: @Sendable (Double) async -> Void = { _ in }) async throws -> String {
        try Task.checkCancellation()
        guard FileManager.default.isReadableFile(atPath: model.path) else {
            throw CrispyError.unavailable("Download and select a verified speech model in Settings. Audio has been kept locally.")
        }
        _ = try RuntimeTools.executable(named: "whisper-cli")
        let work = directory.appendingPathComponent(".transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let speech = work.appendingPathComponent("speech.wav")
        try await AudioFiles.convertToWAV(source: audio, destination: speech)
        let chunks = try await AudioFiles.splitWAV(speech, into: work.appendingPathComponent("chunks"))
        var text: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            do {
                text.append(try await SpeechTranscriber.transcribe(audioURL: chunk, modelURL: model, language: "en"))
            } catch DesktopSupportError.noSpeech {
                // Silence is a real chunk outcome, unlike a failed process or missing output.
                text.append("")
            }
            await progress(Double(index + 1) / Double(chunks.count))
        }
        try Task.checkCancellation()
        return try dictionary.apply(to: text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
}
