import Foundation

extension Transcript {
    /// How Find matches, and so how Replace does: case and accents ignored.
    static let findOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The transcript with `term` replaced in the passages, and how many were. Only passage text changes: the header,
    /// anything before the first speaker line (a summary), the speaker and time lines and the foot stay as they are.
    static func replacing(_ term: String, with new: String, in markdown: String) -> (text: String, count: Int) {
        let label = /\*\*(.+?)\*\* `(\d+):(\d+):(\d+)`/
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard !term.isEmpty, let first = lines.firstIndex(where: { $0.wholeMatch(of: label) != nil }) else { return (markdown, 0) }
        let new = new.components(separatedBy: .newlines).joined(separator: " ")  // a pasted newline must not start a line of the file
        var count = 0
        // ponytail: per line, while Find joins a passage's lines; Kagu writes a passage on one line, so only a hand-edited
        // file with a passage over two lines could show a match that is not replaced.
        for i in first..<(foot(lines) ?? lines.count) where !lines[i].isEmpty && lines[i].wholeMatch(of: label) == nil {
            var out = "", rest = lines[i]
            while let range = rest.range(of: term, options: findOptions) {
                out += rest[..<range.lowerBound] + new
                rest = rest[range.upperBound...]
                count += 1
            }
            if rest.startIndex != lines[i].startIndex { lines[i] = Substring(out + rest) }
        }
        return (lines.joined(separator: "\n"), count)
    }

    static func replaceSelfTest() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        let note = "Struck from the record: 2 fillers."
        let text = [
            "# Angra Mayun", "", "whisper-large, language tr, transcribed Oct 31, 2026", "",
            "## Summary", "", "- Angra Mayun came up.", "",
            "**You** `00:00:03`", "", "Angra Mayun'u anlattı. angra mayun, ANGRA MAYUN.", "",
            "**Them** `00:01:05`", "", "İstanbul'da Mayun yok.", "Angra Mayun", "",
            "---", "", "Angra Mayun is in the " + note, "",
        ].joined(separator: "\n")

        let all = replacing("Angra Mayun", with: "Angra Mainyu", in: text)
        let (before, after) = (text.split(separator: "\n", omittingEmptySubsequences: false), all.text.split(separator: "\n", omittingEmptySubsequences: false))
        let changed = before.indices.filter { before[$0] != after[$0] }
        expect(all.count == 4 && before.count == after.count && changed == [10, 15], "Replace All touches only passage lines, counted per match: \(all.count) \(changed)")
        expect(after[10] == "Angra Mainyu'u anlattı. Angra Mainyu, Angra Mainyu.", "case-insensitive hits all become the replacement: \(after[10])")
        expect(after[0] == before[0] && after[6] == before[6] && after[8] == before[8] && after[12] == before[12] && after[17...] == before[17...], "header, summary, labels and foot stay")

        let turkish = replacing("istanbul", with: "Ankara", in: text)
        expect(turkish.count == 1 && turkish.text.contains("Ankara'da Mayun yok."), "an accent-insensitive match (İ for i): \(turkish.count)")
        let dotless = replacing("ANLATTI", with: "dedi", in: text)
        expect(dotless.text.contains("Angra Mayun'u anlattı.") && dotless.count == 0, "dotless ı is its own letter, not an accented i: Find does not match it either")
        expect(replacing("anlattı", with: "dedi", in: text).text.contains("Angra Mayun'u dedi."), "a Turkish word is replaced whole")
        expect(replacing("Mayun", with: "", in: text).text.contains("Angra 'u anlattı. angra , ANGRA ."), "an empty replacement deletes")

        for term in ["Summary", "whisper-large", "00:00:03", "**You**", "Struck", "Angra Mayun is in"] {
            expect(replacing(term, with: "Z", in: text) == (text, 0), "\u{201C}\(term)\u{201D} is not in a passage: nothing changes")
        }
        expect(replacing("", with: "Z", in: text) == (text, 0), "an empty term changes nothing")
        expect(replacing("Mayun", with: "a\nb\r\n**You** `00:00:09`", in: text).text.split(separator: "\n", omittingEmptySubsequences: false).count == text.split(separator: "\n", omittingEmptySubsequences: false).count, "a newline in the replacement does not add lines")
        expect(replacing("x", with: "y", in: "No speech was found.\n") == ("No speech was found.\n", 0), "no passages, no change")

        // The same hits Find marks (it marks with AttributedString), so the count shown is the count replaced.
        let passage = "Angra Mayun'u anlattı. angra mayun, ANGRA MAYUN."
        var marked = 0
        let attributed = AttributedString(passage)
        var from = attributed.startIndex
        while let range = attributed[from...].range(of: "angra mayun", options: findOptions) { marked += 1; from = range.upperBound }
        expect(marked == 3 && replacing("angra mayun", with: "", in: "**You** `00:00:00`\n\n\(passage)\n").count == marked, "Replace counts what Find marks: \(marked)")

        let typed = ["**You** `00:00:01`", "", "one Mayun", "", "---", "", "two Mayun", "", "**Them** `00:00:02`", "", "three Mayun", ""].joined(separator: "\n")
        expect(replacing("Mayun", with: "M", in: typed).count == 3, "a --- typed between passages is text, not the foot")
        return failures
    }
}
