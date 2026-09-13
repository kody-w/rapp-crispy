import Foundation
import Darwin

public actor MeetingStore {
    public nonisolated let root: URL
    public nonisolated let meetingsDirectory: URL
    private let manager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["CRISPY_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rappcrispy", isDirectory: true)
    }

    public init(root: URL = MeetingStore.defaultRoot) throws {
        self.root = root.standardizedFileURL
        meetingsDirectory = root.appendingPathComponent("meetings", isDirectory: true).standardizedFileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try manager.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    }

    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.hasPrefix(".") &&
        !id.contains("/") && !id.contains("\\") && !id.contains("\0") &&
        id.utf8.count <= 240
    }

    public func directory(for id: String) throws -> URL {
        guard Self.validID(id) else { throw CrispyError.invalidMeetingID }
        let url = meetingsDirectory.appendingPathComponent(id, isDirectory: true)
        try rejectSymbolicLink(url)
        let expected = meetingsDirectory.resolvingSymlinksInPath().appendingPathComponent(id).standardizedFileURL
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == expected.path else {
            throw CrispyError.unsafePath(id)
        }
        return url
    }

    public func fileURL(meetingID: String, filename: String) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else {
            throw CrispyError.unsafePath(filename)
        }
        let directory = try directory(for: meetingID)
        let url = directory.appendingPathComponent(filename)
        try rejectSymbolicLink(url)
        guard url.resolvingSymlinksInPath().standardizedFileURL.path ==
                directory.resolvingSymlinksInPath().appendingPathComponent(filename).standardizedFileURL.path else {
            throw CrispyError.unsafePath(filename)
        }
        return url
    }

    public func create(title: String, engine: EnhancementEngine, date: Date = Date()) throws -> Meeting {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let slug = String(title.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "-"
        }.joined().prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let id = formatter.string(from: date) + (slug.isEmpty ? "" : "_\(slug)") + "_" + UUID().uuidString.prefix(8)
        let meeting = Meeting(id: id, title: String(title.prefix(200)).isEmpty ? "Untitled meeting" : String(title.prefix(200)),
                              createdAt: date, engine: engine)
        let directory = try directory(for: id)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        try save(meeting)
        return meeting
    }

    public func save(_ meeting: Meeting) throws {
        let url = try fileURL(meetingID: meeting.id, filename: "native-meeting.json")
        try encoder.encode(meeting).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func load(_ id: String) throws -> Meeting {
        let directory = try directory(for: id)
        let metadata = try fileURL(meetingID: id, filename: "native-meeting.json")
        if manager.fileExists(atPath: metadata.path) {
            var meeting = try decoder.decode(Meeting.self, from: Data(contentsOf: metadata))
            guard meeting.schemaVersion == 1, meeting.id == id else {
                throw CrispyError.unavailable("Unsupported or mismatched meeting metadata in \(id). Original files were not changed.")
            }
            for filename in [meeting.audioFilename, meeting.enhancedAudioFilename, meeting.screenFilename].compactMap({ $0 }) {
                _ = try fileURL(meetingID: id, filename: filename)
            }
            if meeting.audioFilename == nil {
                let recovery = try fileURL(meetingID: id, filename: "microphone.caf")
                if manager.fileExists(atPath: recovery.path) { meeting.audioFilename = "microphone.caf" }
            }
            return meeting
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
        guard values.isDirectory == true else { throw CrispyError.invalidMeetingID }
        var meeting = Meeting(id: id, title: id, createdAt: values.creationDate ?? .distantPast,
                              phase: .legacy, engine: .none)
        for filename in ["mic.wav", "mic.voiceprocessed.wav", "microphone.caf"] {
            if manager.fileExists(atPath: try fileURL(meetingID: id, filename: filename).path) {
                meeting.audioFilename = filename
                break
            }
        }
        if manager.fileExists(atPath: try fileURL(meetingID: id, filename: "mic.denoised.wav").path) {
            meeting.enhancedAudioFilename = "mic.denoised.wav"
        }
        meeting.hasTranscript = manager.fileExists(atPath: try fileURL(meetingID: id, filename: "transcript.txt").path)
        let notes = try readText(meetingID: id, filename: "notes.md")
        meeting.notesState = notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? .completed : .disabled
        if manager.fileExists(atPath: try fileURL(meetingID: id, filename: "screen.mov").path) {
            meeting.screenFilename = "screen.mov"
        }
        meeting.deviceName = try readText(meetingID: id, filename: "device.txt")?.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.message = "Legacy meeting — original files preserved. The engine used by this recording is not recorded in legacy metadata."
        return meeting
    }

    public func list(activeID: String? = nil) throws -> MeetingListing {
        let directories = try manager.contentsOfDirectory(at: meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var meetings: [Meeting] = []
        var issues: [String] = []
        for directory in directories {
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true else { continue }
                guard values.isSymbolicLink != true else { throw CrispyError.unsafePath(directory.lastPathComponent) }
                var meeting = try load(directory.lastPathComponent)
                if meeting.id != activeID && meeting.phase.isWorking {
                    meeting.phase = .interrupted
                    meeting.message = "The previous job was interrupted. Existing audio, transcripts and notes have been kept; processing was not resumed automatically."
                }
                meetings.append(meeting)
            } catch {
                issues.append("\(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return MeetingListing(meetings: meetings.sorted { $0.createdAt > $1.createdAt }, issues: issues)
    }

    public func readText(meetingID: String, filename: String) throws -> String? {
        let url = try fileURL(meetingID: meetingID, filename: filename)
        guard manager.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func writeText(_ text: String, meetingID: String, filename: String) throws {
        guard ["transcript.txt", "notes.md", "device.txt"].contains(filename) else {
            throw CrispyError.unsafePath(filename)
        }
        let url = try fileURL(meetingID: meetingID, filename: filename)
        if manager.fileExists(atPath: url.path) {
            let revisions = try directory(for: meetingID).appendingPathComponent(".revisions", isDirectory: true)
            try rejectSymbolicLink(revisions)
            guard revisions.resolvingSymlinksInPath().deletingLastPathComponent().path ==
                    url.deletingLastPathComponent().resolvingSymlinksInPath().path else {
                throw CrispyError.unsafePath(revisions.path)
            }
            if !manager.fileExists(atPath: revisions.path) {
                try manager.createDirectory(at: revisions, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            }
            try manager.copyItem(at: url, to: revisions.appendingPathComponent("\(UUID().uuidString)-\(filename)"))
        }
        try Data(text.utf8).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        if result == 0 {
            if information.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw CrispyError.unsafePath(url.lastPathComponent)
            }
        } else if errno != ENOENT {
            throw CrispyError.unavailable("Could not inspect \(url.lastPathComponent) safely (errno \(errno)).")
        }
    }
}
