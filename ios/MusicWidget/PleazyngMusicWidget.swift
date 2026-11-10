import AppIntents
import SwiftUI
import UIKit
import WidgetKit

private struct MusicWidgetEntry: TimelineEntry {
  let date: Date
  let snapshot: MusicWidgetSnapshot?
}

private struct MusicWidgetTimeline: TimelineProvider {
  func placeholder(in context: Context) -> MusicWidgetEntry {
    MusicWidgetEntry(date: Date(), snapshot: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (MusicWidgetEntry) -> Void) {
    completion(entry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<MusicWidgetEntry>) -> Void) {
    let current = entry()
    if let expiry = current.snapshot?.expiresAt {
      completion(Timeline(entries: [current, MusicWidgetEntry(date: expiry, snapshot: nil)], policy: .never))
    } else {
      completion(Timeline(entries: [current], policy: .never))
    }
  }

  private func entry() -> MusicWidgetEntry {
    let now = Date()
    return MusicWidgetEntry(date: now, snapshot: MusicWidgetStore.read(now: now))
  }
}

private struct MusicWidgetView: View {
  let entry: MusicWidgetEntry

  var body: some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(for: .widget) { Color(uiColor: .secondarySystemBackground) }
    } else {
      content.padding()
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(entry.snapshot?.content.title ?? "Pleazyng", systemImage: "music.note")
        .font(.headline).lineLimit(2)
      if let snapshot = entry.snapshot {
        if !snapshot.content.artist.isEmpty {
          Text(snapshot.content.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if #available(iOS 17.0, *) {
          HStack {
            control("previous", icon: "backward.end.fill", snapshot: snapshot)
            control(
              snapshot.content.playing ? "pause" : "play",
              icon: snapshot.content.playing ? "pause.fill" : "play.fill", snapshot: snapshot)
            control("next", icon: "forward.end.fill", snapshot: snapshot)
          }
          .padding(.top, 4)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .widgetURL(URL(string: "pleazyng://open"))
  }

  @available(iOS 17.0, *)
  private func control(_ command: String, icon: String, snapshot: MusicWidgetSnapshot) -> some View {
    Button(
      intent: MusicWidgetTransportIntent(
        command: command, scope: snapshot.content.scope,
        revision: snapshot.content.revision)
    ) {
      Image(systemName: icon).frame(maxWidth: .infinity, minHeight: 32)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(snapshot.content.labels[command] ?? ""))
  }
}

@main
struct PleazyngMusicWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: MusicWidgetStore.kind, provider: MusicWidgetTimeline()) { entry in
      MusicWidgetView(entry: entry)
    }
    .configurationDisplayName("Pleazyng")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
