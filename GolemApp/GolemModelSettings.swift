import SwiftUI

/// Separate from Chatterbox's new-chat defaults: only Golem's assistant is changed.
struct GolemModelSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage("dotDefaultBackend", store: AppPreferences.defaults) private var savedProvider = "codex"
    @AppStorage("dotDefaultModel", store: AppPreferences.defaults) private var savedModel = "gpt-6.1-sol"
    @State private var provider = "codex"
    @State private var selection = ""
    @State private var status: String?
    @State private var busy = false
    private var choices: [(String, String)] {
        provider == "claude"
            ? ClaudeModels.shared.models.map { ($0.value, $0.displayName) }
            : CodexAppServer.shared.models.map { ($0.model, $0.displayName) }
    }
    var body: some View {
        Section("Golem model") {
            Picker("Provider", selection: $provider) {
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
            }.onChange(of: provider) {
                selection = provider == savedProvider ? savedModel : (provider == "claude" ? "haiku" : "gpt-6.1-sol")
            }
            Picker("Default model", selection: $selection) {
                ForEach(choices, id: \.0) { value, name in Text(name).tag(value) }
                if !choices.contains(where: { $0.0 == selection }) { Text(selection + " (not verified)").tag(selection) }
            }
            Text("Applies only to Golem. Worker chat defaults and the Codex email watcher are unchanged. Supported reasoning effort is set to the lowest available level.")
                .font(.caption).foregroundStyle(.secondary)
            if provider == "claude" {
                Text("Claude does not inherit ChatGPT app connections. Gmail and other connected-app requests need a verified Codex worker; the scheduled email watcher still uses Codex.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Save Default") { save(apply: false) }
                Button("Save and Apply to Golem") { save(apply: true) }
                    .disabled(app.dot == nil || app.dot?.isRunning == true)
            }.disabled(busy || !choices.contains(where: { $0.0 == selection }))
            if app.dot?.isRunning == true { Text("Apply after Golem finishes his current reply.").font(.caption) }
            if let status { Text(status).font(.caption).textSelection(.enabled) }
        }
        .task {
            provider = savedProvider; selection = savedModel
            await ClaudeModels.shared.refresh()
            do { try await CodexAppServer.shared.refreshModels() }
            catch { status = "Codex model availability: \(error.localizedDescription)" }
        }
    }
    private func save(apply: Bool) {
        guard !busy else { return }
        let backend = provider, model = selection
        busy = true
        Task {
            defer { busy = false }
            do {
                if apply {
                    guard let dot = app.dot, !dot.isRunning else { status = "Wait for Golem's current reply to finish."; return }
                    var body: [String: JSON] = ["chatID": .string(dot.id.uuidString), "backend": .string(backend)]
                    if backend == "claude" {
                        body["model"] = .string(model)
                        body["effort"] = .string(ClaudeModels.shared.info(model).efforts.first ?? "")
                    } else {
                        body["codexModel"] = .string(model)
                        body["codexEffort"] = CodexAppServer.shared.models.first(where: { $0.model == model })?.efforts.first.map(JSON.string) ?? .null
                        body["codexFolder"] = .string(AppModel.dotFolder)
                    }
                    _ = try await RuntimeClient.shared.request("settings", body: .object(body))
                }
                _ = try await RuntimeClient.shared.request("preferences", body: ["dotDefaultBackend": .string(backend), "dotDefaultModel": .string(model), "dotApplyDefault": false])
                savedProvider = backend; savedModel = model
                status = apply ? "Saved and applied to Golem." : "Default saved. Golem's current conversation was not changed."
            } catch { status = error.localizedDescription }
        }
    }
}

#if DEBUG
/// Explicit deployment verification, executed inside the signed UI identity. Never runs at
/// ordinary startup and never changes worker/global defaults.
@MainActor enum GolemModelActivation {
    static func runIfRequested(_ app: AppModel) async {
        guard ProcessInfo.processInfo.environment["GOLEM_APPLY_HAIKU"] == "1",
              let output = ProcessInfo.processInfo.environment["GOLEM_MODEL_RECEIPT"] else { return }
        do {
            await ClaudeModels.shared.refresh(force: true)
            guard ClaudeModels.shared.models.contains(where: { $0.value == "haiku" }) else {
                throw CocoaError(.featureUnsupported)
            }
            for _ in 0..<300 {
                if let dot = app.dot, !dot.isRunning {
                    _ = try await RuntimeClient.shared.request("settings", body: ["chatID": .string(dot.id.uuidString), "backend": "claude", "model": "haiku", "effort": ""])
                    _ = try await RuntimeClient.shared.request("preferences", body: ["dotDefaultBackend": "claude", "dotDefaultModel": "haiku", "dotApplyDefault": false])
                    AppPreferences.defaults.set("claude", forKey: "dotDefaultBackend")
                    AppPreferences.defaults.set("haiku", forKey: "dotDefaultModel")
                    AppPreferences.defaults.set(false, forKey: "dotApplyDefault")
                    try Data("Applied Claude Haiku with no effort override; assistant only.\n".utf8).write(to: URL(fileURLWithPath: output), options: .atomic)
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw CocoaError(.userCancelled)
        } catch {
            try? Data("Activation failed: \(error.localizedDescription)\n".utf8).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
#endif
