import Foundation
import NaturalLanguage
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A short summary, the decisions and the action items of a transcript, made on this Mac by Apple's on-device model
/// and kept in the transcript's own file, after its header line. The text side (reading model output, cleaning it,
/// the block in the file) is plain functions; the model itself sits in `Model`.
enum Summary {
    struct Parts: Equatable {
        var summary: String
        var decisions: [String] = []
        var actions: [String] = []
    }

    static let disclaimer = "Made on this Mac from the transcript; it can be wrong."
    /// Fewer words than this have nothing worth summarizing.
    static let minWords = 40

    /// False without the framework (older macOS), without Apple Intelligence, or with the hidden test flag.
    static var isAvailable: Bool {
        guard !CommandLine.arguments.contains("--no-summary-model") else { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    static func worthIt(_ blocks: [Transcript.Block]) -> Bool {
        blocks.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } >= minWords
    }

    /// Runs the model. Nil when there is nothing to do: no model, a language it does not speak, too little text.
    /// `abandon` is asked between passes (a recording started); it and a cancelled task end the run with a CancellationError.
    static func make(from markdown: String, progress: @MainActor @Sendable (Double) -> Void, abandon: @MainActor @Sendable () -> Bool) async throws -> Parts? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return try await Model.run(markdown, progress: progress, abandon: abandon) }
        #endif
        return nil
    }

    // MARK: - What the model is asked

    static func dialogue(_ blocks: [Transcript.Block]) -> [String] { blocks.map { "\(Transcript.isOwner($0.speaker) ? "You" : $0.speaker): \($0.text)" } }

    /// The other side's name in a recording of two speakers, You and one more (Them, or the name the owner gave it); else nil.
    static func otherSide(_ blocks: [Transcript.Block]) -> String? {
        let speakers = Set(blocks.map(\.speaker))
        let others = speakers.filter { !Transcript.isOwner($0) }
        return speakers.contains(where: Transcript.isOwner) && others.count == 1 && !others.contains("Speaker") ? others.first : nil
    }

    /// `other`: the name of the other side when the transcript tells You and one other apart (a recording Kagu made); else the speakers are one or mixed.
    static func instructions(language: String, other: String?) -> String {
        let who = other.map { "\"You\" is the person who made the recording, \"\($0)\" is the other side. In sentences say \"you\" for You and \($0 == "Them" ? "\"the other side\"" : "\($0)") for \($0), never \"You\" or \"Them\" with a capital. " }
            ?? "The speakers are not told apart. "
        return "You write notes on a recorded conversation or talk. \(who)Write in \(language). Use only what is said in the text; never invent names, numbers, dates or tasks. "
            + "Keep the three headings SUMMARY:, DECISIONS: and ACTIONS: in English, exactly as given."
    }

    /// `notes`: the text is notes on parts of the conversation, not the conversation. `final`: the answer is the summary itself.
    static func prompt(_ text: String, notes: Bool, final: Bool, language: String, other: String?) -> String {
        let task = switch (notes, final) {
        case (false, false): "Below is one part of a longer conversation. Write notes on it."
        case (false, true): "Below is a conversation. Write a summary of it."
        case (true, false): "Below are notes on several parts of one conversation. Combine them into shorter notes."
        case (true, true): "Below are notes on the parts of one conversation. Combine them into one summary of the whole conversation."
        }
        let actions = other.map { "- You: what you will do\n- \($0): what the other side will do (or a name said in the conversation instead of \($0))" }
            ?? "- what someone took on to do, with their name if a name is said"
        return """
        \(task)
        Answer in exactly this format and nothing else, with no bold text and no other headings:
        SUMMARY:
        \(final ? "3 to 5 sentences: what the conversation was about and what came out of it." : "3 to 6 short bullets with the topics and facts.")
        DECISIONS:
        - what the speakers explicitly decided or agreed to do, in your own words and short, one per line; facts, opinions, history and things being explained are not decisions, nor is a suggestion nobody accepted; write the English word "none" if nothing was decided
        ACTIONS:
        \(actions)
        Write the English word "none" if nobody explicitly promised to do something or was asked to: describing or explaining things is not a task, and a talk, lecture or podcast has none.
        Write every line in \(language), only the three headings stay in English. Merge duplicates. Never list recording, transcribing or testing this conversation as a task, and never copy lines of the conversation.

        \(text)
        """
    }

    /// Tokens are not words: how many characters one token holds, when the model cannot count them itself.
    static func charsPerToken(_ language: String) -> Double {
        switch language { case "en": 3.0; case "tr": 2.0; default: 2.5 }
    }

    /// Lines joined into pieces of at most `limit` characters, cut between lines; a line longer than that is cut at a space.
    static func chunks(_ lines: [String], limit: Int) -> [String] {
        let limit = max(limit, 200)
        var result: [String] = []
        var current = ""
        for line in lines.flatMap({ cut($0, limit) }) {
            if !current.isEmpty, current.count + 1 + line.count > limit { result.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func cut(_ line: String, _ limit: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(line)
        while rest.count > limit {
            let end = rest.prefix(limit).lastIndex(of: " ") ?? rest.index(rest.startIndex, offsetBy: limit)
            pieces.append(String(rest[..<end]))
            rest = rest[end...].drop { $0 == " " }
        }
        return pieces + [String(rest)]
    }

    // MARK: - What the model said

    private enum Section { case summary, decisions, actions }

    /// The three sections of a model answer, cleaned. Tolerant: bold or `#` headings, bullets of any kind, a heading with
    /// text after it. Nil when nothing is left of the summary.
    static func parts(fromModel output: String) -> Parts? {
        let found = sections(in: output)
        let summary = found.summary.filter { !$0.hasPrefix("---") && $0.wholeMatch(of: /(?i)(you|them|speaker)\s*:.*/) == nil }
            .map { $0.last.map { ".?!…".contains($0) } == true ? $0 : $0 + "." }
            .joined(separator: " ")
        guard !summary.isEmpty else { return nil }
        return Parts(summary: summary, decisions: Array(found.decisions.prefix(8)), actions: Array(found.actions.filter { !isNoise($0) }.prefix(12)))
    }

    /// The answer in the fixed format again, for the next pass: nothing but what survived the cleaning.
    static func notes(fromModel output: String) -> String {
        let found = sections(in: output)
        func list(_ items: [String]) -> String { items.map { "- " + $0 }.joined(separator: "\n") }
        return ["SUMMARY:", list(found.summary), "DECISIONS:", list(found.decisions), "ACTIONS:", list(found.actions.filter { !isNoise($0) })]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func sections(in output: String) -> (summary: [String], decisions: [String], actions: [String]) {
        var entries: [Section: [(text: String, bullet: Bool)]] = [:]
        var section = Section.summary
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.wholeMatch(of: speakerLine) != nil { continue }  // a line of the transcript, copied
            let bullet = line.firstMatch(of: /^([-*•]|\d+[.)])\s+/) != nil
            line = plain(line.replacing(/^([-*•]|\d+[.)])\s+/, with: ""))
            if let match = line.wholeMatch(of: /(?i)(summary|decisions?|action items|actions?)\s*(?::\s*(.*))?/) {
                section = match.1.lowercased().hasPrefix("summary") ? .summary : match.1.lowercased().hasPrefix("decision") ? .decisions : .actions
                line = String(match.2 ?? "")
            }
            if !line.isEmpty, !isNone(line) { entries[section, default: []].append((line, bullet || section == .summary)) }
        }
        // A line that is not a bullet continues the bullet before it, when the section has bullets at all.
        func items(_ section: Section) -> [String] {
            let all = entries[section] ?? []
            guard all.contains(where: \.bullet) else { return all.map { $0.text.prefix(1).uppercased() + $0.text.dropFirst() } }
            var result: [String] = []
            for entry in all { if entry.bullet || result.isEmpty { result.append(entry.text) } else { result[result.count - 1] += " " + entry.text } }
            var seen = Set<String>()
            return result.map { $0.prefix(1).uppercased() + $0.dropFirst() }.filter { seen.insert($0.lowercased()).inserted }
        }
        return (items(.summary), items(.decisions), items(.actions))
    }

    /// One line as plain text: no bold, code marks or heading marks, one space between words; a lone rule is nothing.
    static func plain(_ line: String) -> String {
        let text = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
            .replacing(/^#+\s*/, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.allSatisfy { "-_*= ".contains($0) } ? "" : text
    }

    /// The model's way of saying there is nothing, also in the language of the talk. Only a short line counts: "None of
    /// the prices change" and "Hiçbir fiyat değişmeyecek" are statements.
    private static func isNone(_ line: String) -> Bool {
        let text = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".! "))
        guard text.split(whereSeparator: \.isWhitespace).count <= 4 else { return false }
        return ["none", "n/a", "nothing", "no decisions", "no decision", "no action items", "no actions", "no tasks", "yok", "hiçbir", "hiçbiri",
                "hiçbir şey", "hiçbir karar", "hiçbir görev", "karar yok", "görev yok", "aksiyon yok"].contains(text)
    }

    /// "You: recording and transcribing the meeting": the model lists what the recording itself is doing as a task.
    /// Only when the object is this meeting: "Record the next episode on Monday" is a real task.
    static func isNoise(_ item: String) -> Bool {
        let task = item.replacing(/^[^:]{1,30}:\s*/, with: "").lowercased()
        return task.wholeMatch(of: /(?:(?:to|will|is|are|be|keep|keeps|continue|continues)\s+)*(?:testing\s+)?(?:the\s+)?(?:record|transcrib)\w*(?:\s+and\s+(?:record|transcrib)\w*)?(?:\s+(?:this|the|our|that)\s+(?:meeting|call|conversation|session|discussion|talk|interview)|\s+(?:it|everything))?\s*[.!]?/) != nil
    }

    // MARK: - The block in the transcript file

    private static var speakerLine: Regex<(Substring, Substring, Substring, Substring, Substring)> { /\*\*(.+?)\*\* `(\d+):(\d+):(\d+)`/ }

    static func markdown(_ parts: Parts) -> String {
        func list(_ heading: String, _ items: [String]) -> [String] { items.isEmpty ? [] : ["## \(heading)", ""] + items.map { "- " + $0 } + [""] }
        return (["## Summary", "", parts.summary, ""] + list("Decisions", parts.decisions) + list("Action items", parts.actions) + [disclaimer]).joined(separator: "\n")
    }

    /// The transcript with the summary after its header line (the second non-empty line); one that was there is replaced.
    /// Nil when the file has no header line to put it after.
    static func insert(_ parts: Parts, into markdown: String) -> String? {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.indices.filter({ !lines[$0].isEmpty }).dropFirst().first else { return nil }
        let first = lines[(header + 1)...].firstIndex { $0.wholeMatch(of: speakerLine) != nil } ?? lines.endIndex
        if lines[(header + 1)..<first].contains("## Summary") {
            lines.removeSubrange((header + 1)..<first)
            lines.insert("", at: header + 1)
        }
        lines.insert(contentsOf: [""] + Self.markdown(parts).split(separator: "\n", omittingEmptySubsequences: false).map(String.init), at: header + 1)
        return lines.joined(separator: "\n")
    }

    /// The summary a transcript file holds, read back.
    static func parts(in markdown: String) -> Parts? {
        var parts = Parts(summary: "")
        var section: String?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.wholeMatch(of: speakerLine) != nil { break }
            switch line {
            case "## Summary", "## Decisions", "## Action items": section = String(line.dropFirst(3))
            case "", Substring(disclaimer): continue
            default:
                switch section {
                case "Summary": parts.summary += (parts.summary.isEmpty ? "" : " ") + line
                case "Decisions" where line.hasPrefix("- "): parts.decisions.append(String(line.dropFirst(2)))
                case "Action items" where line.hasPrefix("- "): parts.actions.append(String(line.dropFirst(2)))
                default: break
                }
            }
        }
        return parts.summary.isEmpty ? nil : parts
    }

    /// The summary as plain text, for Copy and Transcript as Text.
    static func plainText(in markdown: String) -> String? {
        guard let parts = parts(in: markdown) else { return nil }
        func list(_ heading: String, _ items: [String]) -> [String] { items.isEmpty ? [] : ["", heading] + items.map { "- " + $0 } }
        return (["Summary", parts.summary] + list("Decisions", parts.decisions) + list("Action items", parts.actions) + ["", disclaimer]).joined(separator: "\n")
    }

    // MARK: - Self check (run with --selftest)

    @MainActor
    static func selfTest(in root: URL) -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        let answer = """
        # Meeting Summary
        **SUMMARY:** We talked about the launch date and the pricing page
        - Fran wants the page ready by Friday
        **You** `00:00:05`
        ---
        You: this line is a copy of the conversation
        DECISIONS:
        - **Launch** on Friday
        * The price stays at 12 euros
        - launch on friday
        ACTIONS:
        1. You: recording and transcribing the meeting
        - Them: Send the contract to Fran
        - Fran: will fix the pricing page
          and test it
        - To record the call
        """
        let made = parts(fromModel: answer)
        expect(made?.summary == "Meeting Summary. We talked about the launch date and the pricing page. Fran wants the page ready by Friday.", "summary cleaned: \(made?.summary ?? "nil")")
        expect(made?.decisions == ["Launch on Friday", "The price stays at 12 euros"], "decisions cleaned and deduplicated: \(made?.decisions ?? [])")
        expect(made?.actions == ["Them: Send the contract to Fran", "Fran: will fix the pricing page and test it"], "actions without recording noise, a wrapped line joined: \(made?.actions ?? [])")
        expect(isNoise("You: recording and transcribing the meeting") && isNoise("Them: Transcribing this call") && !isNoise("You: send the call recording to Fran"), "noise only when the task is the recording itself")
        expect(parts(fromModel: "SUMMARY:\nnone\nDECISIONS:\n- none\nACTIONS:\n- None.") == nil, "nothing said, no summary")
        expect(parts(fromModel: "SUMMARY:\nShort.\nDECISIONS:\n- None of the prices change\n- Hiçbir fiyat değişmeyecek")?.decisions == ["None of the prices change", "Hiçbir fiyat değişmeyecek"], "a statement that starts like none is kept")
        expect(isNoise("You: recording the meeting") && isNoise("Them: record the call.") && !isNoise("You: Record the next episode on Monday") && !isNoise("You: transcribe the interview with Fran by Friday"), "noise needs this meeting as the object")
        expect(parts(fromModel: "SUMMARY:\nKısa bir konuşma.\nDECISIONS:\n- Hiçbir\nACTIONS:\n- Yok") == Parts(summary: "Kısa bir konuşma."), "none in Turkish is none")
        let plainAnswer = Summary.parts(fromModel: "Summary: A short talk.\nDecisions:\nNone\nActions: \n- You: call Fran")
        expect(plainAnswer == Parts(summary: "A short talk.", decisions: [], actions: ["You: call Fran"]), "plain headings, none dropped: \(String(describing: plainAnswer))")
        expect(notes(fromModel: answer).hasPrefix("SUMMARY:\n- Meeting Summary\n") && !notes(fromModel: answer).contains("recording and transcribing"), "notes keep the fixed format")

        // A transcript with the block in it still reads as before.
        let lines = [Transcript.Line(speaker: "You", start: 3, text: "Hello there, fine."), Transcript.Line(speaker: "Them", start: 65, text: "So we ship it on Friday.")]
        var struck = Transcript.Struck()
        struck.fillers = 2
        let original = Transcript.render(lines, struck: struck, title: "Standup", model: "Whisper", language: "auto", date: Date())
        guard let block = made, let with = insert(block, into: original) else { return failures + ["summary not inserted"] }
        let twice = insert(Parts(summary: "Another."), into: with) ?? ""
        expect(Transcript.parse(with) == Transcript.parse(original), "the passages are the same with a summary: \(Transcript.parse(with))")
        expect(Transcript.footnote(with) == Transcript.footnote(original) && Transcript.footnote(with) != nil, "the foot note is the same with a summary")
        let header = original.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? ""
        expect(header.hasPrefix("Whisper, language auto") && with.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().first.map(String.init) == header, "the header line is still the second line")
        expect(with.hasPrefix("# Standup\n\n\(header)\n\n## Summary\n\n") && with.contains("\n\(disclaimer)\n\n**You** `00:00:03`\n"), "the block sits between the header and the first passage: \(with.prefix(400))")
        expect(parts(in: with) == block && parts(in: original) == nil, "the summary reads back from the file")
        expect(twice.components(separatedBy: "## Summary").count == 2 && parts(in: twice) == Parts(summary: "Another.") && Transcript.parse(twice).count == 2, "a second summary replaces the first")
        expect(transcriptSnippet(with, "friday")?.description.contains("Friday") == true && transcriptSnippet(with, "launch") == nil, "the library snippet looks only at what was said")
        let copied = Transcript.plainText(title: "t", date: Date(timeIntervalSince1970: 0), summary: plainText(in: with), blocks: Transcript.parse(with))
        expect(copied.contains("\n\nSummary\nMeeting Summary.") && copied.contains("Action items\n- Them: Send the contract to Fran\n- Fran: will fix the pricing page and test it\n\n\(disclaimer)\n\nYou (00:00:03)\nHello there, fine."), "Copy has the summary before the passages: \(copied)")
        expect(plainText(in: original) == nil, "no summary, nothing added to Copy")

        // Writing: only into the file the model worked from.
        let url = root.appending(path: "summary.md")
        try? original.write(to: url, atomically: true, encoding: .utf8)
        do { try TranscriptFile.edit(url, expected: original) { insert(block, into: $0) } } catch { failures.append("attach failed: \(error)") }
        expect((try? String(contentsOf: url, encoding: .utf8)) == with, "the summary is written into the file")
        try? "# New\n\nWhisper\n\n**You** `00:00:01`\n\nA new transcript.\n".write(to: url, atomically: true, encoding: .utf8)
        expect((try? TranscriptFile.edit(url, expected: original) { insert(block, into: $0) }) == nil && parts(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "") == nil, "a transcript that changed meanwhile gets no summary")

        // Chunks: cut between lines, nothing lost, none too long.
        let spoken = (0..<40).map { "You: sentence number \($0) of a long talk" }
        let pieces = chunks(spoken, limit: 300)
        expect(pieces.count > 3 && pieces.allSatisfy { $0.count <= 300 } && pieces.joined(separator: "\n") == spoken.joined(separator: "\n"), "chunks at line boundaries: \(pieces.count)")
        let long = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
        expect(chunks(["Them: " + long], limit: 300).allSatisfy { $0.count <= 300 } && chunks(["Them: " + long], limit: 300).joined(separator: " ").split(separator: " ").count == 201, "a line longer than a chunk is cut at spaces")
        expect(charsPerToken("tr") < charsPerToken("en") && charsPerToken("de") < charsPerToken("en"), "Turkish gets fewer characters per token")
        let named = [Transcript.Block(speaker: "Me", seconds: 0, text: "Hi."), Transcript.Block(speaker: "Fran", seconds: 3, text: "Hello.")]
        expect(otherSide(named) == "Fran" && dialogue(named) == ["You: Hi.", "Fran: Hello."] && otherSide([Transcript.Block(speaker: "Speaker", seconds: 0, text: "x")]) == nil, "the other side keeps the name the owner gave it")
        expect(!worthIt([Transcript.Block(speaker: "You", seconds: 0, text: "Hello there.")]) && worthIt([Transcript.Block(speaker: "You", seconds: 0, text: String(repeating: "word ", count: 50))]), "a short transcript is not worth summarizing")
        return failures
    }
}

