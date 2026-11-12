import plezy_preparation
import Flutter
import UIKit
import AVFoundation
import MediaPlayer
import MusicKit
import CarPlay
import Intents
#if canImport(GoogleCast)
  import GoogleCast
#endif

/// Re-downloadable media is not user-created document data. Keep the policy
/// confined to our two managed roots, including their legacy support paths.
enum DownloadBackupPolicy {
  static var managedRoots: [URL] {
    let manager = FileManager.default
    return [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory]
      .flatMap { manager.urls(for: $0, in: .userDomainMask) }
      .flatMap { base in ["downloads", "artwork"].map { base.appendingPathComponent($0, isDirectory: true) } }
  }

  @discardableResult
  static func exclude(_ directory: URL, allowedRoots: [URL] = managedRoots) throws -> Bool {
    guard directory.isFileURL else { return false }
    let target = directory.standardizedFileURL.resolvingSymlinksInPath()
    guard allowedRoots.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == target }) else {
      return false
    }
    let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { return false }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var writableURL = directory
    try writableURL.setResourceValues(values)
    return true
  }

  static func refreshExistingRoots() {
    for root in managedRoots where FileManager.default.fileExists(atPath: root.path) {
      do {
        try exclude(root)
      } catch {
        MpvLog.error("Could not exclude downloaded content from backup: \(error)")
      }
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  // One explicit engine survives both the phone scene and CarPlay-only launch.
  // The normal Dart entry point owns authentication and the only music session.
  private(set) var musicEngine: FlutterEngine?

  func ensureMusicEngine() -> FlutterEngine {
    if let engine = musicEngine { return engine }
    let engine = FlutterEngine(name: "pleazyng_shared_music", project: nil, allowHeadlessExecution: true)
    musicEngine = engine
    guard
      engine.run(
        withEntrypoint: "main", libraryURI: nil, initialRoute: nil,
        entrypointArgs: ["--pleazyng-car-host"])
    else {
      musicEngine = nil
      return engine
    }
    registerApplicationPlugins(engine)
    return engine
  }

  private let musicIntentHandler = MusicPlayIntentHandler()
  private let musicNfcBridge = MusicNfcBridge()

  override func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
    intent is INPlayMediaIntent ? musicIntentHandler : super.application(application, handlerFor: intent)
  }

  private var deviceAdjustmentChannel: FlutterMethodChannel?
  /// The screen whose brightness the player changed, and the level to restore
  /// on it. Track the display because foldable iPhones can move the app between
  /// screens while playback is active.
  private var brightnessOverride: (screen: UIScreen, original: CGFloat)?
  private var volumeView: MPVolumeView?
  private weak var volumeSlider: UISlider?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    RommAppleBroker.install()
    DownloadBackupPolicy.refreshExistingRoots()
    PlezyPreparationPlugin.registerBackgroundTasks { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Configure the non-mixing session; activate it only when playback starts.
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default)
    } catch {
      MpvLog.error("Failed to configure audio session: \(error)")
    }
    // Declares that playback can carry 5.1/7.1 and Dolby content, so the
    // system offers multichannel Spatial Audio on AirPods (#2264). mpv's
    // AVFoundation output only declares it for sources above stereo, and only
    // in builds that compiled the call in; declaring it here does not depend
    // on either.
    do {
      try AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)
    } catch {
      MpvLog.error("Failed to declare multichannel audio content: \(error)")
    }

    application.beginReceivingRemoteControlEvents()
    _ = ensureMusicEngine()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func registerApplicationPlugins(_ registry: FlutterPluginRegistry) {
    if let registrar = registry.registrar(forPlugin: "PlezySteamPlugin") {
      PlezySteamPlugin.register(with: registrar)
    }

    GeneratedPluginRegistrant.register(with: registry)
    if let registrar = registry.registrar(forPlugin: "MusicCarBridge") {
      MusicCarBridge.shared.attach(registrar.messenger())
    }
    if let registrar = registry.registrar(forPlugin: "MusicNfcBridge") {
      musicNfcBridge.attach(registrar.messenger())
    }

    if let registrar = registry.registrar(forPlugin: "DownloadStorageChannel") {
      let channel = FlutterMethodChannel(name: "com.pleazyng/download_storage", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "excludeFromBackup", let path = call.arguments as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        do {
          result(try DownloadBackupPolicy.exclude(URL(fileURLWithPath: path)))
        } catch {
          result(
            FlutterError(code: "backup_exclusion", message: "Could not update download backup policy", details: nil))
        }
      }
    }

    if let registrar = registry.registrar(forPlugin: "MpvPlayerPlugin") {
      MpvPlayerPlugin.register(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "MpvWorkspacePlayerPlugin") {
      MpvPlayerPlugin.registerWorkspace(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "MpvAudioPlayerPlugin") {
      MpvAudioPlayerPlugin.register(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "MpvAudioOverlapPlugin") {
      MpvAudioPlayerPlugin.registerOverlap(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "MpvAudioGroupOutputPlugin") {
      MpvAudioPlayerPlugin.registerGroupOutput(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "VideoDecodeCapabilitiesPlugin") {
      VideoDecodeCapabilitiesPlugin.register(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "DeviceAdjustmentChannel") {
      registerDeviceAdjustmentChannel(messenger: registrar.messenger())
    }

    if let registrar = registry.registrar(forPlugin: "AppIconPlugin") {
      AppIconPlugin.register(with: registrar)
    }

    if let registrar = registry.registrar(forPlugin: "DeepLinkPlugin") {
      DeepLinkPlugin.register(with: registrar)
    }

    #if canImport(GoogleCast)
      if let registrar = registry.registrar(forPlugin: "CastMusicQueuePlugin") {
        CastMusicQueuePlugin.register(with: registrar)
      }
    #endif

    if #available(iOS 15.0, *),
      let registrar = registry.registrar(forPlugin: "AppleMusicKitPlugin")
    {
      AppleMusicKitPlugin.register(with: registrar)
    }
  }

  private func registerDeviceAdjustmentChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.plezy/device_adjustment", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        self?.handleDeviceAdjustmentCall(call, result: result)
      }
    }
    deviceAdjustmentChannel = channel
  }

  private func handleDeviceAdjustmentCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getBrightness":
      result(activeScreen.map { Double($0.brightness) })
    case "setBrightness":
      guard let value = normalizedArgument(call.arguments, result: result) else { return }
      guard let screen = activeScreen else {
        result(FlutterError(code: "DEVICE_ADJUSTMENT_UNAVAILABLE", message: "No active screen", details: nil))
        return
      }
      if let override = brightnessOverride, override.screen !== screen {
        override.screen.brightness = override.original
        brightnessOverride = nil
      }
      if brightnessOverride == nil {
        brightnessOverride = (screen, screen.brightness)
      }
      screen.brightness = CGFloat(value)
      result(nil)
    case "restoreBrightness":
      if let override = brightnessOverride {
        override.screen.brightness = override.original
        brightnessOverride = nil
      }
      result(nil)
    case "getMediaVolume":
      result(Double(AVAudioSession.sharedInstance().outputVolume))
    case "setMediaVolume":
      guard let value = normalizedArgument(call.arguments, result: result) else { return }
      if setMediaVolume(value) {
        result(nil)
      } else {
        result(
          FlutterError(code: "DEVICE_ADJUSTMENT_UNAVAILABLE", message: "System volume slider unavailable", details: nil)
        )
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func normalizedArgument(_ arguments: Any?, result: @escaping FlutterResult) -> Double? {
    guard let value = arguments as? NSNumber else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a numeric value", details: nil))
      return nil
    }
    let doubleValue = value.doubleValue
    guard doubleValue.isFinite else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a finite numeric value", details: nil))
      return nil
    }
    return min(1.0, max(0.0, doubleValue))
  }

  private func setMediaVolume(_ value: Double) -> Bool {
    guard let slider = ensureVolumeSlider() else { return false }
    slider.setValue(Float(value), animated: false)
    slider.sendActions(for: .valueChanged)
    slider.sendActions(for: .touchUpInside)
    return true
  }

  private func ensureVolumeSlider() -> UISlider? {
    if let volumeSlider = volumeSlider { return volumeSlider }

    let volumeView = self.volumeView ?? MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    volumeView.showsRouteButton = false
    volumeView.showsVolumeSlider = true
    volumeView.alpha = 0.01
    volumeView.isUserInteractionEnabled = false

    if volumeView.superview == nil {
      activeWindow?.addSubview(volumeView)
    }
    volumeView.layoutIfNeeded()

    self.volumeView = volumeView
    let slider = findVolumeSlider(in: volumeView)
    volumeSlider = slider
    return slider
  }

  private func findVolumeSlider(in view: UIView) -> UISlider? {
    if let slider = view as? UISlider { return slider }
    for subview in view.subviews {
      if let slider = findVolumeSlider(in: subview) { return slider }
    }
    return nil
  }

  /// The display showing the app. `UIScreen.main` may still refer to the
  /// outer display while a foldable iPhone shows the app on its inner display.
  private var activeScreen: UIScreen? {
    activeWindow?.windowScene?.screen
  }

  private var activeWindow: UIWindow? {
    if #available(iOS 13.0, *) {
      for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
          return keyWindow
        }
      }
      for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene, let window = windowScene.windows.first else { continue }
        return window
      }
      return nil
    }

    return UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first
  }
}

