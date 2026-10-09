import Foundation
// ReplyQueue: Golem's messages are read whole, in order, and never twice.
func check(_ ok: Bool, _ what: String) { precondition(ok, what); print("PASS \(what)") }
var q = ReplyQueue()
let a = UUID(), b = UUID(), c = UUID()
check(q.offer(a, text: "First.", final: false, then: nil, reading: nil) == .read, "nothing playing: the first message is read")
check(q.offer(a, text: "First. More.", final: false, then: nil, reading: a) == .read, "the message being read keeps receiving its text")
check(q.offer(b, text: "Second", final: false, then: nil, reading: a) == .wait, "a new message waits instead of cutting the first off")
check(q.offer(b, text: "Second, longer.", final: true, then: nil, reading: a) == .wait && q.waiting.count == 1 && q.waiting[0].text == "Second, longer." && q.waiting[0].final,
      "a waiting message keeps its latest text and stays complete")
check(q.offer(c, text: "Third.", final: true, then: nil, reading: a) == .wait && q.waiting.map(\.id) == [b, c], "messages wait in the order they arrived")
check(q.finished(a)?.id == b, "when the first is done, the next one starts")
check(q.offer(a, text: "First, revised after it was read.", final: true, then: nil, reading: b) == .skip, "a message already read is never read again, even if it changes")
check(q.finished(b)?.id == c && q.finished(c) == nil, "then the third; then nothing is left")
check(q.offer(b, text: "Second.", final: true, then: nil, reading: nil) == .skip, "nor once nothing is playing")
var s = ReplyQueue()
let d = UUID(), e = UUID()
_ = s.offer(d, text: "x", final: false, then: nil, reading: nil); _ = s.offer(e, text: "y", final: false, then: nil, reading: d)
s.stopped(d)
check(s.waiting.isEmpty && s.offer(d, text: "x", final: true, then: nil, reading: nil) == .skip && s.offer(e, text: "y", final: true, then: nil, reading: nil) == .skip,
      "stop drops the message being read and everything waiting")
s.restart(d)
check(s.offer(d, text: "x", final: true, then: nil, reading: nil) == .read, "Listen reads a message again on request")
