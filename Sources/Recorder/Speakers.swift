import Foundation

extension Transcript {
    private static let nameLimit = 40

    /// The owner of the recording: its mic track. Older transcripts call it "Me". Only the other side is renamed.
    static func isOwner(_ speaker: String) -> Bool { speaker == "You" || speaker == "Me" }

    /// What may go into a speaker line: no `*` or backtick (they are the label's own marks), one line, one space between
    /// words, at most 40 characters.
    static func cleanSpeakerName(_ raw: String) -> String {
        let words = raw.filter { $0 != "*" && $0 != "`" }.split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
    }

    /// Why a cleaned `name` cannot replace `old`, or nil when it can. Case is ignored, so "fran" is not "Fran" twice.
    static func speakerNameProblem(_ name: String, replacing old: String, in markdown: String) -> String? {
        if name.isEmpty { return "Enter a name." }
        if name.lowercased() == "you" || name.lowercased() == "me" { return "That is you." }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        let others = lines[..<(foot(lines) ?? lines.count)].compactMap { $0.wholeMatch(of: /\*\*(.+?)\*\* `(\d+):(\d+):(\d+)`/).map { String($0.1) } }.filter { $0 != old }
        return others.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? "Another speaker has that name." : nil
    }

    /// The transcript with the speaker `old` called `raw` (cleaned), or nil when the name is refused or nothing changes.
    /// Only a speaker line that wholly matches is rewritten, from its own time stamp. Of the foot only "repeated from <old>."
    /// follows, the one place the note names a speaker. Header, summary and passages are never touched.
    static func renaming(_ old: String, to raw: String, in markdown: String) -> String? {
        let name = cleanSpeakerName(raw)
        guard !isOwner(old), name != old, speakerNameProblem(name, replacing: old, in: markdown) == nil else { return nil }
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        let rule = foot(lines)
        for i in lines.indices {
            if i < rule ?? lines.count {
                if let match = lines[i].wholeMatch(of: /\*\*(.+?)\*\* `(\d+):(\d+):(\d+)`/), match.1 == old { lines[i] = "**\(name)** `\(match.2):\(match.3):\(match.4)`" }
            } else if i > rule ?? lines.count {
                lines[i] = Substring(lines[i].replacingOccurrences(of: "repeated from \(old).", with: "repeated from \(name)."))
            }
        }
        let text = lines.joined(separator: "\n")
        return text == markdown ? nil : text
    }