#if canImport(FoundationModels)
/// The calls to Apple's on-device model.
@available(macOS 26, *)
private enum Model {
    static func run(_ markdown: String, progress: @MainActor @Sendable (Double) -> Void, abandon: @MainActor @Sendable () -> Bool) async throws -> Summary.Parts? {
        let blocks = Transcript.parse(markdown)
        guard Summary.worthIt(blocks) else { return nil }
        // The guardrails that allow rewriting and summarizing what people said, which the default ones may refuse.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard model.availability == .available else { return nil }
        let dialogue = Summary.dialogue(blocks)
        let (code, name) = language(of: dialogue.joined(separator: " "))
        guard model.supportsLocale(Locale(identifier: code)) else {
            log("summary: the model does not support \(code)")
            return nil
        }
        let ratio = await charsPerToken(model, dialogue, code)
        let other = Summary.otherSide(blocks)
        let clock = ContinuousClock()
        let start = clock.now
        var result: Summary.Parts?
        var passes = 0
        do {
            (result, passes) = try await summarize(dialogue, model: model, language: name, other: other, ratio: ratio, scale: 1, progress: progress, abandon: abandon)
        } catch where isOverflow(error) {
            log("summary: a chunk was too long for the model, trying again with half the size")
            (result, passes) = try await summarize(dialogue, model: model, language: name, other: other, ratio: ratio, scale: 0.5, progress: progress, abandon: abandon)
        }
        log("summary: \(passes) passes in \(clock.now - start), \(code), \(String(format: "%.1f", ratio)) characters per token, context \(model.contextSize)")
        return result
    }

