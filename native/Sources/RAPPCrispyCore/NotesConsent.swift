import Combine
import CryptoKit
import Foundation
import RAPPDesktopSupport

public enum NotesProviderKind: String, Codable, CaseIterable, Sendable {
    case localExecutable
    case cloudExecutable
}

public struct NotesProvider: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var executable: URL
    public var kind: NotesProviderKind
    public var destination: String

    public init(id: UUID = UUID(), name: String, executable: URL, kind: NotesProviderKind, destination: String) {
        self.id = id
        self.name = name
        self.executable = executable.standardizedFileURL
        self.kind = kind
        self.destination = destination
    }

    public func fingerprint() throws -> String {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path),
              (try executable.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw NotesConsentError.unavailableExecutable
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotesConsentError.missingDestination
        }
        var hash = SHA256()
        hash.update(data: Data("\(id.uuidString)\n\(name)\n\(executable.path)\n\(kind.rawValue)\n\(destination)\n".utf8))
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum NotesConsentError: LocalizedError, Equatable {
    case missingProvider, consentRequired, providerChanged, unavailableExecutable, missingDestination, revoked

    public var errorDescription: String? {
        switch self {
        case .missingProvider: return "Notes are disabled. Select a provider; local audio and transcription still work."
        case .consentRequired: return "Notes are disabled until you explicitly approve this provider and its destination."
        case .providerChanged: return "The notes executable or configuration changed after approval. Review it and give fresh consent."
        case .unavailableExecutable: return "The selected notes provider is not an executable regular file."
        case .missingDestination: return "Name the provider and the destination that will receive this transcript."
        case .revoked: return "Notes consent was revoked. No new result was saved. Content already sent cannot be recalled."
        }
    }
}

public struct NotesAuthorization: Sendable {
    public let provider: NotesProvider
    public let fingerprint: String
    public let revision: UUID
}

@MainActor
public final class NotesConsentStore: ObservableObject {
    private struct Receipt: Codable {
        var fingerprint: String
        var approvedAt: Date
    }
    private struct State: Codable {
        var provider: NotesProvider?
        var receipt: Receipt?
    }

    @Published public private(set) var provider: NotesProvider?
    @Published public private(set) var warning: String?
    @Published public private(set) var revision = UUID()
    private var receipt: Receipt?
    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("native-notes-consent.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
                provider = state.provider
                receipt = state.receipt
            } catch {
                warning = "Could not read notes settings: \(error.localizedDescription). Notes remain disabled."
            }
        }
    }

    public var status: String {
        do {
            let auth = try authorize()
            return "Approved: \(auth.provider.name) → \(auth.provider.destination). Notes run only when you request them."
        } catch {
            return error.localizedDescription
        }
    }

    public var isApproved: Bool { (try? authorize()) != nil }

    public func configure(_ provider: NotesProvider?) throws {
        self.provider = provider
        receipt = nil
        revision = UUID()
        try persist()
    }

    public func approve() throws {
        guard let provider else { throw NotesConsentError.missingProvider }
        receipt = Receipt(fingerprint: try provider.fingerprint(), approvedAt: Date())
        revision = UUID()
        do {
            try persist()
        } catch {
            receipt = nil
            throw error
        }
    }

    public func revoke() throws {
        receipt = nil
        revision = UUID()
        try persist()
    }

    public func authorize() throws -> NotesAuthorization {
        guard let provider else { throw NotesConsentError.missingProvider }
        guard let receipt else { throw NotesConsentError.consentRequired }
        guard try provider.fingerprint() == receipt.fingerprint else { throw NotesConsentError.providerChanged }
        return NotesAuthorization(provider: provider, fingerprint: receipt.fingerprint, revision: revision)
    }

    public func check(_ authorization: NotesAuthorization) throws {
        let current = try authorize()
        guard current.revision == authorization.revision,
              current.fingerprint == authorization.fingerprint else { throw NotesConsentError.revoked }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(State(provider: provider, receipt: receipt))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        warning = nil
    }
}

public enum NotesRunner {
    public static func generate(transcript: URL, authorization: NotesAuthorization) async throws -> String {
        try Task.checkCancellation()
        guard try authorization.provider.fingerprint() == authorization.fingerprint else {
            throw NotesConsentError.providerChanged
        }
        let result = try await ProcessRunner.run(
            executable: authorization.provider.executable,
            arguments: [transcript.path, "--rappcrispy-explicit-consent"],
            directory: transcript.deletingLastPathComponent()
        )
        try Task.checkCancellation()
        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CrispyError.emptyNotes
        }
        return result.stdout
    }
}