    static func speakerSelfTest() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        func split(_ text: String) -> [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
        let note = "Struck from the record: 2 fillers and 1 line repeated from Them. Over 3 minutes the model heard \u{201C}Thank you.\u{201D} It was not entered."
        let text = [
            "# Them and Me", "", "whisper-large, language tr, transcribed Oct 31, 2026", "",
            "## Summary", "", "- **Them** `00:00:03` said Them is late.", "",
            "**You** `00:00:03`", "", "Them, is that you?", "",
            "**Them** `00:01:05`", "", "Evet, Them burada. **Them** `00:00:09`", "",
            "**Them** `01:02:03`", "", "Bitti.", "",
            "---", "", note, "",
        ].joined(separator: "\n")

        let renamed = renaming("Them", to: "Fran", in: text) ?? ""
        let (before, after) = (split(text), split(renamed))
        let changed = before.indices.filter { before[$0] != after[$0] }
        expect(before.count == after.count && changed == [12, 16, 22], "only the two speaker lines and the note change: \(changed)")
        expect(after[12] == "**Fran** `00:01:05`" && after[16] == "**Fran** `01:02:03`", "the time stamp is kept: \(after[12]) \(after[16])")
        expect(after[22] == note.replacingOccurrences(of: "repeated from Them.", with: "repeated from Fran."), "the note follows: \(after[22])")
        expect(after[0] == before[0] && after[2] == before[2] && after[6] == before[6] && after[8] == before[8] && after[10] == before[10] && after[14] == before[14], "header, summary, passages and the owner stay")
        expect(parse(renamed).map(\.speaker) == ["You", "Fran", "Fran"], "parse reads the new name back: \(parse(renamed).map(\.speaker))")
        expect(plainText(title: "t", date: Date(timeIntervalSince1970: 0), blocks: parse(renamed)).contains("Fran (00:01:05)"), "Copy uses the new name")
        expect(footnote(renamed) == note.replacingOccurrences(of: "repeated from Them.", with: "repeated from Fran."), "the foot is still found after a rename")
        let again = renaming("Fran", to: "Francesca", in: renamed)
        expect(again.map(parse)?.map(\.speaker) == ["You", "Francesca", "Francesca"], "a second rename works")
        expect(renaming("Them", to: "Fran", in: renamed) == nil, "a speaker that is not there changes nothing")

        // Names are cleaned: marks, whitespace, length.
        expect(cleanSpeakerName("  Şebnem   Çağlar\n İnci ") == "Şebnem Çağlar İnci", "Turkish letters and spaces: \(cleanSpeakerName("  Şebnem   Çağlar\n İnci "))")
        expect(cleanSpeakerName("**Fran** `00:00:09`\tX") == "Fran 00:00:09 X", "marks removed: \(cleanSpeakerName("**Fran** `00:00:09`\tX"))")
        let long = cleanSpeakerName(String(repeating: "Abcdefgh ", count: 10))
        expect(long.count <= 40 && !long.hasSuffix(" "), "cut to 40, no trailing space: \(long.count)")
        let tricky = renaming("Them", to: "Fran\n\n**You** `00:00:00`\n`x`", in: text) ?? ""
        expect(split(tricky).count == before.count && parse(tricky).map(\.speaker) == ["You", "Fran You 00:00:00 x", "Fran You 00:00:00 x"], "a pasted label does not add a line: \(parse(tricky).map(\.speaker))")
        expect(renaming("Them", to: "Ağabey", in: text).map { parse($0).last?.speaker } == "Ağabey", "a Turkish name")

        // Refused: empty, you, the other speaker; and unchanged.
        for bad in ["", "   ", "***", "``", "You", "me", "YOU"] { expect(renaming("Them", to: bad, in: text) == nil, "\u{201C}\(bad)\u{201D} is refused") }
        expect(speakerNameProblem("", replacing: "Them", in: text) != nil && speakerNameProblem("you", replacing: "Them", in: text) != nil, "a reason is given")
        expect(renaming("Them", to: "Them", in: text) == nil, "the same name changes nothing")
        expect(renaming("Them", to: "them", in: text).map { $0.contains("**them** `00:01:05`") } == true, "only the case changes: allowed")
        let three = text.replacingOccurrences(of: "**Them** `01:02:03`", with: "**Fran** `01:02:03`")
        expect(renaming("Them", to: "fran", in: three) == nil && speakerNameProblem("Fran", replacing: "Them", in: three) != nil, "another speaker's name is refused, case ignored")
        expect(renaming("You", to: "Ali", in: text) == nil && renaming("Me", to: "Ali", in: text) == nil, "the owner is not renamed")

        // A legacy file says Me.
        let legacy = "# t\n\nm\n\n**Me** `00:00:01`\n\nHi.\n\n**Them** `00:00:02`\n\nHello.\n"
        expect(renaming("Them", to: "Fran", in: legacy) == "# t\n\nm\n\n**Me** `00:00:01`\n\nHi.\n\n**Fran** `00:00:02`\n\nHello.\n", "a legacy Me file: Them renamed, Me stays")
        expect(renaming("Them", to: "Me", in: legacy) == nil && renaming("Me", to: "Fran", in: legacy) == nil && isOwner("Me") && isOwner("You") && !isOwner("Them"), "Me is the owner too")

        // A --- between passages is text, not the foot; a passage that says "repeated from Them." is not the note.
        let typed = ["**You** `00:00:01`", "", "---", "", "x repeated from Them.", "", "**Them** `00:00:02`", "", "y", ""].joined(separator: "\n")
        expect(renaming("Them", to: "Fran", in: typed) == typed.replacingOccurrences(of: "**Them**", with: "**Fran**"), "only the label changes in a file with a typed rule")
        expect(renaming("Them", to: "Fran", in: "No speech was found.\n") == nil, "no speaker lines, no change")
        return failures
    }
}