    private static func summarize(_ dialogue: [String], model: SystemLanguageModel, language: String, other: String?, ratio: Double, scale: Double,
                                  progress: @MainActor @Sendable (Double) -> Void, abandon: @MainActor @Sendable () -> Bool) async throws -> (Summary.Parts?, Int) {
        // A quarter of the window stays free for the instructions and the answer.
        let limit = Int(Double(model.contextSize) * 0.75 * ratio * scale)
        var total = 1
        var done = 0
        func pass(_ text: String, notes: Bool, final: Bool) async throws -> String {
            try Task.checkCancellation()
            if await abandon() { throw CancellationError() }  // a recording started
            // A new session for each pass: a pass never carries the one before it in its window.
            let session = LanguageModelSession(model: model, instructions: Summary.instructions(language: language, other: other))
            let reply = try await session.respond(to: Summary.prompt(text, notes: notes, final: final, language: language, other: other), options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: final ? 700 : 500))
            done += 1
            await progress(Double(done) / Double(total))
            return reply.content
        }
        let chunks = Summary.chunks(dialogue, limit: limit)
        var answer: String
        if chunks.count == 1 {
            answer = try await pass(chunks[0], notes: false, final: true)
        } else {
            total = chunks.count + 1
            var level: [String] = []
            for chunk in chunks { level.append(Summary.notes(fromModel: try await pass(chunk, notes: false, final: false))) }
            // Notes of many chunks that do not fit one pass are combined in groups first, until they do.
            while level.joined(separator: "\n\n").count > limit {
                let groups = Summary.chunks(level, limit: limit)
                guard groups.count < level.count else { throw RecorderError("The notes did not get shorter.") }
                total += groups.count
                level = []
                for group in groups { level.append(Summary.notes(fromModel: try await pass(group, notes: true, final: false))) }
            }
            answer = try await pass(level.joined(separator: "\n\n"), notes: true, final: true)
        }
        try Task.checkCancellation()
        guard let parts = Summary.parts(fromModel: answer) else { throw RecorderError("The model gave no summary.") }
        return (parts, done)
    }

    /// The most common language of the text (the header only says `auto`).
    private static func language(of text: String) -> (code: String, name: String) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(20_000)))
        let code = recognizer.dominantLanguage?.rawValue ?? "en"
        return (code, Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code)
    }

    /// The model counts the tokens of a sample of the text where it can (macOS 26.4 and later), with a margin; else a guess by language.
    private static func charsPerToken(_ model: SystemLanguageModel, _ dialogue: [String], _ code: String) async -> Double {
        let guess = Summary.charsPerToken(code)
        guard #available(macOS 26.4, *) else { return guess }
        let sample = String(dialogue.joined(separator: "\n").prefix(6000))
        guard let tokens = try? await model.tokenCount(for: sample), tokens > 0 else { return guess }
        return max(1.5, min(5, Double(sample.count) / Double(tokens) * 0.85))
    }

    private static func isOverflow(_ error: Error) -> Bool {
        if #available(macOS 27, *), case .contextSizeExceeded? = error as? LanguageModelError { return true }
        if case .exceededContextWindowSize? = error as? LanguageModelSession.GenerationError { return true }
        return false
    }
}
#endif

