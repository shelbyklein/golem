import Foundation

@MainActor enum EmailSweep {
    nonisolated private static let runner=EmailSweepRunner()
    static func cancel(){runner.cancel()}
    struct Email: Codable, Equatable {
        var account: String
        var from: String
        var subject: String
        var why: String
        var action: String
        var link: String
        var id: String
    }

    static func prompt(name: String, since: Date, until: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        let iso = ISO8601DateFormatter()
        return """
        You are \(name)'s email sweep, running in the background for the user. Find the email that arrived in all of the user's Gmail accounts between \(format.string(from: since)) and \(format.string(from: until)) (\(iso.string(from: since)) to \(iso.string(from: until)) UTC). Use your Gmail tools. Only read: never send, draft, archive, label, mark as read, delete, or change anything.

        To find it, search each account with exactly this query: after:\(Int(since.timeIntervalSince1970)) before:\(Int(until.timeIntervalSince1970)) -in:sent -in:drafts (Gmail reads those numbers as exact moments). Every result is in the window; don't filter by time yourself, since Gmail mixes time zones in its timestamps. Page through all results. Judge each message's sender and subject first and open only the ones that could matter; obvious newsletters, promotions and automated receipts can be set aside from their metadata, so a busy window doesn't overflow your context.

        First read the user's notes: \(RuntimePaths.assistantMemoryFolder.path)/MEMORY.md and the files it points to (especially the accounts and \(name)'s jobs). Follow them on what counts as important. Flag verified, contextual matters requiring a decision or meaningful new information: school, appointments, life-admin deadlines, clients and work requests (USA Archery and its forwards included), and personal messages from real people. Read the relevant message/thread before deciding; a subject or snippet saying an announcement might contain updates is not enough.

        Routine mail stays quiet: newsletters, promotions, receipts with nothing to do, ordinary bill-available notices with automatic payment already scheduled, routine sign-ins on a known device, and anything already replied to. Automated project alerts may matter when they show a concrete unresolved fault, deadline, or material worsening; do not flag routine status or repeat alerts. The later briefing will correlate important project mail with its existing project chat. Do not invent urgency or propose work just to make an ordinary message actionable.

        Access is part of the result: search every configured Gmail account in the account notes. Return status "ok" only when Gmail tools actually completed those searches and you inspected enough context to classify the results. List the account addresses you successfully checked in accountsChecked. If a tool is absent, an account is inaccessible, a page fails, or the checks are incomplete, return status "unavailable", a short error without credentials, and emails []. An inaccessible inbox is never a successful empty inbox.

        Answer with the JSON the schema asks for: "emails", most important first, at most 8. Leave it empty when nothing needs the user; that's the usual case. For each email: account (the address it arrived at), from (the sender's name), subject, why (one short sentence on why it matters to the user), action (one short suggested next step), link (a Gmail web link to the message if your tools give one, otherwise ""), and id (the message's id).
        """
    }

    nonisolated static let schema = """
    {"type":"object","additionalProperties":false,"required":["status","accountsChecked","error","emails"],"properties":{"status":{"type":"string","enum":["ok","unavailable"]},"accountsChecked":{"type":"array","items":{"type":"string"}},"error":{"type":"string"},"emails":{"type":"array","maxItems":8,"items":{"type":"object","additionalProperties":false,"required":["account","from","subject","why","action","link","id"],"properties":{"account":{"type":"string"},"from":{"type":"string"},"subject":{"type":"string"},"why":{"type":"string"},"action":{"type":"string"},"link":{"type":"string"},"id":{"type":"string"}}}}}}
    """

    enum Outcome {
        case success([Email], accounts: [String])
        case failure(String)
    }

