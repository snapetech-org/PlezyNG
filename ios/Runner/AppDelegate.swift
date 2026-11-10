import plezy_preparation
import Flutter
import UIKit
import AVFoundation
import MediaPlayer
import MusicKit
import CarPlay

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
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PlezySteamPlugin") {
      PlezySteamPlugin.register(with: registrar)
    }

    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MusicCarBridge") {
      MusicCarBridge.shared.attach(registrar.messenger())
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DownloadStorageChannel") {
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

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MpvPlayerPlugin") {
      MpvPlayerPlugin.register(with: registrar)
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MpvWorkspacePlayerPlugin") {
      MpvPlayerPlugin.registerWorkspace(with: registrar)
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MpvAudioPlayerPlugin") {
      MpvAudioPlayerPlugin.register(with: registrar)
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VideoDecodeCapabilitiesPlugin") {
      VideoDecodeCapabilitiesPlugin.register(with: registrar)
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceAdjustmentChannel") {
      registerDeviceAdjustmentChannel(messenger: registrar.messenger())
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppIconPlugin") {
      AppIconPlugin.register(with: registrar)
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeepLinkPlugin") {
      DeepLinkPlugin.register(with: registrar)
    }

    if #available(iOS 15.0, *),
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleMusicKitPlugin")
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

/// Native CarPlay templates backed by the same profile-scoped Dart catalog.
/// MPNowPlaying/remote commands remain owned by os_media_controls.
final class MusicCarBridge {
  static let shared = MusicCarBridge()
  private var channel: FlutterMethodChannel?
  private(set) var ready = false
  private var epoch = 0
  private(set) var connected = false
  weak var scene: MusicCarSceneDelegate?

  func attach(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.pleazyng/music_car", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "ready":
        self.ready = true
        self.epoch += 1
        if self.connected { self.connection(true) }
        self.scene?.refresh()
        result(nil)
      case "snapshot": result(nil)
      case "close":
        self.ready = false
        self.epoch += 1
        self.scene?.refresh()
        result(nil)
      default: result(FlutterMethodNotImplemented)
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

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    controller = interfaceController
    MusicCarBridge.shared.scene = self
    MusicCarBridge.shared.connection(true)
    refresh()
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnect interfaceController: CPInterfaceController
  ) {
    MusicCarBridge.shared.connection(false)
    MusicCarBridge.shared.scene = nil
    controller = nil
  }

  func refresh() {
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

  private func show(id: String, title: String, root: Bool = false) {
    MusicCarBridge.shared.request("browse", ["id": id]) { [weak self] value in
      guard let self, let controller = self.controller else { return }
      let rows = value as? [[String: Any]] ?? []
      let items: [CPListItem] = rows.prefix(100).compactMap { row in
        guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
        let item = CPListItem(text: title, detailText: row["subtitle"] as? String)
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
      } else {
        controller.pushTemplate(template, animated: true, completion: nil)
      }
    }
  }
}
