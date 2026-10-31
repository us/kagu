import Foundation

/// Turns whisper segments of one or two tracks into a readable transcript. Pure functions, no I/O.
enum Transcript {
    struct Line: Equatable {
        var speaker: String
        var start: Double
        var text: String
    }

    typealias Track = (speaker: String, segments: [Segment])

    /// What the cleaning removed, kept so the transcript can say so at its foot.
    struct Struck: Equatable {
        var fillers = 0
        var repeatedWords = 0
        var doubled = 0
        var echoes = 0
        var echoOf = "Them"
        var inventions: [Segment] = []

        mutating func add(_ other: Struck) {
            fillers += other.fillers
            repeatedWords += other.repeatedWords
            inventions += other.inventions
        }

        /// "Struck from the record: 41 fillers and 2 lines repeated from Them." Nil when nothing was removed.
        var note: String? {
            func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
            let parts = [
                count(fillers, "filler", "fillers"),
                count(repeatedWords, "repeated word", "repeated words"),
                count(doubled, "line that came twice", "lines that came twice"),
                count(echoes, "line repeated from \(echoOf)", "lines repeated from \(echoOf)"),
            ].compactMap { $0 }
            var sentences = parts.isEmpty ? [] : ["Struck from the record: \(parts.formatted(.list(type: .and).locale(Locale(identifier: "en_US"))))."]
            for invention in inventions {
                let seconds = Int(invention.end - invention.start)
                let span = seconds < 90 ? "\(seconds) seconds" : "\(Int((Double(seconds) / 60).rounded())) minutes"
                sentences.append("Over \(span) the model heard \u{201C}\(invention.text.trimmingCharacters(in: .whitespaces))\u{201D} It was not entered.")
            }
            return sentences.isEmpty ? nil : sentences.joined(separator: " ")
        }
    }

    /// Only English "language" fillers: `er` or `mm` are real words in other languages.
    private static let fillers: Set<String> = ["um", "umm", "uh", "uhm", "hmm", "mhm"]
    /// What a listener says while the other side talks.
    private static let backchannels: Set<String> = ["yeah", "yes", "yep", "mmhmm", "uhhuh", "mhm", "hmm", "okay", "ok", "right", "sure"]
    private static let silenceInventions: Set<String> = ["you", "thank you", "thanks for watching", "bye"]
    private static let joinGap = 3.0  // seconds of silence that start a new paragraph
    private static let paragraphLimit = 450  // characters; a longer paragraph starts a new one at the next segment

    static func merge(_ tracks: [Track], language: String) -> (lines: [Line], struck: Struck) {
        let locale = Locale(identifier: language == "auto" ? "en" : language)
        var struck = Struck()
        // What tidying took out of each kept segment; it is only counted if the segment itself stays.
        var kept: [(speaker: String, segment: Segment, struck: Struck)] = []
        for track in tracks {
            var previous = ""
            for segment in track.segments {
                var own = Struck()
                let text = tidy(segment, language: language, locale: locale, struck: &own)
                // The same longer sentence twice in a row is a loop, not speech.
                let duplicate = text.split(separator: " ").count >= 4 && text.lowercased() == previous
                previous = text.lowercased()
                if duplicate {
                    struck.doubled += 1
                } else if text.isEmpty {
                    struck.add(own)  // a segment of only fillers, or a silence invention: all of it was struck
                } else {
                    kept.append((track.speaker, Segment(start: segment.start, end: segment.end, text: text), own))
                }
            }
        }
        var items = dropEchoes(kept.map { ($0.speaker, $0.segment) }, tracks.map(\.speaker))
        for entry in kept {
            if items.contains(where: { $0.speaker == entry.speaker && $0.segment == entry.segment }) { struck.add(entry.struck) } else { struck.echoes += 1 }
        }
        if tracks.count == 2 { struck.echoOf = tracks[1].speaker }
        items.sort { $0.segment.start < $1.segment.start }
        if language == "en" || language == "auto" {
            // "Yeah" or "mm-hmm" said while the other side talks is listening, not a turn; kept, it cuts their paragraph up.
            let short = Set(items.indices.filter { i in
                let words = items[i].segment.text.split(whereSeparator: \.isWhitespace).map { normal(String($0)) }
                return words.count <= 3 && words.allSatisfy(backchannels.contains)
            })
            // Only a real turn of the other side can hold one: both saying "okay" or "yeah" at once, neither is dropped.
            let listening = short.filter { i in
                items.indices.contains {
                    !short.contains($0) && items[$0].speaker != items[i].speaker
                        && items[$0].segment.start <= items[i].segment.start && items[$0].segment.end >= items[i].segment.end
                }
            }
            for i in listening { struck.fillers += items[i].segment.text.split(whereSeparator: \.isWhitespace).count }
            items = items.indices.filter { !listening.contains($0) }.map { items[$0] }
        }

        var lines: [Line] = []
        var lastEnd = 0.0
        for item in items {
            if let last = lines.last, last.speaker == item.speaker, item.segment.start - lastEnd <= joinGap, last.text.count < paragraphLimit {
                lines[lines.count - 1].text += " " + item.segment.text
            } else {
                lines.append(Line(speaker: item.speaker, start: item.segment.start, text: item.segment.text))
            }
            lastEnd = item.segment.end
        }
        return (lines.map { Line(speaker: $0.speaker, start: $0.start, text: finish($0.text, language: language, locale: locale)) }, struck)
    }