    /// One `codex exec`: read-only, kept out of Codex's history, stopped after ten minutes.
    static func run(codex: String, model: String, prompt: String) async -> Outcome {
        let folder = RuntimePaths.assistantFolder
        // Direct, not through a proxy, when Codex has a ChatGPT sign-in: Gmail comes with it.
        let direct = EasyCLIProxy.codexHasChatGPTSignIn
        let ticket=runner.ticket()
        return await Task.detached {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chatterbox-email-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let schemaFile = scratch.appendingPathComponent("schema.json")
            let answerFile = scratch.appendingPathComponent("answer.json")
            try? Data(schema.utf8).write(to: schemaFile)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: codex)
            process.arguments = (direct ? ["-c", "model_provider=openai"] : []) + ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-m", model,

                                 "-C", folder, "--output-schema", schemaFile.path,
                                 "-o", answerFile.path, prompt]
            process.environment = BinaryLocator.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do { try runner.launch(process,ticket:ticket) } catch { return .failure("Couldn't start Codex: \(error.localizedDescription)") }
            defer{runner.finished(process)}
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: watchdog)
            // Drain the pipe, but never copy provider output (which may contain mail or
            // credentials) into service logs or user-visible errors.
            _ = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            guard process.terminationStatus == 0, let data = try? Data(contentsOf: answerFile), !data.isEmpty else {
                return .failure(process.terminationReason == .uncaughtSignal ? "The sweep took too long and was stopped."
                                : "The email sweep did not complete successfully (Codex exit \(process.terminationStatus)).")
            }
            struct Answer: Decodable { var status: String; var accountsChecked: [String]; var error: String; var emails: [Email] }
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
                let shape = (try? JSONSerialization.jsonObject(with: data)) == nil ? "not JSON" : "JSON without the expected fields"
                return .failure("The sweep's answer couldn't be read (\(data.count) bytes, \(shape), from \(codex)).")
            }
            guard answer.status == "ok", answer.error.isEmpty,
                  !answer.accountsChecked.isEmpty, answer.accountsChecked.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return .failure("Gmail checks were unavailable or incomplete; the successful email cursor was not advanced.")
            }
            return .success(answer.emails, accounts: answer.accountsChecked)
        }.value
    }

}

/// Where the email watcher is and what it sweeps next. Pure, so it can be tested on its own.
enum EmailCatchUp {
    struct Window: Equatable { var since: Date; var until: Date; var catchingUp: Bool }
    /// A window is at most this long, so a backlog is swept in pieces a sweep can handle.
    static let step: TimeInterval = 3 * 3600
    /// Each consecutive failure halves the window, down to this.
    static let minimumStep: TimeInterval = 1800
    /// Mail older than this is not swept automatically, and the gap is reported.
    static let maximumBacklog: TimeInterval = 7 * 86400
    /// Sweeps failing this long (and at least `alertFailures` times) earn the user one alert.
    static let alertAfter: TimeInterval = 3600, alertFailures = 3

    /// The next window from the last successful point; nil when there's nothing to sweep yet.
    static func window(through: Date?, failures: Int, now: Date) -> Window? {
        let since = max(through ?? now.addingTimeInterval(-3600), now.addingTimeInterval(-maximumBacklog))
        let length = max(minimumStep, step / pow(2, Double(min(max(failures, 0), 8))))
        let until = min(now, since.addingTimeInterval(length))
        guard until.timeIntervalSince(since) >= 60 else { return nil }
        return Window(since: since, until: until, catchingUp: now.timeIntervalSince(until) >= 60)
    }

    /// Mail between `through` and this was skipped for being older than the backlog limit.
    static func skipped(through: Date?, now: Date) -> Date? {
        guard let through, now.timeIntervalSince(through) > maximumBacklog else { return nil }
        return now.addingTimeInterval(-maximumBacklog)
    }

    /// A provider path that is a test fixture, not Codex.
    static func looksLikeFixture(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return path.contains("/tests/") || name.hasSuffix(".py") || name.hasPrefix("fake")
    }

    static func shouldAlert(failingSince: Date?, failures: Int, alerted: Bool, now: Date) -> Bool {
        guard let failingSince, !alerted else { return false }
        return failures >= alertFailures && now.timeIntervalSince(failingSince) >= alertAfter
    }
}

private final class EmailSweepRunner:@unchecked Sendable {
    private let lock=NSLock()
    private var generation=0
    private var process:Process?
    func ticket()->Int{lock.lock();defer{lock.unlock()};return generation}
    func launch(_ process:Process,ticket:Int) throws {
        lock.lock();defer{lock.unlock()}
        guard ticket==generation else{throw RuntimeFailure("Email sweep cancelled")}
        try process.run();self.process=process
    }
    func finished(_ process:Process){lock.lock();defer{lock.unlock()};if self.process===process{self.process=nil}}
    func cancel(){lock.lock();defer{lock.unlock()};generation += 1;if let process,process.isRunning{process.terminate()}}
}
