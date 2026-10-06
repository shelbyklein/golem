import Foundation

// Logic fixture for streaming speech segmentation. No audio, no network.
var failures = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { print("PASS \(name)") } else { print("FAIL \(name) \(detail())"); failures += 1 }
}
func precondition(_ ok: Bool, _ name: String) {
    if !ok { print("Precondition failed: \(name)"); exit(1) }
}
func words(_ parts: [String]) -> [String] { parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init) }

// MARK: cut

do {
    let r = SpeechSegments.cut("Hello there. How are you? Fine!", final: false)
    precondition(r.segments.count == 2, "two sentences with a following space")
    check(r.segments == ["Hello there.", "How are you?"], "sentence cuts", "\(r.segments)")
    check(r.consumed == "Hello there. How are you? ".count, "consumed covers sentences and the space, not the tail", "\(r.consumed)")
    let f = SpeechSegments.cut("Hello there. How are you? Fine!", final: true)
    check(f.segments == ["Hello there.", "How are you?", "Fine!"] && f.consumed == 31, "final turns the remainder into a segment", "\(f)")
    check(SpeechSegments.cut("No end yet", final: false).segments.isEmpty, "unfinished text waits")
    check(SpeechSegments.cut("Wait.", final: false).segments.isEmpty, "punctuation without a following space waits")
}

do {
    let r = SpeechSegments.cut("Dr. Smith met Mr. Jones and Mrs. Lee vs. Ms. Kay, e.g. Tom, i.e. Bob. Done. ", final: false)
    check(r.segments == ["Dr. Smith met Mr. Jones and Mrs. Lee vs. Ms. Kay, e.g. Tom, i.e. Bob.", "Done."], "abbreviations are not sentence ends", "\(r.segments)")
}

do {
    let list = "Steps:\n1. Open it\n2. Close it\n10. Done\n"
    let r = SpeechSegments.cut(list, final: false)
    check(r.segments.isEmpty, "list numbers are not sentence ends", "\(r.segments)")
    check(SpeechSegments.cut(list, final: true).segments == ["Steps:\n1. Open it\n2. Close it\n10. Done"], "list lines stay together until the end")
    let indented = SpeechSegments.cut("Intro\n 3. Third item here\n", final: false)
    check(indented.segments.isEmpty, "an indented list number is not a sentence end", "\(indented.segments)")
    check(SpeechSegments.cut("It was 2024. Then it ended. ", final: false).segments == ["It was 2024.", "Then it ended."], "four digits and mid-line numbers end a sentence")
    check(SpeechSegments.cut("About 3. Then 4. ", final: false).segments == ["About 3.", "Then 4."], "mid-line 1-digit numbers end a sentence")
}

do {
    let q = SpeechSegments.cut("He said \"Stop.\" Then he left (quietly.) Okay. ", final: false)
    check(q.segments == ["He said \"Stop.\"", "Then he left (quietly.)", "Okay."], "closing quote or paren stays with the sentence", "\(q.segments)")
    let e = SpeechSegments.cut("Wait\u{2026} what? Hmm... fine. And 3.14 is pi. ", final: false)
    check(e.segments == ["Wait\u{2026}", "what?", "Hmm...", "fine.", "And 3.14 is pi."], "ellipsis and decimals", "\(e.segments)")
    let u = SpeechSegments.cut("Dots... ", final: false)
    check(u.segments == ["Dots..."], "a plain ellipsis ends a sentence", "\(u.segments)")
}

do {
    let p = SpeechSegments.cut("A heading\n\nFirst paragraph without a period\n \nSecond", final: false)
    check(p.segments == ["A heading", "First paragraph without a period"], "paragraph breaks cut", "\(p.segments)")
    check(p.consumed == "A heading\n\nFirst paragraph without a period\n \n".count, "consumed through the blank line", "\(p.consumed)")
    check(SpeechSegments.cut("One line\nSecond line", final: false).segments.isEmpty, "a single newline is not a cut")
}

