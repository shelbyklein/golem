import Foundation
func check(_ ok: Bool, _ what: String) { precondition(ok, what); print("PASS \(what)") }
let utc = TimeZone(identifier: "UTC")!
let now = ISO8601DateFormatter().date(from: "2026-10-06T15:12:00Z")!
check(GolemQuickPrompts.expand("since {since} until {now}", now: now, timeZone: utc) == "since Oct 6, 2:12 PM until Oct 6, 3:12 PM", "fills {since} (an hour ago) and {now}")
let midnight = ISO8601DateFormatter().date(from: "2026-10-07T00:30:00Z")!
check(GolemQuickPrompts.expand("{since}", now: midnight, timeZone: utc) == "Oct 6, 11:30 PM", "an hour before midnight keeps the right date")
check(GolemQuickPrompts.decode(Data()) == GolemQuickPrompts.defaults && GolemQuickPrompts.defaults.first?.label == "Catch me up", "nothing saved means the defaults")
check(GolemQuickPrompts.decode(Data("junk".utf8)) == GolemQuickPrompts.defaults, "unreadable data falls back to the defaults")
let custom = [GolemQuickPrompt(label: "Plan", text: "Plan my afternoon from {now}")]
check(GolemQuickPrompts.decode(GolemQuickPrompts.encode(custom)) == custom, "edited list round-trips")
check(GolemQuickPrompts.decode(GolemQuickPrompts.encode([])).isEmpty, "an emptied list stays empty (no chips)")
