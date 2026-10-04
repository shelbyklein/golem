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

    static func prompt(name: String, since: Date, now: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        let iso = ISO8601DateFormatter()
        return """
        You are \(name)'s email sweep, running in the background for the user. Find the email that arrived in all of the user's Gmail accounts since \(format.string(from: since)) (\(iso.string(from: since)) UTC). Use your Gmail tools. Only read: never send, draft, archive, label, mark as read, delete, or change anything.

        To find it, search each account with exactly this query: after:\(Int(since.timeIntervalSince1970)) -in:sent -in:drafts (Gmail reads that number as the exact moment of the last sweep). Every result is new; don't filter by time yourself, since Gmail mixes time zones in its timestamps. Page through all results.

        First read the user's notes: \(RuntimePaths.assistantMemoryFolder.path)/MEMORY.md and the files it points to (especially the accounts and \(name)'s jobs). Follow them on what counts as important. Unless they say otherwise, flag mail that needs the user to do or decide something, or that they'd want to know about soon: school, appointments, bills or deadlines, clients and work requests (USA Archery and its forwards included), and personal messages from real people. Stay quiet about newsletters, promotions, receipts with nothing to do, automated notifications, and anything the user has already replied to.

        Answer with the JSON the schema asks for: "emails", most important first, at most 8. Leave it empty when nothing needs the user; that's the usual case. For each email: account (the address it arrived at), from (the sender's name), subject, why (one short sentence on why it matters to the user), action (one short suggested next step), link (a Gmail web link to the message if your tools give one, otherwise ""), and id (the message's id).
        """
    }

    nonisolated static let schema = """
    {"type":"object","additionalProperties":false,"required":["emails"],"properties":{"emails":{"type":"array","maxItems":8,"items":{"type":"object","additionalProperties":false,"required":["account","from","subject","why","action","link","id"],"properties":{"account":{"type":"string"},"from":{"type":"string"},"subject":{"type":"string"},"why":{"type":"string"},"action":{"type":"string"},"link":{"type":"string"},"id":{"type":"string"}}}}}}
    """

    enum Outcome {
        case success([Email])
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
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            watchdog.cancel()

            guard let data = try? Data(contentsOf: answerFile), !data.isEmpty else {
                NSLog("Chatterbox email watch: codex exited %d: %@", process.terminationStatus, String(errorText.suffix(1500)))
                let last = errorText.split(separator: "\n").last(where: { $0.localizedCaseInsensitiveContains("error") }) ?? ""
                return .failure(process.terminationReason == .uncaughtSignal ? "The sweep took too long and was stopped."
                                : "The sweep didn't finish. " + String(last.prefix(200)))
            }
            struct Answer: Decodable { var emails: [Email] }
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
                return .failure("The sweep's answer couldn't be read.")
            }
            return .success(answer.emails)
        }.value
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
