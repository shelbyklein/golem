import Foundation

/// Runs one Outlook sweep: a `codex exec` that reads the Outlook inbox open in the user's Chrome
/// (see OutlookWatch for what it does and what the answer means).
@MainActor enum OutlookSweep {
    nonisolated private static let runner = EmailSweepRunner()
    static func cancel() { runner.cancel() }

    /// Read-only, kept out of Codex's history, stopped after ten minutes. The scratch folder holds
    /// only the answer schema and Codex's answer, and is removed however the run ends.
    static func run(codex: String, model: String, prompt: String) async -> Result<OutlookWatch.Answer, SweepError> {
        let folder = RuntimePaths.assistantFolder
        let direct = EasyCLIProxy.codexHasChatGPTSignIn
        let ticket = runner.ticket()
        let base = scratchBase
        return await Task.detached {
            let scratch = base.appendingPathComponent(OutlookWatch.scratchPrefix + UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: scratch) }
            let schemaFile = scratch.appendingPathComponent("schema.json")
            let answerFile = scratch.appendingPathComponent("answer.json")
            try? Data(OutlookWatch.schema.utf8).write(to: schemaFile)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: codex)
            process.arguments = (direct ? ["-c", "model_provider=openai"] : []) + ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-m", model,
                                 "-C", folder, "--output-schema", schemaFile.path, "-o", answerFile.path, prompt]
            process.environment = BinaryLocator.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do { try runner.launch(process, ticket: ticket) } catch { return .failure(SweepError("Couldn't start Codex: \(error.localizedDescription)")) }
            defer { runner.finished(process) }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: watchdog)
            // Drain, but never copy provider output (which may contain mail) into logs or errors.
            _ = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            guard process.terminationStatus == 0, let data = try? Data(contentsOf: answerFile), !data.isEmpty else {
                return .failure(SweepError(process.terminationReason == .uncaughtSignal ? "The Outlook sweep took too long and was stopped."
                                           : "The Outlook sweep did not complete (Codex exit \(process.terminationStatus))."))
            }
            guard let answer = try? JSONDecoder().decode(OutlookWatch.Answer.self, from: data) else {
                return .failure(SweepError("The Outlook sweep's answer couldn't be read (\(data.count) bytes)."))
            }
            return .success(answer)
        }.value
    }

    /// Where runs keep their schema and answer: inside the service's own data folder, so a test's
    /// service (with its own data folder) never touches a real run's files.
    nonisolated static var scratchBase: URL { RuntimePaths.data.appendingPathComponent("OutlookScratch", isDirectory: true) }

    /// Scratch folders left by a run that was interrupted (the service stopped mid-sweep).
    nonisolated static func removeLeftovers() {
        let base = scratchBase
        for name in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] where OutlookWatch.isScratch(name) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }

    struct SweepError: Error { let message: String; init(_ message: String) { self.message = message } }
}