/// Makes the summaries one at a time, and knows the state of each: waiting, running, failed.
@MainActor @Observable
final class Summarizer {
    enum State: Equatable {
        case waiting  // for its turn, or for the recording that is running
        case running(Double)
        case failed(String)

        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    private(set) var states: [URL: State] = [:]
    /// Set by the transcriber: true while a recording runs, then a summary does not start and one in progress is given up.
    var shouldPause: () -> Bool = { false }
    /// Called when a summary ends, so a quit that waited for it goes on.
    @ObservationIgnored var onIdle: () -> Void = {}

    private var queue: [URL] = []
    /// Asked for with its button: only then does a model that cannot help say so.
    private var manual: Set<URL> = []
    /// Asked for again while it runs (the transcript was made again): it goes round once more when this one ends.
    private var again: Set<URL> = []
    /// Put back in the queue once already after a write that failed: not a second time.
    private var retried: Set<URL> = []
    private var current: (source: URL, task: Task<Summary.Parts?, Error>)?
    private var working = false
    private var shuttingDown = false

    var isBusy: Bool { states.values.contains { !$0.isFailure } }

    /// `source`: the recording; its transcript is looked up when the work starts and again when it ends.
    func request(_ source: URL, manual isManual: Bool = false) {
        guard Summary.isAvailable, !shuttingDown else { return }
        if isManual { manual.insert(source) }
        switch states[source] {
        case .waiting: return
        case .running: again.insert(source); return
        case .failed, nil: break
        }
        retried.remove(source)
        enqueue(source)
    }

