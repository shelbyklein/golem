import SwiftUI
import WidgetKit

/// Home Screen: Golem, and a tap opens him listening for one dictated message.
@main struct GolemWidgets: WidgetBundle {
    var body: some Widget { GolemTalkWidget() }
}

struct GolemTalkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GolemTalk", provider: Provider()) { _ in GolemTalkView() }
            .configurationDisplayName("Talk to Golem")
            .description("Tap to dictate a message to Golem.")
            .supportedFamilies([.systemSmall])
    }

    /// Nothing changes over time: one entry, never refreshed.
    struct Provider: TimelineProvider {
        struct Entry: TimelineEntry { let date: Date }
        func placeholder(in context: Context) -> Entry { Entry(date: .now) }
        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry(date: .now)], policy: .never))
        }
    }
}

struct GolemTalkView: View {
    /// The same rig the app draws him with, bundled with the widget, in his resting pose.
    private static let rig = Bundle.main.url(forResource: "rig", withExtension: nil).flatMap(GolemRig.load(from:))

    var body: some View {
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
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "golem://dictate"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talk to Golem")
        .accessibilityHint("Opens Golem listening for one message")
    }
}
