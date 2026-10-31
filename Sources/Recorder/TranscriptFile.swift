import Foundation

/// The one way a transcript changes after it is made (its summary, Replace, speaker names): read, change and write
/// in one step on the main actor, so two of them never interleave, and Edit > Undo puts the previous text back.
@MainActor
enum TranscriptFile {
    /// `transform` gets the file's text and returns the new text, or nil to leave the file as it is.
    /// `expected`: the text the caller worked from; when the file holds something else now (a new transcript,
    /// an edit in another app), nothing is written. Returns the text written, or nil when nothing changed.
    @discardableResult
    static func edit(_ url: URL, expected: String? = nil, undo: UndoManager? = nil, action: String = "", _ transform: (String) -> String?) throws -> String? {
        let old = try String(contentsOf: url, encoding: .utf8)
        if let expected, expected != old { throw RecorderError("The transcript changed meanwhile. Try again.") }
        guard let new = transform(old), new != old else { return nil }
        try new.write(to: url, atomically: true, encoding: .utf8)
        if let undo {
            // Undo writes the old text back through here, so it registers the redo, and it refuses once the file
            // changed again (Transcribe Again made a new one): an undo never overwrites a newer transcript.
            undo.registerUndo(withTarget: undo) { undo in
                MainActor.assumeIsolated {
                    do { try edit(url, expected: new, undo: undo, action: action) { _ in old } } catch { log("transcript undo: \(error.localizedDescription)") }
                }
            }
            if !action.isEmpty { undo.setActionName(action) }
        }
        return new
    }

    static func selfTest(in root: URL) -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        let url = root.appending(path: "edit.md")
        try? "one".write(to: url, atomically: true, encoding: .utf8)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let read = { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        undo.beginUndoGrouping()
        let wrote = try? edit(url, undo: undo, action: "Replace All") { $0 + " two" }
        undo.endUndoGrouping()
        expect(wrote == "one two" && read() == "one two", "an edit writes the file: \(read())")
        expect(undo.undoActionName == "Replace All", "the undo is named: \(undo.undoActionName)")
        undo.undo()
        expect(read() == "one", "undo puts the old text back: \(read())")
        undo.redo()
        expect(read() == "one two", "redo writes it again: \(read())")
        expect((try? edit(url) { _ in nil }) == .some(nil) && read() == "one two", "no change, no write")
        expect((try? edit(url, expected: "stale") { _ in "x" }) == nil && read() == "one two", "a changed file is not overwritten")
        try? "new transcript".write(to: url, atomically: true, encoding: .utf8)
        undo.undo()
        expect(read() == "new transcript", "an undo does not overwrite a newer transcript: \(read())")
        return failures
    }
}
