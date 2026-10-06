import Foundation

// Logic fixture for Core/Shared/UtterancePause.swift. Time is injected; nothing sleeps.
func check(_ ok: Bool, _ message: String, line: Int = #line) {
    if !ok { FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8)); exit(1) }
}
let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

// Effective pause: default, clamping, terminal punctuation.
check(UtterancePause.effectivePause(1.0, after: "hello there") == 1.0, "plain pause unchanged")
check(UtterancePause.effectivePause(1.0, after: "hello there.") == 0.7, "period shortens")
check(UtterancePause.effectivePause(2.5, after: "what?") == 0.7, "question mark shortens")
check(UtterancePause.effectivePause(2.5, after: "stop!  ") == 0.7, "exclamation shortens, trailing space ignored")
check(UtterancePause.effectivePause(2.5, after: "he said \"go.\"") == 0.7, "closing quote ignored")
check(UtterancePause.effectivePause(0.5, after: "done.") == 0.5, "never lengthens a short pause")
check(UtterancePause.effectivePause(0.1, after: "and") == 0.5, "clamped up to 0.5")
check(UtterancePause.effectivePause(9, after: "and") == 3.0, "clamped down to 3.0")
check(UtterancePause.effectivePause(1.0, after: "") == 1.0, "empty text")
check(UtterancePause.effectivePause(1.0, after: "wait,") == 1.0, "comma does not shorten")
print("PASS effective pause: default, clamp, punctuation")

// Qualifying words.
check(UtterancePause.qualifyingWords(in: "a I") == 0, "one-letter words don't count")
check(UtterancePause.qualifyingWords(in: "I am here") == 2, "am and here count")
check(UtterancePause.qualifyingWords(in: "12 ...") == 0, "digits and punctuation don't count")
print("PASS qualifying words")

// Barge-in, 1-word rule (headphones): fires once at the first qualifying word.
var one = UtterancePause(pause: 1, giveUp: 8, minimumWords: 1, opened: at(0))
check(!one.heard("", at: at(0.1)), "empty text no barge-in")
check(!one.heard("a", at: at(0.2)), "one-letter word no barge-in")
check(one.heard("so", at: at(0.3)), "first qualifying word barges in")
check(!one.heard("so then", at: at(0.4)), "no second barge-in")
check(!one.heard("so then we", at: at(0.5)), "still only once")
print("PASS barge-in, 1-word rule")

// 2-word rule (speaker).
var two = UtterancePause(pause: 1, giveUp: 8, minimumWords: 2, opened: at(0))
check(!two.heard("hello", at: at(0.1)), "one word is not enough")
check(!two.heard("hello a", at: at(0.2)), "a does not count")
check(two.heard("hello there", at: at(0.3)), "second qualifying word barges in")
check(!two.heard("hello there friend", at: at(0.4)), "no second barge-in")
check(!two.heard("hello there", at: at(0.5)), "revision does not refire")
print("PASS barge-in, 2-word rule")

// .send after the pause with words; the clock restarts when the text changes.
var send = UtterancePause(pause: 1, giveUp: 8, minimumWords: 1, opened: at(0))
check(send.due(at: at(0.5)) == nil, "nothing yet")
_ = send.heard("turn on the", at: at(2))
check(send.due(at: at(2.9)) == nil, "not due before the pause")
check(send.due(at: at(3.0)) == .send("turn on the"), "due after the pause")
_ = send.heard("turn on the lights", at: at(3.5))
check(send.due(at: at(4.4)) == nil, "new words restart the pause")
check(send.due(at: at(4.5)) == .send("turn on the lights"), "due after the new pause")
_ = send.heard("turn on the lights.", at: at(5))
check(send.due(at: at(5.69)) == nil, "sentence end: not yet at 0.69 s")
check(send.due(at: at(5.7)) == .send("turn on the lights."), "sentence end sends after 0.7 s")
var padded = UtterancePause(pause: 1, giveUp: 8, minimumWords: 1, opened: at(0))
_ = padded.heard("  hi there \n", at: at(1))
check(padded.due(at: at(2)) == .send("hi there"), "words are trimmed")
var blank = UtterancePause(pause: 1, giveUp: 2, minimumWords: 1, opened: at(0))
_ = blank.heard("   ", at: at(0.5))
check(blank.due(at: at(1.9)) == nil && blank.due(at: at(2)) == .silent, "whitespace is not speech")
print("PASS send after pause with words")

// .silent after giveUp when nothing was heard (counted from when it opened).
let quiet = UtterancePause(pause: 1, giveUp: 8, minimumWords: 1, opened: at(10))
check(quiet.due(at: at(17.9)) == nil, "not yet")
check(quiet.due(at: at(18)) == .silent, "silent after giveUp")
var spoke = UtterancePause(pause: 1, giveUp: 8, minimumWords: 1, opened: at(0))
_ = spoke.heard("hey", at: at(1))
check(spoke.due(at: at(9)) == .send("hey"), "words beat giveUp")
print("PASS silent after giveUp")

// Rotation: an empty request open for more than 50 s is replaced; one with words isn't.
let empty = UtterancePause(pause: 1, giveUp: 600, minimumWords: 1, opened: at(0))
check(!empty.shouldRotate(openedAt: at(0), now: at(50)), "not at exactly 50 s")
check(empty.shouldRotate(openedAt: at(0), now: at(50.1)), "rotates after 50 s")
check(!empty.shouldRotate(openedAt: at(40), now: at(80)), "counts from the request opening")
var words = empty
_ = words.heard("hello", at: at(10))
check(!words.shouldRotate(openedAt: at(0), now: at(60)), "never rotates with words")
print("PASS rotation")