/// Narrow iOS MusicKit pilot. Apple remains the catalog and playback owner;
/// Pleazyng receives catalog metadata and never receives protected media bytes.
@available(iOS 15.0, *)
final class AppleMusicKitPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.plezy/apple_music_kit",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(AppleMusicKitPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    Task { @MainActor in
      await handleMusicKitCall(call, result: result)
    }
  }

  @MainActor
  private func handleMusicKitCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
    switch call.method {
    case "requestAuthorization":
      let status = await MusicAuthorization.request()
      result(status == .authorized ? "authorized" : "denied")
    case "search":
      guard MusicAuthorization.currentStatus == .authorized,
        let arguments = call.arguments as? [String: Any],
        let query = arguments["query"] as? String,
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        query.count <= 160
      else {
        result(
          FlutterError(
            code: "INVALID_OR_UNAUTHORIZED", message: "A granted MusicKit session and search query are required.",
            details: nil))
        return
      }
      do {
        var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
        request.limit = 20
        let response = try await request.response()
        result(
          response.songs.map { song in
            [
              "id": song.id.rawValue,
              "title": song.title,
              "artist": song.artistName,
              "album": song.albumTitle ?? "",
            ] as [String: Any]
          })
      } catch {
        result(FlutterError(code: "CATALOG_UNAVAILABLE", message: "Apple Music catalog search failed.", details: nil))
      }
    case "canPlayCatalogContent":
      guard MusicAuthorization.currentStatus == .authorized else {
        result(false)
        return
      }
      do {
        let subscription = try await MusicSubscription.current
        result(subscription.canPlayCatalogContent)
      } catch {
        result(
          FlutterError(
            code: "SUBSCRIPTION_UNAVAILABLE", message: "Apple Music subscription status is unavailable.", details: nil))
      }
    case "play":
      guard MusicAuthorization.currentStatus == .authorized,
        let arguments = call.arguments as? [String: Any],
        let songID = arguments["id"] as? String,
        !songID.isEmpty,
        songID.count <= 128
      else {
        result(
          FlutterError(
            code: "INVALID_OR_UNAUTHORIZED", message: "A granted MusicKit session and song id are required.",
            details: nil))
        return
      }
      do {
        let subscription = try await MusicSubscription.current
        guard subscription.canPlayCatalogContent else {
          result(
            FlutterError(
              code: "SUBSCRIPTION_REQUIRED", message: "An Apple Music subscription is required for catalog playback.",
              details: nil))
          return
        }
        let request = MusicCatalogResourceRequest<Song>(
          matching: \.id,
          equalTo: MusicItemID(songID)
        )
        let response = try await request.response()
        guard let song = response.items.first else {
          result(
            FlutterError(
              code: "SONG_NOT_FOUND", message: "The selected Apple Music item is no longer available.", details: nil))
          return
        }
        let player = ApplicationMusicPlayer.shared
        player.queue = .init(for: [song])
        try await player.play()
        result(nil)
      } catch {
        result(
          FlutterError(code: "PLAYBACK_UNAVAILABLE", message: "Apple Music could not start playback.", details: nil))
      }
    case "stop":
      ApplicationMusicPlayer.shared.stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// The phone attaches to the same engine a CarPlay-only launch prewarmed.
/// Forward every scene callback through Flutter's lifecycle adapter so URL,
/// authentication and background-download plugins retain their existing hooks.
@objc(MusicPhoneSceneDelegate)
final class MusicPhoneSceneDelegate: UIResponder, UIWindowSceneDelegate, FlutterSceneLifeCycleProvider {
  var sceneLifeCycleDelegate = FlutterPluginSceneLifeCycleDelegate()
  var window: UIWindow?

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
      let app = UIApplication.shared.delegate as? AppDelegate
    else { return }
    let engine = app.ensureMusicEngine()
    if let existing = engine.viewController?.viewIfLoaded?.window?.windowScene, existing != windowScene {
      // CarPlay and external video scenes are independent native surfaces;
      // a second phone window must not detach the first window's shared engine.
      UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
      return
    }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = PlezyFlutterViewController(engine: engine, nibName: nil, bundle: nil)
    self.window = window
    sceneLifeCycleDelegate.scene(scene, willConnectTo: session, options: connectionOptions)
    window.makeKeyAndVisible()
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    sceneLifeCycleDelegate.sceneDidDisconnect(scene)
    if let controller = window?.rootViewController as? FlutterViewController,
      let app = UIApplication.shared.delegate as? AppDelegate,
      app.musicEngine?.viewController === controller
    {
      app.musicEngine?.viewController = nil
    }
    window = nil
  }
  func sceneWillEnterForeground(_ scene: UIScene) { sceneLifeCycleDelegate.sceneWillEnterForeground(scene) }
  func sceneDidBecomeActive(_ scene: UIScene) { sceneLifeCycleDelegate.sceneDidBecomeActive(scene) }
  func sceneWillResignActive(_ scene: UIScene) { sceneLifeCycleDelegate.sceneWillResignActive(scene) }
  func sceneDidEnterBackground(_ scene: UIScene) { sceneLifeCycleDelegate.sceneDidEnterBackground(scene) }
  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    sceneLifeCycleDelegate.scene(scene, openURLContexts: contexts)
  }
  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    sceneLifeCycleDelegate.scene(scene, continue: userActivity)
  }
  func windowScene(
    _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    sceneLifeCycleDelegate.windowScene(
      windowScene, performActionFor: shortcutItem, completionHandler: completionHandler)
  }
}

