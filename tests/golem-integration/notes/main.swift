import Foundation
// GolemNotes.parse: what counts as a note confirmation in Golem's replies.
func check(_ ok: Bool, _ what: String) { precondition(ok, what); print("PASS \(what)") }
let reply = """
Sure, done.
Noted: buy furnace filters
- **Noted:** call the dentist Thursday
📝 Noted: "renew the passport"
I noted that yesterday.
Notes: this is not a confirmation
Deleted note: buy furnace filters
noted:
"""
let found = GolemNotes.parse(reply)
check(found.added == ["buy furnace filters", "call the dentist Thursday", "renew the passport"], "adds plain, bold-bulleted and quoted Noted: lines (\(found.added))")
check(found.deleted == ["buy furnace filters"], "reads Deleted note: lines")
check(GolemNotes.parse("We noted it. Notes: none.").added.isEmpty, "ignores prose that only mentions notes")
check(GolemNotes.same("Buy furnace filters.", "buy furnace filters"), "matching ignores case and punctuation")
check(GolemNotes.matches("call the dentist Thursday", "dentist") && !GolemNotes.matches("call the dentist", "the"), "partial deletion needs a real fragment")