    func cancel(_ source: URL) {
        states[source] = nil
        for set in [\Summarizer.manual, \.again, \.retried] { self[keyPath: set].remove(source) }
        queue.removeAll { $0 == source }
        if current?.source == source { current?.task.cancel() }
        onIdle()
    }

    /// A recording was renamed or moved: its summary follows it.
    func moved(_ old: URL, to new: URL) {
        guard old != new else { return }
        if let state = states.removeValue(forKey: old) { states[new] = state }
        for set in [\Summarizer.manual, \.again, \.retried] where self[keyPath: set].remove(old) != nil { self[keyPath: set].insert(new) }
        for i in queue.indices where queue[i] == old { queue[i] = new }
        if let running = current, running.source == old { current = (new, running.task) }
    }

    /// At quit: nothing starts again, what runs stops.
    func shutDown() {
        shuttingDown = true
        queue.removeAll()
        current?.task.cancel()
    }

    private func enqueue(_ source: URL) {
        states[source] = .waiting
        queue.append(source)
        guard !working else { return }
        working = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            // Wait before taking one out of the queue, so a rename meanwhile still finds it there.
            while shouldPause(), !shuttingDown { try? await Task.sleep(for: .seconds(1)) }
            guard !shuttingDown, !queue.isEmpty else { break }
            let source = queue.removeFirst()
            guard states[source] != nil else { continue }  // cancelled while waiting
            await run(source)
        }
        working = false
        onIdle()
    }

