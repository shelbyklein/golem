import Foundation
// MobileTranscriptCache: saved transcripts read back exactly, only the 30 newest are kept,
// and disconnecting clears them. Runs against a temporary folder, never the real cache.
func check(_ ok: Bool, _ what: String) { precondition(ok, what); print("PASS \(what)") }
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-cache-\(UUID().uuidString)")
setenv("CHATTERBOX_TEST_TRANSCRIPT_CACHE", folder.path, 1)
func detail(_ id: UUID, _ text: String, revision: Int = 1) -> Companion.ChatDetail {
    let json = """
    {"revision":\(revision),"settings":"Codex · GPT-6 Luna","earlierCount":0,
     "summary":{"id":"\(id.uuidString)","title":"Chat","backend":"codex","isRunning":false,"isWaitingOnYou":false,"updatedAt":"2026-10-08T00:00:00Z"},
     "items":[{"id":"\(UUID().uuidString)","kind":"assistant","text":"\(text)","isStreaming":false,"isCommentary":false,"isPending":false,"attachments":[],"isQueued":false}]}
    """
    return try! Companion.decoder.decode(Companion.ChatDetail.self, from: Data(json.utf8))
}
let first = UUID()
check(MobileTranscriptCache.load(first) == nil, "nothing saved yet means nothing to show")
MobileTranscriptCache.save(detail(first, "Hello from last visit", revision: 7)); MobileTranscriptCache.flush()
let loaded = MobileTranscriptCache.load(first)
check(loaded?.items.first?.text == "Hello from last visit" && loaded?.revision == 7 && loaded?.summary.id == first, "a saved transcript reads back exactly")
MobileTranscriptCache.save(detail(first, "Newer text", revision: 8)); MobileTranscriptCache.flush()
check(MobileTranscriptCache.load(first)?.items.first?.text == "Newer text", "saving again replaces the old copy")
var ids: [UUID] = []
for n in 0..<35 { let id = UUID(); ids.append(id); MobileTranscriptCache.save(detail(id, "chat \(n)")); MobileTranscriptCache.flush(); usleep(20_000) }
let kept = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? 0
check(kept == MobileTranscriptCache.limit, "only the \(MobileTranscriptCache.limit) newest are kept (\(kept))")
check(MobileTranscriptCache.load(ids.last!) != nil && MobileTranscriptCache.load(first) == nil, "the oldest go first")
let list = try! Companion.decoder.decode(Companion.ChatList.self, from: Data(#"{"revision":3,"groups":[{"id":"dot","kind":"dot","title":"Golem","chats":[]}]}"#.utf8))
MobileTranscriptCache.saveList(list); MobileTranscriptCache.flush()
check(MobileTranscriptCache.loadList()?.revision == 3 && MobileTranscriptCache.loadList()?.groups.first?.kind == .dot, "the chat list reads back too")
check(((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? 0) == MobileTranscriptCache.limit, "the chat list doesn't count against the transcript limit")
MobileTranscriptCache.clear(); MobileTranscriptCache.flush()
check(MobileTranscriptCache.load(ids.last!) == nil && MobileTranscriptCache.loadList() == nil, "disconnecting clears every saved transcript and the list")