    /// The line that separates the passages from the note at the foot.
    private static let rule = "---"

    static func render(_ lines: [Line], struck: Struck = Struck(), title: String, model: String, language: String, date: Date) -> String {
        var out = ["# \(title)", "", "\(model), language \(language), transcribed \(date.formatted(date: .abbreviated, time: .shortened))", ""]
        for line in lines {
            out += ["**\(line.speaker)** `\(clock(line.start))`", "", line.text, ""]
        }
        if lines.isEmpty { out += ["No speech was found.", ""] }
        if let note = struck.note { out += [rule, "", note, ""] }
        return out.joined(separator: "\n")
    }

    /// The note at the foot of a transcript, if it has one.
    static func footnote(_ markdown: String) -> String? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = foot(lines) else { return nil }
        let note = lines[(index + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return note.isEmpty ? nil : note
    }

    /// The rule before the note: the last `---` with no passage after it. A `---` someone typed between
    /// passages is part of the text, not the foot.
    static func foot(_ lines: [Substring]) -> Int? {
        guard let index = lines.lastIndex(of: Substring(rule)), !lines[(index + 1)...].contains(where: { $0.wholeMatch(of: /\*\*(.+?)\*\* `(\d+):(\d+):(\d+)`/) != nil }) else { return nil }
        return index
    }

    struct Block: Equatable {
        var speaker: String
        var seconds: Double
        var text: String
    }

    /// Reads back what `render` wrote: `**Me** \`00:00:03\`` followed by the paragraph.
    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines[..<(foot(lines) ?? lines.count)] {
            if let match = line.wholeMatch(of: /\*\*(.+?)\*\* `(\d+):(\d+):(\d+)`/) {
                let (h, m, s): (Double, Double, Double) = (Double(match.2) ?? 0, Double(match.3) ?? 0, Double(match.4) ?? 0)
                let seconds = h * 3600 + m * 60 + s  // in parts: as one expression it timed out the type checker on CI
                blocks.append(Block(speaker: String(match.1), seconds: seconds, text: ""))
            } else if !blocks.isEmpty, !line.isEmpty {
                blocks[blocks.count - 1].text += (blocks[blocks.count - 1].text.isEmpty ? "" : " ") + line
            }
        }
        return blocks.filter { !$0.text.isEmpty }
    }

