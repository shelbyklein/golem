import SwiftUI
import WidgetKit

/// Home Screen: Golem, a tap to dictate a message to him, and (medium and large) your quick prompts.
@main struct GolemWidgets: WidgetBundle {
    var body: some Widget { GolemTalkWidget() }
}

struct GolemTalkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GolemTalk", provider: Provider()) { entry in GolemTalkView(prompts: entry.prompts) }
            .configurationDisplayName("Talk to Golem")
            .description("Tap Golem to dictate a message, or send one of your quick prompts.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }

    /// The app refreshes the widget when your quick prompts change; nothing else changes over time.
    struct Provider: TimelineProvider {
        struct Entry: TimelineEntry { let date: Date; let prompts: [GolemQuickPrompt] }
        private func entry() -> Entry {
            Entry(date: .now, prompts: GolemQuickPrompts.decode(GolemQuickPrompts.shared?.data(forKey: GolemQuickPrompts.key) ?? Data()))
        }
        func placeholder(in context: Context) -> Entry { Entry(date: .now, prompts: GolemQuickPrompts.defaults) }
        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(entry()) }
        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [entry()], policy: .never))
        }
    }
}

struct GolemTalkView: View {
    let prompts: [GolemQuickPrompt]
    @Environment(\.widgetFamily) private var family
    /// The same rig the app draws him with, bundled with the widget, in his resting pose.
    private static let rig = Bundle.main.url(forResource: "rig", withExtension: nil).flatMap(GolemRig.load(from:))
    private static let dictate = URL(string: "golem://dictate")!

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                HStack(spacing: 12) {
                    Link(destination: Self.dictate) { talk }.frame(maxWidth: 120)
                    promptList(Array(prompts.prefix(3)))
                }
            case .systemLarge:
                VStack(spacing: 12) {
                    Link(destination: Self.dictate) { talk }.frame(height: 150)
                    promptList(Array(prompts.prefix(6)))
                    Spacer(minLength: 0)
                }
            default:
                talk.widgetURL(Self.dictate)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var talk: some View {
        VStack(spacing: 4) {
            if let rig = Self.rig {
                GolemFrameCanvas(rig: rig, frame: rig.frame(pose: "cairn", at: 0))
                    .aspectRatio(1, contentMode: .fit)
                    // His stage leaves room around him for moving; a still Golem fills the tile.
                    .scaleEffect(1.65, anchor: UnitPoint(x: 0.5, y: 0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "sparkles").font(.largeTitle).frame(maxHeight: .infinity)
            }
            Label("Talk", systemImage: "mic.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talk to Golem")
        .accessibilityHint("Opens Golem listening for one message")
    }

    @ViewBuilder private func promptList(_ shown: [GolemQuickPrompt]) -> some View {
        if shown.isEmpty {
            Text("Add quick prompts in Golem’s Settings.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                ForEach(shown) { prompt in
                    Link(destination: URL(string: "golem://ask/\(prompt.id.uuidString)")!) {
                        Text(prompt.label)
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityHint("Sends it to Golem")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