    private func run(_ started: URL) async {
        guard let url = Self.transcript(for: started), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return end(started, .failed("There is no transcript to summarize."), "no transcript")
        }
        states[started] = .running(0)
        let task = Task {
            try await Summary.make(from: text, progress: { [weak self] value in self?.progress(value) }, abandon: { [weak self] in self?.shouldPause() ?? false })
        }
        current = (started, task)
        let clock = ContinuousClock()
        let begin = clock.now
        do {
            let parts = try await task.value
            let source = current?.source ?? started  // renamed meanwhile
            if task.isCancelled { throw CancellationError() }
            guard let parts else { return end(source, .failed("This Mac cannot summarize this transcript."), "nothing to summarize") }
            // The transcript is looked up again: it may have been renamed. If it is another text now (made again, or
            // edited meanwhile), the summary is not written; the work is done once more on the new text.
            guard let target = Self.transcript(for: source) else { throw RecorderError("The transcript is gone.") }
            do { try TranscriptFile.edit(target, expected: text) { Summary.insert(parts, into: $0) } } catch { return retry(source, "\(error)") }
            log("summary: \(target.lastPathComponent), \(parts.decisions.count) decisions, \(parts.actions.count) actions, \(clock.now - begin)")
            AccessibilityNotification.Announcement("Summary ready").post()
            settle(source, done: true)
        } catch is CancellationError {
            let source = current?.source ?? started
            // Cancelled by the user (no state left) or at quit: nothing more. A recording that started: later, when it is over.
            if case .running = states[source], !shuttingDown { settle(source, done: false, requeue: true) } else { settle(source, done: false) }
        } catch {
            end(current?.source ?? started, .failed("Could not make a summary."), "\(error)")
        }
    }

    /// The summary could not be written: once more from the start, never twice.
    private func retry(_ source: URL, _ reason: String) {
        log("summary: not written for \(source.lastPathComponent) (\(reason))")
        guard retried.insert(source).inserted else { return end(source, .failed("Could not make a summary."), "not written twice") }
        settle(source, done: false, requeue: true)
    }

    /// A summary that did not come: logged; shown only when it was asked for with the button.
    private func end(_ source: URL, _ state: State, _ reason: String) {
        log("summary failed for \(source.lastPathComponent): \(reason)")
        states[source] = manual.remove(source) != nil ? state : nil
        settle(source, done: false)
    }

    /// One run is over. `requeue`: it goes round again. A request that came while it ran also does, unless the transcript has its summary now.
    private func settle(_ source: URL, done: Bool, requeue: Bool = false) {
        current = nil
        let asked = again.remove(source) != nil
        if done { states[source] = nil; manual.remove(source) }
        let text = Self.transcript(for: source).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if !shuttingDown, requeue || (asked && Summary.parts(in: text) == nil) { enqueue(source) } else if case .running = states[source] { states[source] = nil }
        onIdle()
    }

    private func progress(_ value: Double) {
        guard let source = current?.source, case .running(let before) = states[source] else { return }
        states[source] = .running(max(before, value))  // a pass that was planned late must not move the bar back
    }

    /// Where the transcript of a recording is now.
    static func transcript(for source: URL) -> URL? {
        let stem = source.deletingPathExtension()
        return [stem.appendingPathExtension("md"), stem.appendingPathExtension("transcript.md")].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Self check of the queue (no model is asked: the recordings have no transcript, so every run ends at once).
    static func selfTest() async -> [String] {
        var failures: [String] = []
        guard Summary.isAvailable else { return failures }
        let summarizer = Summarizer()
        var paused = true
        summarizer.shouldPause = { paused }
        let old = URL(fileURLWithPath: "/nonexistent/old.m4a"), new = URL(fileURLWithPath: "/nonexistent/new.m4a")
        summarizer.request(old)
        summarizer.moved(old, to: new)  // renamed while the recording that pauses it runs
        if summarizer.states[new] != .waiting || summarizer.states[old] != nil { failures.append("a rename while waiting keeps the request: \(summarizer.states)") }
        paused = false
        try? await Task.sleep(for: .seconds(2.5))
        if summarizer.states[new] != nil || summarizer.isBusy { failures.append("a request renamed while waiting still ends: \(summarizer.states)") }
        return failures
    }
}
