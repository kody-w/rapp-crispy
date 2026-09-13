import Foundation

public enum NativeCommand: Equatable, Sendable {
    case prepareRecording(name: String, seconds: Int?, requestScreen: Bool)
    case history
    case meeting(String)
    case diagnostics
    case models

    public static func parse(_ url: URL) throws -> NativeCommand {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "rappcrispy", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else {
            throw CrispyError.invalidCommand("invalid URL")
        }
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else {
                throw CrispyError.invalidCommand("duplicate or missing parameter")
            }
            query[item.name] = value
        }
        switch parts.host {
        case "prepare-recording":
            guard Set(query.keys).isSubset(of: ["name", "seconds", "screen"]) else {
                throw CrispyError.invalidCommand("unknown recording parameter")
            }
            let name = query["name"] ?? ""
            guard name.count <= 200, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CrispyError.invalidCommand("invalid meeting title")
            }
            var seconds: Int?
            if let value = query["seconds"] {
                guard let duration = Int(value), (1...86_400).contains(duration) else {
                    throw CrispyError.invalidCommand("duration must be 1–86400 seconds")
                }
                seconds = duration
            }
            guard query["screen"] == nil || ["true", "false"].contains(query["screen"]!) else {
                throw CrispyError.invalidCommand("screen must be true or false")
            }
            return .prepareRecording(name: name, seconds: seconds, requestScreen: query["screen"] == "true")
        case "history":
            guard query.isEmpty else { throw CrispyError.invalidCommand("history takes no parameters") }
            return .history
        case "meeting":
            guard query.count == 1, let id = query["id"], MeetingStore.validID(id) else {
                throw CrispyError.invalidCommand("invalid meeting identifier")
            }
            return .meeting(id)
        case "diagnostics":
            guard query.isEmpty else { throw CrispyError.invalidCommand("diagnostics takes no parameters") }
            return .diagnostics
        case "models":
            guard query.isEmpty else { throw CrispyError.invalidCommand("models takes no parameters") }
            return .models
        default:
            throw CrispyError.invalidCommand("only prepare-recording, history, meeting, diagnostics and models are supported; URLs never start capture")
        }
    }
}