    /// What the Copy button puts on the clipboard: a title, the summary if there is one, then each passage as speaker, time and text.
    static func plainText(title: String, date: Date, summary: String? = nil, blocks: [Block]) -> String {
        let head = "\(title)\n\(date.formatted(date: .long, time: .shortened))"
        return ([head] + (summary.map { [$0] } ?? []) + blocks.map { "\($0.speaker) (\(clock($0.seconds)))\n\($0.text)" }).joined(separator: "\n\n")
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    // MARK: - Cleaning

    /// Removes fillers, immediate repeats and text Whisper makes up over silence; then fixes the capital and the full stop.
    static func tidy(_ segment: Segment, language: String, locale: Locale) -> String {
        var struck = Struck()
        return tidy(segment, language: language, locale: locale, struck: &struck)
    }

    static func tidy(_ segment: Segment, language: String, locale: Locale, struck: inout Struck) -> String {
        var words = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let plain = words.map(normal).joined(separator: " ")
        if segment.end - segment.start > 20, silenceInventions.contains(plain) {
            struck.inventions.append(segment)
            return ""
        }
        if language == "en" || language == "auto" {
            let count = words.count
            words.removeAll { fillers.contains(normal($0)) }
            struck.fillers += count - words.count
        }
        words.removeAll { $0 == "-" || $0 == "–" }  // dialogue markers some models print
        let count = words.count
        words = collapseRepeats(words, oneWord: language == "en")
        struck.repeatedWords += count - words.count
        guard !words.isEmpty else { return "" }
        let text = words.joined(separator: " ")
        guard language == "en", text.contains(where: { ".,?!".contains($0) }) else { return text }
        return words.map { $0 == "i" ? "I" : $0 }.joined(separator: " ")
    }

    /// Whisper punctuates some stretches and not others, and a segment is often cut mid sentence ("but I'm" |
    /// "energized for the week."), so a paragraph, not a segment, gets a capital and a full stop, and only where
    /// Whisper punctuated it itself.
    static func finish(_ paragraph: String, language: String, locale: Locale) -> String {
        guard paragraph.contains(where: { ".,?!".contains($0) }) else { return paragraph }
        var text = paragraph
        if language != "auto" { text = text.prefix(1).uppercased(with: locale) + text.dropFirst() }  // "iyi" needs the Turkish rule
        if let last = text.last, ",;:".contains(last) { text.removeLast() }
        if let last = text.last, !".?!…".contains(last) { text += "." }
        return text
    }

    /// "I think I think it is it is fine" becomes "I think it is fine": repeats of 1 to 6 words, until none are left.
    /// Words are compared with their punctuation ("It works. It works on" is two sentences, not a stutter), and a
    /// single repeated word only in English: "sık sık" or "yavaş yavaş" in Turkish is one word said twice on purpose.
    static func collapseRepeats(_ input: [String], oneWord: Bool = true) -> [String] {
        var words = input
        var changed = true
        while changed {
            changed = false
            for n in stride(from: 6, through: oneWord ? 1 : 2, by: -1) {
                var i = 0
                while i + 2 * n <= words.count {
                    if (0..<n).allSatisfy({ words[i + $0].lowercased() == words[i + n + $0].lowercased() }) {
                        words.removeSubrange(i + n..<i + 2 * n)
                        changed = true
                    } else {
                        i += 1
                    }
                }
            }
        }
        return words
    }

    /// Speaker bleed: a `Me` segment that overlaps a `Them` segment in time and repeats most of its words is an echo the canceller missed.
    private static func dropEchoes(_ items: [(speaker: String, segment: Segment)], _ speakers: [String]) -> [(speaker: String, segment: Segment)] {
        guard speakers.count == 2 else { return items }
        let (mine, theirs) = (speakers[0], speakers[1])
        return items.filter { item in
            guard item.speaker == mine else { return true }
            let mineWords = Set(item.segment.text.split(separator: " ").map { normal(String($0)) })
            guard mineWords.count >= 4 else { return true }  // "yeah, sure" is never judged an echo
            let length = max(0.1, item.segment.end - item.segment.start)
            return !items.contains { other in
                guard other.speaker == theirs else { return false }
                let shared = min(item.segment.end, other.segment.end) - max(item.segment.start, other.segment.start)
                guard shared / length > 0.5 else { return false }
                // A short line is an echo only when it starts together with theirs; a reply comes after.
                if mineWords.count < 6, abs(item.segment.start - other.segment.start) > 1.5 { return false }
                let theirWords = Set(other.segment.text.split(separator: " ").map { normal(String($0)) })
                return Double(mineWords.intersection(theirWords).count) / Double(max(1, mineWords.count)) > 0.6
            }
        }
    }

    private static func normal(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    // MARK: - Self check (run with --selftest)

    static func selfTest() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        let en = Locale(identifier: "en")

        expect(collapseRepeats("I think I think it is it is fine".split(separator: " ").map(String.init)).joined(separator: " ") == "I think it is fine", "collapse repeats")
        expect(collapseRepeats("It works. It works on my machine.".split(separator: " ").map(String.init)).joined(separator: " ") == "It works. It works on my machine.", "two sentences are not a stutter")
        expect(finish(tidy(Segment(start: 0, end: 3, text: " sık sık geliyor, yavaş yavaş."), language: "tr", locale: Locale(identifier: "tr")), language: "tr", locale: Locale(identifier: "tr")) == "Sık sık geliyor, yavaş yavaş.", "Turkish doubled words stay")
        expect(finish(tidy(Segment(start: 0, end: 3, text: " um so hello, there"), language: "en", locale: en), language: "en", locale: en) == "So hello, there.", "filler and full stop")
        expect(tidy(Segment(start: 0, end: 3, text: " - so hello there"), language: "en", locale: en) == "so hello there", "dialogue dash dropped, unpunctuated text left alone")
        expect(finish(tidy(Segment(start: 0, end: 3, text: " fine, and i agree,"), language: "en", locale: en), language: "en", locale: en) == "Fine, and I agree.", "capital I and trailing comma")
        expect(tidy(Segment(start: 0, end: 25, text: " Thank you."), language: "en", locale: en) == "", "silence invention")
        expect(tidy(Segment(start: 0, end: 3, text: " Thank you."), language: "en", locale: en) == "Thank you.", "real thank you stays")
        expect(finish(tidy(Segment(start: 0, end: 3, text: " iyi günler, hepinize"), language: "tr", locale: Locale(identifier: "tr")), language: "tr", locale: Locale(identifier: "tr")) == "İyi günler, hepinize.", "Turkish capital i")
        expect(finish(tidy(Segment(start: 0, end: 3, text: " er hat recht, ja"), language: "de", locale: Locale(identifier: "de")), language: "de", locale: Locale(identifier: "de")) == "Er hat recht, ja.", "German er is kept")

        let me: [Segment] = [Segment(start: 0, end: 4, text: "so what we have here today"), Segment(start: 10, end: 14, text: "yes that works for me,"), Segment(start: 15, end: 17, text: "and one more thing.")]
        let them: [Segment] = [Segment(start: 1, end: 5, text: "so what we have here today is a tool"), Segment(start: 30, end: 34, text: "great")]
        let lines = merge([("Me", me), ("Them", them)], language: "en").lines
        expect(lines.map(\.speaker) == ["Them", "Me", "Them"], "echo dropped, order kept, same speaker joined: \(lines.map(\.speaker))")
        expect(lines.count == 3 && lines[1].text == "Yes that works for me, and one more thing.", "me lines joined: \(lines.map(\.text))")
        let rendered = render([Line(speaker: "Me", start: 3, text: "Hello there."), Line(speaker: "Them", start: 3725, text: "Fine, thanks.")], title: "t", model: "m", language: "en", date: Date())
        expect(parse(rendered) == [Block(speaker: "Me", seconds: 3, text: "Hello there."), Block(speaker: "Them", seconds: 3725, text: "Fine, thanks.")], "parse reads back render: \(parse(rendered))")
        let copied = plainText(title: "t", date: Date(timeIntervalSince1970: 0), blocks: [Block(speaker: "Me", seconds: 3, text: "Hello."), Block(speaker: "Them", seconds: 65, text: "Hi.")])
        expect(copied.hasSuffix("Me (00:00:03)\nHello.\n\nThem (00:01:05)\nHi."), "copy format: \(copied)")
        let long = (0..<20).map { Segment(start: Double($0) * 5, end: Double($0) * 5 + 4.5, text: "this is sentence number \($0) of a long talk by one person.") }
        let paragraphs = merge([("Speaker", long)], language: "en").lines
        expect(paragraphs.count > 1 && paragraphs.allSatisfy { $0.text.count < 450 + 70 }, "a long monologue is cut into paragraphs: \(paragraphs.count)")
        let bleed = merge([("You", [Segment(start: 4, end: 7, text: "testing the live robot recording")]), ("Them", [Segment(start: 4.2, end: 8, text: "testing the live row while recording")])], language: "en").lines
        expect(bleed.map(\.speaker) == ["Them"], "a five word echo that starts with theirs is dropped: \(bleed.map(\.speaker))")
        let looped = merge([("Speaker", [Segment(start: 0, end: 4, text: "so we have to check the setup again."), Segment(start: 4, end: 8, text: "so we have to check the setup again."), Segment(start: 5, end: 6, text: "Yeah.")])], language: "en").lines
        expect(looped.count == 1 && looped[0].text == "So we have to check the setup again. Yeah.", "back to back duplicate dropped: \(looped.map(\.text))")
        let shortMe = merge([("Me", [Segment(start: 2, end: 3, text: "yeah I think so")]), ("Them", [Segment(start: 0, end: 10, text: "yeah I think so and that is the plan we have")])], language: "en").lines
        expect(shortMe.count == 2, "a short Me line over a long Them segment is kept: \(shortMe.map(\.speaker))")
        let counted = merge([("You", [Segment(start: 4, end: 7, text: "um testing the live robot recording"), Segment(start: 9, end: 11, text: "I think I think so"), Segment(start: 20, end: 50, text: " Thank you.")]), ("Them", [Segment(start: 4.2, end: 8, text: "testing the live row while recording")])], language: "en").struck
        // The filler sits in the echo line, which is struck whole: it is not counted twice.
        expect(counted == Struck(fillers: 0, repeatedWords: 2, doubled: 0, echoes: 1, echoOf: "Them", inventions: [Segment(start: 20, end: 50, text: " Thank you.")]), "struck counts: \(counted)")
        let note = counted.note ?? ""
        expect(note == "Struck from the record: 2 repeated words and 1 line repeated from Them. Over 30 seconds the model heard \u{201C}Thank you.\u{201D} It was not entered.", "struck note: \(note)")
        let fillerOnly = merge([("You", [Segment(start: 0, end: 2, text: "um"), Segment(start: 3, end: 5, text: "uh so we start")])], language: "en").struck
        expect(fillerOnly.fillers == 2, "fillers in kept lines and in a line of only fillers count: \(fillerOnly)")
        expect(Struck().note == nil, "nothing struck, no note")
        let footed = render([Line(speaker: "You", start: 3, text: "Hello there.")], struck: counted, title: "t", model: "m", language: "en", date: Date())
        expect(parse(footed) == [Block(speaker: "You", seconds: 3, text: "Hello there.")] && footnote(footed) == note, "the note is kept apart from the passages: \(parse(footed))")
        expect(footnote(rendered) == nil, "an old transcript has no note")
        let typed = rendered.replacingOccurrences(of: "**Them**", with: "---\n\n**Them**")
        expect(parse(typed).count == 2 && footnote(typed) == nil, "a --- typed between passages cuts nothing: \(parse(typed))")
        let taken = FileManager.default.temporaryDirectory.appending(path: "recorder-unused-probe.md")
        FileManager.default.createFile(atPath: taken.path, contents: Data())
        expect(Transcriber.unused(taken).lastPathComponent == "recorder-unused-probe 2.md", "existing transcript is never replaced")
        try? FileManager.default.removeItem(at: taken)
        return failures
    }
}
