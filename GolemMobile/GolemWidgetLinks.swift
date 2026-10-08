import SwiftUI
import WidgetKit

/// The Home Screen widget's links, and keeping its copy of the quick prompts current.
///   golem://dictate      Golem's conversation, listening for one message
///   golem://ask/<id>     sends that quick prompt to Golem
struct GolemWidgetLinks: ViewModifier {
    @Environment(MobileStore.self) private var store
    @Binding var destination: GolemMobileRoot.Destination?
    @AppStorage(GolemQuickPrompts.key) private var quickPromptData = Data()

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                guard url.scheme == "golem" else { return }
                switch url.host {
                case "dictate":
                    Task { try? await GolemConversationRequest.shared.run(start: true, once: true) }
                case "ask":
                    guard let id = UUID(uuidString: url.lastPathComponent),
                          let prompt = GolemQuickPrompts.decode(quickPromptData).first(where: { $0.id == id }) else { return }
                    destination = .golem
                    Task { await ask(prompt) }
                default: break
                }
            }
            // The widget can't read the app's settings, so it gets its own copy.
            .onChange(of: quickPromptData, initial: true) { _, data in
                GolemQuickPrompts.shared?.set(GolemQuickPrompts.encode(GolemQuickPrompts.decode(data)), forKey: GolemQuickPrompts.key)
                WidgetCenter.shared.reloadAllTimelines()
            }
    }

    private func ask(_ prompt: GolemQuickPrompt) async {
        if store.chatList == nil { await store.loadChats() }
        guard let golem = store.chatList?.groups.first(where: { $0.kind == .dot })?.chats.first else { return }
        _ = try? await store.send(GolemQuickPrompts.expand(prompt.text), to: golem.id)
    }
}
