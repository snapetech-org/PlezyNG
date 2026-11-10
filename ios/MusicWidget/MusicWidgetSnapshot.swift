import Foundation

struct MusicWidgetSnapshot: Codable, Equatable {
  struct Content: Codable, Equatable {
    let scope: String
    let revision: Int
    let title: String
    let artist: String
    let playing: Bool
    let labels: [String: String]
  }

  static let commands = Set(["play", "pause", "previous", "next"])
  static let lifetime: TimeInterval = 15 * 60
  let content: Content
  let capturedAt: Date
  var expiresAt: Date { capturedAt.addingTimeInterval(Self.lifetime) }

  init?(message: Any?, now: Date = Date()) {
    guard let values = message as? [String: Any],
      let scope = values["scope"] as? String, UUID(uuidString: scope) != nil,
      let revision = values["revision"] as? Int, revision >= 0,
      let title = values["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let playing = values["playing"] as? Bool,
      let labels = values["labels"] as? [String: String],
      Self.commands.allSatisfy({ !(labels[$0] ?? "").isEmpty })
    else { return nil }
    content = Content(
      scope: scope, revision: revision, title: String(title.prefix(256)),
      artist: String((values["artist"] as? String ?? "").prefix(256)), playing: playing,
      labels: labels.filter { Self.commands.contains($0.key) }.mapValues { String($0.prefix(128)) })
    capturedAt = now
  }

  func isFresh(at date: Date) -> Bool {
    date >= capturedAt && date < expiresAt
  }

  func authorizes(_ command: String, scope: String, revision: Int, now: Date = Date()) -> Bool {
    isFresh(at: now) && Self.commands.contains(command) && scope == content.scope && revision == content.revision
  }
}

#if canImport(WidgetKit)
  import WidgetKit

  enum MusicWidgetStore {
    static let kind = "PleazyngMusicWidget"
    private static let maximumBytes = 16 * 1024
    private static let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.org.snapetech.pleazyng"
    )?.appendingPathComponent("MusicWidget.json")

    static func read(now: Date = Date()) -> MusicWidgetSnapshot? {
      guard let url,
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes,
        let data = try? Data(contentsOf: url), data.count <= maximumBytes,
        let snapshot = try? JSONDecoder().decode(MusicWidgetSnapshot.self, from: data), snapshot.isFresh(at: now)
      else { return nil }
      return snapshot
    }

    static func publish(_ snapshot: MusicWidgetSnapshot?) {
      guard let url else { return }
      if let snapshot, let data = try? JSONEncoder().encode(snapshot), data.count <= maximumBytes {
        do {
          try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
          try? FileManager.default.removeItem(at: url)
        }
      } else {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
      }
      WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
  }
#endif