/// Native CarPlay templates backed by the same profile-scoped Dart catalog.
/// MPNowPlaying/remote commands remain owned by os_media_controls.
final class MusicCarBridge {
  static let shared = MusicCarBridge()
  private var channel: FlutterMethodChannel?
  private(set) var ready = false
  private var epoch = 0
  private var widgetSnapshot: MusicWidgetSnapshot?
  private(set) var connected = false
  weak var scene: MusicCarSceneDelegate?

  func attach(_ messenger: FlutterBinaryMessenger) {
    ready = false
    epoch += 1
    updateWidget(nil)
    channel = FlutterMethodChannel(name: "com.pleazyng/music_car", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "ready":
        self.ready = true
        self.epoch += 1
        self.updateWidget(nil)
        if self.connected { self.connection(true) }
        self.scene?.refresh()
        result(nil)
      case "catalogChanged":
        self.scene?.refresh()
        result(nil)
      case "snapshot":
        if self.ready { self.updateWidget(MusicWidgetSnapshot(message: call.arguments)) }
        result(nil)
      case "close":
        self.ready = false
        self.epoch += 1
        self.updateWidget(nil)
        self.scene?.refresh()
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func updateWidget(_ snapshot: MusicWidgetSnapshot?) {
    if let snapshot, let previous = widgetSnapshot,
      snapshot.content == previous.content, previous.isFresh(at: snapshot.capturedAt),
      snapshot.capturedAt.timeIntervalSince(previous.capturedAt) < MusicWidgetSnapshot.lifetime / 2
    {
      return
    }
    widgetSnapshot = snapshot
    MusicWidgetStore.publish(snapshot)
  }

  @MainActor
  func performWidgetTransport(_ command: String, scope: String, revision: Int) async {
    guard ready, widgetSnapshot?.authorizes(command, scope: scope, revision: revision) == true else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      request("transport", ["command": command, "scope": scope, "revision": revision]) { _ in
        continuation.resume()
      }
    }
  }

  func connection(_ value: Bool) {
    connected = value
    guard ready else { return }
    channel?.invokeMethod("connection", arguments: ["connected": value])
  }

  func request(_ method: String, _ args: [String: Any], completion: @escaping (Any?) -> Void) {
    guard ready, let channel else { completion(nil); return }
    let expected = epoch
    var finished = false
    let finish: (Any?) -> Void = { [weak self] value in
      guard !finished else { return }
      finished = true
      completion(self?.epoch == expected ? value : nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
    channel.invokeMethod(method, arguments: args, result: finish)
  }
}

@objc(MusicCarSceneDelegate)
final class MusicCarSceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private var controller: CPInterfaceController?
  private var artworkGeneration = 0

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    _ = (UIApplication.shared.delegate as? AppDelegate)?.ensureMusicEngine()
    controller = interfaceController
    MusicCarBridge.shared.scene = self
    MusicCarBridge.shared.connection(true)
    refresh()
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnect interfaceController: CPInterfaceController
  ) {
    artworkGeneration += 1
    MusicCarBridge.shared.connection(false)
    MusicCarBridge.shared.scene = nil
    controller = nil
  }

  func refresh() {
    artworkGeneration += 1
    guard let controller else { return }
    if !MusicCarBridge.shared.ready {
      let item = CPListItem(
        text: NSLocalizedString("Open Pleazyng to unlock your music", comment: "CarPlay locked profile"),
        detailText: nil)
      item.isEnabled = false
      controller.setRootTemplate(
        CPListTemplate(title: "Pleazyng", sections: [CPListSection(items: [item])]), animated: false, completion: nil)
      return
    }
    show(id: "root", title: "Pleazyng", root: true)
  }

  private func loadArtwork(_ rows: [(String, CPListItem)], generation: Int, scale: CGFloat) {
    // CPListItem.setImage accepts a display-ready image. Bound both the
    // bridge payload and concurrent work; no media URL enters the native list.
    let size = min(
      256,
      max(
        32,
        Int(
          ceil(
            max(
              CPListItem.maximumImageSize.width, CPListItem.maximumImageSize.height) * scale))))
    weak var scene = self
    var cursor = 0
    var active = 0
    func pump() {
      guard let scene, generation == scene.artworkGeneration, scene.controller != nil else { return }
      while active < 3, cursor < rows.count {
        let (id, item) = rows[cursor]
        cursor += 1
        active += 1
        MusicCarBridge.shared.request("artwork", ["id": id, "size": size]) { [weak scene, weak item] value in
          guard let scene, generation == scene.artworkGeneration, scene.controller != nil else { return }
          if let data = value as? FlutterStandardTypedData, data.data.count <= 512 * 1024,
            let image = UIImage(data: data.data, scale: scale)
          {
            item?.setImage(image)
          }
          active -= 1
          pump()
        }
      }
    }
    pump()
  }

  private func show(id: String, title: String, root: Bool = false) {
    artworkGeneration += 1
    let generation = artworkGeneration
    MusicCarBridge.shared.request("browse", ["id": id]) { [weak self] value in
      guard let self, generation == self.artworkGeneration, let controller = self.controller else { return }
      let rows = value as? [[String: Any]] ?? []
      var artworkRows: [(String, CPListItem)] = []
      let items: [CPListItem] = rows.prefix(100).compactMap { row in
        guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
        let item = CPListItem(text: title, detailText: row["subtitle"] as? String)
        if row["artwork"] as? Bool == true { artworkRows.append((id, item)) }
        item.handler = { [weak self] _, done in
          if row["playable"] as? Bool == true {
            MusicCarBridge.shared.request("playItem", ["id": id]) { success in
              if success as? Bool == true {
                self?.controller?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
              }
              done()
            }
          } else {
            self?.show(id: id, title: title)
            done()
          }
        }
        return item
      }
      let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
      template.emptyViewTitleVariants = [NSLocalizedString("No music available", comment: "CarPlay empty list")]
      if root {
        controller.setRootTemplate(template, animated: false, completion: nil)
      } else if id.hasPrefix("page:"), let current = controller.topTemplate as? CPListTemplate {
        // Pagination updates the current level instead of exhausting CarPlay's
        // template stack after a few pages of a large music library.
        current.updateSections(template.sections)
      } else {
        controller.pushTemplate(template, animated: true, completion: nil)
      }
      self.loadArtwork(artworkRows, generation: generation, scale: controller.carTraitCollection.displayScale)
    }
  }
}

/// Siri resolves through the unlocked profile's catalog. Identifiers are
/// ephemeral, profile-qualified catalog references, never server credentials.
/// A cold/locked session reports that the app must open; it cannot bypass PINs.
final class MusicPlayIntentHandler: NSObject, INPlayMediaIntentHandling {
  func resolveMediaItems(
    for intent: INPlayMediaIntent,
    with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
  ) {
    DispatchQueue.main.async {
      guard MusicCarBridge.shared.ready else {
        completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .unsupported())])
        return
      }
      if intent.resumePlayback == true {
        completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .notRequired())])
        return
      }
      if let selected = intent.mediaItems?.first,
        (selected.identifier?.hasPrefix("item:") == true || selected.identifier?.hasPrefix("station:") == true
          || selected.identifier?.hasPrefix("recipe:") == true)
      {
        // The play command revalidates this identifier against the active map.
        completion(INPlayMediaMediaItemResolutionResult.successes(with: [selected]))
        return
      }
      guard let name = intent.mediaSearch?.mediaName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .needsValue())])
        return
      }
      var args: [String: Any] = ["query": name]
      if let artist = intent.mediaSearch?.artistName { args["artist"] = artist }
      if let album = intent.mediaSearch?.albumName { args["album"] = album }
      switch intent.mediaSearch?.mediaType {
      case .song: args["kind"] = "track"
      case .album: args["kind"] = "album"
      case .artist: args["kind"] = "artist"
      case .playlist: args["kind"] = "playlist"
      case .radioStation: args["kind"] = "station"
      default: break
      }
      MusicCarBridge.shared.request("resolveVoice", args) { value in
        let items: [INMediaItem] = (value as? [[String: Any]] ?? []).compactMap { row in
          guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
          let type: INMediaItemType =
            row["kind"] as? String == "album"
            ? .album
            : row["kind"] as? String == "artist"
              ? .artist
              : row["kind"] as? String == "station"
                ? .radioStation : row["kind"] as? String == "playlist" ? .playlist : .song
          return INMediaItem(
            identifier: id, title: title, type: type, artwork: nil,
            artist: row["subtitle"] as? String)
        }
        if items.count == 1 {
          completion(INPlayMediaMediaItemResolutionResult.successes(with: items))
        } else if items.isEmpty {
          completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .unsupported())])
        } else {
          completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .disambiguation(with: items))])
        }
      }
    }
  }

  func confirm(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
    DispatchQueue.main.async {
      completion(
        INPlayMediaIntentResponse(
          code: MusicCarBridge.shared.ready ? .ready : .failureRequiringAppLaunch,
          userActivity: nil))
    }
  }

  func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
    DispatchQueue.main.async {
      guard MusicCarBridge.shared.ready else {
        completion(INPlayMediaIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil))
        return
      }
      let finish: (Any?) -> Void = { result in
        completion(INPlayMediaIntentResponse(code: result as? Bool == true ? .success : .failure, userActivity: nil))
      }
      if intent.resumePlayback == true {
        MusicCarBridge.shared.request("play", [:], completion: finish)
      } else if let id = intent.mediaItems?.first?.identifier {
        var args: [String: Any] = ["id": id, "shuffle": intent.playShuffled == true]
        switch intent.playbackRepeatMode {
        case .one: args["repeat"] = "one"
        case .all: args["repeat"] = "all"
        default: break
        }
        switch intent.playbackQueueLocation {
        case .next: args["queue"] = "next"
        case .later: args["queue"] = "later"
        default: break
        }
        MusicCarBridge.shared.request("playItem", args, completion: finish)
      } else {
        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
      }
    }
  }
}

