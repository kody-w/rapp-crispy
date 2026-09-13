import Foundation

public struct PersonalDictionary: Sendable {
    public let terms: [String]
    public let substitutions: [(heard: String, meant: String)]

    public init(contents: String) {
        var terms: [String] = []
        var substitutions: [(String, String)] = []
        for raw in contents.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let divider = line.range(of: "=>") {
                let heard = String(line[..<divider.lowerBound]).trimmingCharacters(in: .whitespaces)
                let meant = String(line[divider.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !heard.isEmpty {
                    substitutions.append((heard, meant))
                    terms.append(meant)
                }
            } else {
                terms.append(line)
            }
        }
        self.terms = terms
        self.substitutions = substitutions.sorted { $0.0.count > $1.0.count }
    }

    public static func load(root: URL = MeetingStore.defaultRoot) throws -> PersonalDictionary {
        let environment = ProcessInfo.processInfo.environment
        let candidates: [URL]
        if let explicit = environment["CRISPY_DICT"], !explicit.isEmpty {
            candidates = [URL(fileURLWithPath: explicit)]
        } else {
            candidates = [
                root.appendingPathComponent("dictionary.txt"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rappvoice/dictionary.txt")
            ]
        }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return PersonalDictionary(contents: "")
        }
        return PersonalDictionary(contents: try String(contentsOf: url, encoding: .utf8))
    }

    public var weightedPrompt: String {
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }.map { "\($0). \($0)." }.joined(separator: " ")
    }

    public func apply(to original: String) throws -> String {
        var text = original
        for rule in substitutions { text = try replace(rule.heard, with: rule.meant, in: text) }
        for term in terms where !term.isEmpty { text = try replace(term, with: term, in: text) }
        return text
    }

    private func replace(_ term: String, with replacement: String, in text: String) throws -> String {
        var pattern = NSRegularExpression.escapedPattern(for: term)
        if term.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) == true { pattern = "\\b" + pattern }
        if term.unicodeScalars.last.map(CharacterSet.alphanumerics.contains) == true { pattern += "\\b" }
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