do {
    let sentence = (1...200).map { "word\($0)" }.joined(separator: ", ") + "."
    precondition(sentence.count > 600, "long sentence is longer than 600")
    let ended = SpeechSegments.cut(sentence + " Next. ", final: false)
    check(ended.segments.dropLast().allSatisfy { $0.count <= 600 } && ended.segments.count >= 3, "long sentence is cut into pieces of at most 600", "\(ended.segments.map(\.count))")
    check(ended.segments.dropLast().dropLast().allSatisfy { $0.hasSuffix(",") }, "long sentence is cut at commas", "\(ended.segments.map { String($0.suffix(3)) })")
    check(words(ended.segments) == words([sentence, "Next."]), "long sentence loses nothing")
    let spaces = (1...200).map { "alpha\($0)" }.joined(separator: " ") + ". "
    let s = SpeechSegments.cut(spaces, final: false)
    check(s.segments.dropLast().allSatisfy { $0.count <= 600 } && words(s.segments) == words([spaces]), "no comma: cut at a space, nothing split mid-word", "\(s.segments.map(\.count))")
    let open = SpeechSegments.cut(sentence.dropLast(30) + "", final: false)
    precondition(sentence.count - 30 > 600, "unfinished text is longer than 600")
    check(!open.segments.isEmpty && open.consumed < sentence.count - 30 && open.segments.allSatisfy { $0.count <= 600 },
          "an over-long unfinished sentence speaks its first part now", "\(open.segments.count) \(open.consumed)")
}

// MARK: merge

do {
    let s = (1...30).map { "Sentence number \($0) is short." }
    let m = SpeechSegments.merge(s)
    precondition(m.count > 1, "merge produced several groups")
    check(m.allSatisfy { $0.count <= 240 }, "merged segments are at most 240 characters", "\(m.map(\.count))")
    check(m.joined(separator: " ") == s.joined(separator: " "), "merge keeps order and content")
    check(SpeechSegments.merge(["a", String(repeating: "x", count: 300), "b"]) == ["a", String(repeating: "x", count: 300), "b"], "an over-long sentence stands alone")
    check(SpeechSegments.merge(["a", "b"], limit: 3) == ["a b"] && SpeechSegments.merge(["a", "bb"], limit: 3) == ["a", "bb"], "merge limit is honored")
}

// MARK: incremental feeding (raw cut)

let sample = "Intro line. Dr. Who said \"Hello.\" Then 3 things happened:\n1. One\n2. Two\n\nA new paragraph starts here! Is it? Yes\u{2026} it is. And a final bit without end"
do {
    let all = SpeechSegments.cut(sample, final: true).segments
    let cuts = [0, 17, 60, 95, 140, sample.count]
    var rest = "", used = 0, got: [String] = []
    for k in 1..<cuts.count {
        let fed = String(sample.prefix(cuts[k]))
        let r = SpeechSegments.cut(String(fed.dropFirst(used)), final: k == cuts.count - 1)
        got += r.segments; used += r.consumed; rest = fed
    }
    precondition(all.count >= 5, "sample has several segments")
    check(got == all, "five pieces give the same segments as all at once", "\(got) vs \(all)")
    check(used == sample.count && rest == sample, "everything consumed after final")
}

// MARK: the segmenter (cleaning + cutting)

let markdown = """
# Plan for today

I **finished** the [login page](https://example.com/login) and read https://example.com/docs/page. It works!

| Name | Status |
|------|--------|
| Login | Done |
| Signup | Pending |

- First item is *ready*
- Second item uses `code`
1. A numbered point
2. Another numbered point

```swift
let x = 1. Not spoken.
```

See /Users/me/Projects/app/main.swift for details. Dr. Who agrees. Final sentence without end
"""

func run(_ text: String, pieces: [Int]) -> (segments: [String], seg: SpeechSegmenter) {
    var seg = SpeechSegmenter(), out: [String] = []
    var from = text.startIndex
    for (k, n) in pieces.enumerated() {
        let to = k == pieces.count - 1 ? text.endIndex : text.index(from, offsetBy: n)
        out += seg.feed(String(text[..<to]), final: k == pieces.count - 1)
        from = to
    }
    return (out, seg)
}
func normalized(_ segments: [String]) -> String { words(segments).joined(separator: " ") }