#if canImport(GoogleCast)
  /// Clones the receiver's acknowledged item, preserving its ID and media metadata.
  private final class CastMusicQueuePlugin: NSObject, FlutterPlugin, GCKRequestDelegate {
    private var pending: (request: GCKRequest, result: FlutterResult, owned: () -> Bool)?
    private var timeout: DispatchWorkItem?

    static func register(with registrar: FlutterPluginRegistrar) {
      let channel = FlutterMethodChannel(name: "com.pleazyng/cast_music_queue", binaryMessenger: registrar.messenger())
      registrar.addMethodCallDelegate(CastMusicQueuePlugin(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      guard call.method == "armRepeat" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard pending == nil, GCKCastContext.isSharedInstanceInitialized(),
        let args = call.arguments as? [String: Any],
        let sessionID = args["session"] as? String, !sessionID.isEmpty,
        let device = args["device"] as? String, !device.isEmpty,
        let mediaSession = args["mediaSession"] as? Int, mediaSession > 0,
        let itemID = args["item"] as? UInt, itemID > 0,
        let token = args["token"] as? String, !token.isEmpty, token.count <= 128,
        let occurrence = args["occurrence"] as? String, !occurrence.isEmpty,
        let contentID = args["contentId"] as? String, contentID == "pleazyng:\(token):\(occurrence)",
        let repeatName = args["repeat"] as? String, ["SINGLE", "ALL"].contains(repeatName),
        let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
        let remote = session.remoteMediaClient
      else {
        result(false)
        return
      }
      let repeatMode: GCKMediaRepeatMode = repeatName == "SINGLE" ? .single : .all
      func mediaMatches(_ media: GCKMediaInformation?) -> Bool {
        let custom = media?.customData as? [String: Any]
        return media?.contentID == contentID && custom?["pleazyngOwner"] as? String == token
          && custom?["pleazyngOccurrence"] as? String == occurrence
      }
      func owned() -> Bool {
        guard GCKCastContext.sharedInstance().sessionManager.currentCastSession === session,
          session.connectionState == .connected, session.sessionID == sessionID,
          session.device.deviceID == device, let status = remote.mediaStatus
        else { return false }
        return status.mediaSessionID == mediaSession && status.currentItemID == itemID
          && status.playerState == .paused && status.queueRepeatMode == repeatMode
          && mediaMatches(status.mediaInformation)
      }
      guard owned(), let item = remote.mediaStatus?.queueItem(withItemID: itemID),
        mediaMatches(item.mediaInformation)
      else {
        result(false)
        return
      }
      let builder = GCKMediaQueueItemBuilder(mediaQueueItem: item)
      builder.autoplay = true
      let request = remote.queueUpdateItems([builder.build()])
      pending = (
        request, result,
        {
          owned() && remote.mediaStatus?.queueItem(withItemID: itemID)?.autoplay == true
        }
      )
      request.delegate = self
      let deadline = DispatchWorkItem { [weak self, weak request] in
        guard let request else { return }
        self?.finish(request, success: false)
      }
      timeout = deadline
      DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
    }

    private func finish(_ request: GCKRequest, success: Bool) {
      guard let operation = pending, operation.request === request else { return }
      pending = nil
      timeout?.cancel()
      timeout = nil
      request.delegate = nil
      operation.result(success && operation.owned())
    }

    func requestDidComplete(_ request: GCKRequest) {
      finish(request, success: true)
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
      finish(request, success: false)
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
      finish(request, success: false)
    }

    deinit {
      timeout?.cancel()
      pending?.request.delegate = nil
      pending?.result(false)
    }
  }
#endif
