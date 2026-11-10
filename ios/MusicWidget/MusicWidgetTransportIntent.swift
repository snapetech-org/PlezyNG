#if PLEAZYNG_MUSIC_WIDGET_HOST || PLEAZYNG_MUSIC_WIDGET_EXTENSION
  import AppIntents
  import Foundation

  @available(iOS 17.0, *)
  struct MusicWidgetTransportIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Music transport"
    static let openAppWhenRun = false

    @Parameter(title: "Command") var command: String
    @Parameter(title: "Session") var scope: String
    @Parameter(title: "Queue revision") var revision: Int

    init() {}

    init(command: String, scope: String, revision: Int) {
      self.command = command
      self.scope = scope
      self.revision = revision
    }

    @MainActor
    func perform() async throws -> some IntentResult {
      #if !PLEAZYNG_MUSIC_WIDGET_EXTENSION
        await MusicCarBridge.shared.performWidgetTransport(command, scope: scope, revision: revision)
      #endif
      return .result()
    }
  }
#endif
