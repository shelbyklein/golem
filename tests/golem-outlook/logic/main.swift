import Foundation
// OutlookWatch: dedupe, cap, ordering, continuation, baseline, and failures that never look empty.
func check(_ ok: Bool, _ what: String) { precondition(ok, what); print("PASS \(what)") }
func msg(_ id: String, summary: String = "A summary.") -> OutlookWatch.Message {
    .init(id: id, link: "https://outlook.cloud.microsoft/mail/inbox/id/\(id)", from: "Sam", subject: "S \(id)", received: "Fri", summary: summary,
          actions: ["Reply by Friday"], deadlines: ["Fri 5pm"], links: ["https://example.com/a"], important: false, unreadRestored: true)
}
func answer(_ status: String = "ok", inbox: [String], processed: [OutlookWatch.Message] = [], error: String = "") -> OutlookWatch.Answer {
    .init(status: status, error: error, account: "me@example.org", inboxIDs: inbox, processed: processed)
}

// Baseline: the first run records the listed inbox as known (newest last) and opens nothing.
if case .baseline(let known) = OutlookWatch.evaluate(answer(inbox: ["c", "b", "a"]), known: [], baseline: true) {
    check(known == ["a", "b", "c"], "first run records the inbox as already seen, newest last")
} else { check(false, "first run is a baseline") }

// A normal run: new messages are kept and remembered; known ones are dropped.
let known = ["a", "b", "c"]
if case .processed(let got, let now) = OutlookWatch.evaluate(answer(inbox: ["e", "d", "c"], processed: [msg("d"), msg("e"), msg("c")]), known: known, baseline: false) {
    check(got.map(\.id) == ["d", "e"], "new messages are kept, oldest first; an already-read one is skipped")
    check(now == ["a", "b", "c", "d", "e"], "only messages actually read are remembered")
} else { check(false, "normal run processes") }

// Duplicates in one answer, and empty or unsummarized entries, don't count.
if case .processed(let got, _) = OutlookWatch.evaluate(answer(inbox: ["f"], processed: [msg("f"), msg("f"), msg(""), msg("g", summary: "")]), known: known, baseline: false) {
    check(got.map(\.id) == ["f"], "duplicates, missing ids and unsummarized messages are dropped")
} else { check(false, "dedupe run processes") }

// The cap: at most perRun a run; the rest stay unknown so the next run gets them.
let many = (1...14).map { "n\($0)" }
if case .processed(let got, let now) = OutlookWatch.evaluate(answer(inbox: many.reversed(), processed: many.map { msg($0) }), known: known, baseline: false) {
    check(got.count == OutlookWatch.perRun && got.first?.id == "n1", "at most \(OutlookWatch.perRun) a run, oldest first")
    check(!now.contains("n11") && now.contains("n10"), "messages past the cap stay new for the next run")
} else { check(false, "capped run processes") }

// Failures never look like an empty inbox, and nothing is remembered from them.
check(OutlookWatch.evaluate(answer("signedOut", inbox: []), known: known, baseline: false) == .failure("Outlook in Chrome is signed out. Sign in again and the watcher will pick up where it left off."), "signed out is a failure")
if case .failure(let why) = OutlookWatch.evaluate(answer("unavailable", inbox: [], error: "extension not connected"), known: known, baseline: false) {
    check(why.contains("extension not connected"), "unavailable is a failure that says why")
} else { check(false, "unavailable fails") }
if case .failure = OutlookWatch.evaluate(answer(inbox: []), known: known, baseline: false) { check(true, "\"ok\" with an empty inbox is treated as a failed load") } else { check(false, "empty inbox fails") }
if case .failure = OutlookWatch.evaluate(answer(inbox: []), known: [], baseline: true) { check(true, "a first run that sees no inbox doesn't record a baseline") } else { check(false, "empty baseline fails") }

// Memory stays bounded and keeps the newest.
let long = OutlookWatch.remember((1...600).map { "m\($0)" }, ["m3", "z"])
check(long.count == OutlookWatch.rememberLimit && long.last == "z" && long.dropLast().last == "m3" && !long.contains("m1"), "remembered ids are bounded, newest kept, repeats moved to newest")

// The prompt stops at the newest known ids and asks for the newest-first listing.
let p = OutlookWatch.prompt(name: "Golem", memory: "/mem", known: (1...80).map { "k\($0)" }, baseline: false)
check(p.contains("- k80") && p.contains("- k21") && !p.contains("- k20\n") && p.contains("oldest \(OutlookWatch.perRun)"), "the sweep gets the newest \(OutlookWatch.promptKnown) known ids as its stopping points")
check(OutlookWatch.prompt(name: "Golem", memory: "/mem", known: [], baseline: true).contains("Don't open any message"), "the first run's prompt opens nothing")

// Journal text carries the action, deadline and a link back; scratch folders are recognized.
let text = OutlookWatch.journalText(msg("x"))
check(text.contains("For you: Reply by Friday") && text.contains("Deadlines: Fri 5pm") && text.contains("Open in Outlook: https://"), "the Journal entry has the action item, deadline and link")
check(OutlookWatch.isScratch("golem-outlook-\(UUID().uuidString)") && !OutlookWatch.isScratch("golem-outlook-notes") && !OutlookWatch.isScratch("chatterbox-email-x"), "only the watcher's own scratch folders are cleaned up")
check((try? JSONSerialization.jsonObject(with: Data(OutlookWatch.schema.utf8))) != nil, "the answer schema is valid JSON")