do {
    let once = run(markdown, pieces: [markdown.count])
    let spoken = normalized(once.segments)
    check(spoken == normalized([SpeechSegments.spoken(markdown)]), "streamed words equal spoken() of the whole text", "\(spoken)\n\(SpeechSegments.spoken(markdown))")
    check(spoken.contains("login page") && !spoken.contains("example.com/login") && spoken.contains("a link"), "links are named, bare URLs become 'a link'")
    check(spoken.contains("Login, Done.") && spoken.contains("Signup, Pending."), "table rows are read row by row", spoken)
    check(spoken.contains("(code in the chat)") && !spoken.contains("Not spoken") && spoken.contains("main.swift") && !spoken.contains("/Users"), "code blocks and paths are shortened")
    check(spoken.hasSuffix("Final sentence without end"), "the final remainder is spoken")

    var chunks = [Int](), cuts = [0, 50, 160, 300, markdown.count - 20, markdown.count]
    for k in 1..<cuts.count { chunks.append(cuts[k] - cuts[k - 1]) }
    let five = run(markdown, pieces: chunks)
    check(five.segments.count >= 2 && normalized(five.segments) == spoken, "markdown in 5 pieces: nothing repeated or lost", "\(normalized(five.segments))")

    let single = run(markdown, pieces: Array(repeating: 1, count: markdown.count))
    check(normalized(single.segments) == spoken, "markdown one character at a time: nothing repeated or lost", "\(normalized(single.segments))")

    var odd = 0
    for step in [3, 7, 13, 29, 41] {
        let r = run(markdown, pieces: Array(repeating: step, count: markdown.count / step + 1))
        if normalized(r.segments) != spoken { odd += 1; print("  step \(step): \(normalized(r.segments))") }
    }
    check(odd == 0, "arbitrary split points (mid-link, mid-bold, mid-table-row, mid-fence) give the same words")
}

do {
    var seg = SpeechSegmenter()
    let first = seg.feed("First sentence here. Second one follows. Thi", final: false)
    check(first == ["First sentence here. Second one follows."], "a segment is ready before the reply ends", "\(first)")
    precondition(!seg.ended, "not final yet")
    check(seg.feed("First sentence here. Second one follows. Thi", final: false).isEmpty, "the same text again yields nothing")
    let last = seg.feed("First sentence here. Second one follows. Third, done", final: true)
    check(last == ["Third, done"], "final flushes the remainder once", "\(last)")
    check(seg.feed("First sentence here. Second one follows. Third, done and more", final: true).isEmpty, "nothing after final")
}

do {
    var seg = SpeechSegmenter()
    let head = seg.feed("A table:\n| Name | Status |\n| Login | Do", final: false)
    check(head.count == 1 && words(head) == ["A", "table:", "Name,", "Status."], "a finished row is read, the half-written one waits", "\(head)")
    let row = seg.feed("A table:\n| Name | Status |\n| Login | Done |\n", final: false)
    check(row == ["Login, Done."], "the row is read once complete", "\(row)")
    var open = SpeechSegmenter()
    check(open.feed("Before. \n```\ncode. here. more.", final: false) == ["Before."], "an open code fence is held back")
    check(open.feed("Before. \n```\ncode. here. more.\n```\nAfter it. ", final: false) .map({ words([$0]) }) == [["(code", "in", "the", "chat)", "After", "it."]], "and spoken as one note once closed")
}

do {
    let long = (1...400).map { "Sentence number \($0) says something." }.joined(separator: " ")
    precondition(long.count > SpeechSegments.spokenLimit, "reply longer than the cap")
    var seg = SpeechSegmenter(), out: [String] = []
    var from = 0
    while from < long.count { from = min(from + 700, long.count); out += seg.feed(String(long.prefix(from)), final: from == long.count) }
    let total = out.joined(separator: " ")
    check(seg.capped && total.hasSuffix(SpeechSegments.capTail) && total.count <= SpeechSegments.spokenLimit + 40, "long replies are capped with 'The rest is in the chat.'", "\(total.count) \(total.suffix(40))")
    check(SpeechSegments.spoken(long).hasSuffix(". " + SpeechSegments.capTail) && SpeechSegments.spoken(long).count <= SpeechSegments.spokenLimit + 40, "spoken() keeps the cap")
}

do {
    var seg = SpeechSegmenter()
    _ = seg.feed("One two three. Four five six. ", final: false)
    let changed = seg.feed("One two THREE. Four five six. Seven. ", final: false)
    check(!changed.isEmpty && !changed.joined().contains("Four five six. Seven. Four"), "an edited text continues without crashing", "\(changed)")
    check(SpeechSegments.spoken("") == "" && SpeechSegments.spoken("  \n ") == "", "empty text says nothing")
    check(SpeechSegments.spoken("| a | b |") == "a, b.", "spoken(): a table row", SpeechSegments.spoken("| a | b |"))
    check(SpeechSegments.spoken("Read [this](http://x.y/z) or http://x.y/z.") == "Read this or a link.", "spoken(): link text and bare link", SpeechSegments.spoken("Read [this](http://x.y/z) or http://x.y/z."))
}

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
