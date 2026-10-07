import Foundation

// Logic fixture for Core/Shared/UtteranceTranscript.swift: per-utterance bookkeeping for a long-running recognizer.
func check(_ ok: Bool, _ message: String, line: Int = #line) {
    if !ok { FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8)); exit(1) }
}

// Volatile results replace each other; a final one is kept.
var t = UtteranceTranscript()
check(t.apply("hel", isFinal: false, start: 0.2, end: 0.5), "first volatile")
check(t.apply("hello", isFinal: false, start: 0.2, end: 0.8), "volatile replaces overlapping volatile")
check(t.text == "hello", "text is the latest volatile: \(t.text)")
check(!t.apply("hello", isFinal: false, start: 0.2, end: 0.8), "same text reports no change")
t.apply("Hello there.", isFinal: true, start: 0.2, end: 1.4)
check(t.text == "Hello there.", "final replaces volatile: \(t.text)")
t.apply("how", isFinal: false, start: 1.6, end: 1.9)
check(t.text == "Hello there. how", "volatile appended after final with a space: \(t.text)")
t.apply("how are you?", isFinal: false, start: 1.6, end: 2.6)
check(t.text == "Hello there. how are you?", "later volatile replaces: \(t.text)")
print("PASS volatile replace, final kept")

// Pieces already carrying whitespace aren't double-spaced.
var w = UtteranceTranscript()
w.apply("one ", isFinal: true, start: 0, end: 1)
w.apply("two", isFinal: true, start: 1, end: 2)
check(w.text == "one two", "no double space: \(w.text)")
print("PASS joining")

// Next utterance starts empty; late results for the previous one are ignored.
var u = UtteranceTranscript()
u.apply("first turn", isFinal: false, start: 0.3, end: 2.0)
u.reset(boundary: 4.0)
check(u.text.isEmpty, "reset starts empty")
check(!u.apply("first turn.", isFinal: true, start: 0.3, end: 2.1), "late final of previous turn ignored")
check(u.text.isEmpty, "still empty after late final")
check(!u.apply("older", isFinal: false, start: 3.0, end: 4.0), "ending exactly at the boundary is ignored")
check(u.apply("second", isFinal: false, start: 4.5, end: 5.0), "new speech accepted")
check(u.text == "second", "only new words: \(u.text)")
print("PASS utterance boundary")

// Untimed results are always current.
var n = UtteranceTranscript(boundary: 10)
check(n.apply("hi there", isFinal: false, start: .nan, end: .nan), "untimed accepted")
check(n.text == "hi there", "untimed text")
print("PASS untimed")
