import Foundation

/// Reads Golem's note confirmations out of a reply. Foundation-only, so it can be tested alone.
enum GolemNotes {
    struct Found: Equatable { var added: [String] = []; var deleted: [String] = [] }

    /// Lines like "Noted: buy filters" (markdown emphasis, bullets, quotes or a 📝 allowed) add
    /// a note; "Deleted note: buy filters" removes one.
    static func parse(_ text: String) -> Found {
        var found = Found()
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "-*•>_📝✅".contains(first) || first.isWhitespace { line.removeFirst() }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            for (prefix, deleting) in [("deleted note", true), ("noted", false)] {
                guard line.lowercased().hasPrefix(prefix) else { continue }
                var rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                guard let colon = rest.first, colon == ":" || colon == "：" else { continue }
                rest = String(rest.dropFirst()).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_\"“”")))
                guard !rest.isEmpty, rest.count <= 1000 else { break }
                if deleting { found.deleted.append(rest) } else { found.added.append(rest) }
                break
            }
        }
        return found
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
    static func same(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }
    /// A deletion that names part of the note ("the filters note").
    static func matches(_ note: String, _ request: String) -> Bool {
        let r = normalized(request)
        return r.count >= 4 && normalized(note).contains(r)
    }
}
