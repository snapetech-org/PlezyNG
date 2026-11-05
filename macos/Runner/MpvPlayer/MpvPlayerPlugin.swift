import Cocoa
import FlutterMacOS
import QuartzCore

/// Flutter plugin that bridges MPV player to Dart via method and event channels
class MpvPlayerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, MpvPluginShared {

  // MARK: - Properties

  private var playerCore: MpvPlayerCore?
  var eventSink: FlutterEventSink?
  private weak var registrar: FlutterPluginRegistrar?
  var nameToId: [String: Int] = [:]

  var coreBase: MpvPlayerCoreBase? { playerCore }
  private var requestedVisible = false
  func setPlayerVisible(_ visible: Bool, restoreOnWindowVisible: Bool) {
    requestedVisible = visible
    playerCore?.setVisible(visible, restoreOnWindowVisible: restoreOnWindowVisible)
  }
  func updatePlayerFrame() { if detachedWindow == nil { playerCore?.updateFrame() } }
  func setPlayerVideoRect(
    left: Int,
    top: Int,
    right: Int,
    bottom: Int,
    devicePixelRatio: Double
  ) {
    guard detachedWindow == nil else { return }
    playerCore?.setVideoRect(left: left, top: top, right: right, bottom: bottom, devicePixelRatio: devicePixelRatio)
  }
  func setPlayerVideoZoom(_ scale: Double) { playerCore?.setVideoZoom(scale) }

  private var pipController: MpvPipController?
  private var detachedWindow: MpvDetachedVideoWindow?
  private var detachedToken: String?
  private var pipChannel: FlutterMethodChannel?
  private var autoPipEnabled = false
  private var enteredPipViaAuto = false
  private let displayModes = DisplayModeManager()

  // MARK: - FlutterPlugin Registration

  static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "com.plezy/mpv_player",
      binaryMessenger: registrar.messenger
    )

    let eventChannel = FlutterEventChannel(
      name: "com.plezy/mpv_player/events",
      binaryMessenger: registrar.messenger
    )

    let pipChannel = FlutterMethodChannel(
      name: "com.plezy/pip",
      binaryMessenger: registrar.messenger
    )

    let instance = MpvPlayerPlugin()
    instance.registrar = registrar
    instance.pipChannel = pipChannel

    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
    pipChannel.setMethodCallHandler(instance.handlePipCall)

    MpvLog.debug("[MpvPlayerPlugin] Registered with Flutter")
  }

  /// Registers the isolated in-app workspace decoder without a system PiP
  /// controller; workspace layout owns its presentation and lifecycle.
  static func registerWorkspace(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "com.plezy/mpv_player/workspace",
      binaryMessenger: registrar.messenger
    )
    let eventChannel = FlutterEventChannel(
      name: "com.plezy/mpv_player/workspace/events",
      binaryMessenger: registrar.messenger
    )
    let instance = MpvPlayerPlugin()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    self.eventSink = events
    MpvLog.debug("[MpvPlayerPlugin] Event stream connected")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    MpvLog.debug("[MpvPlayerPlugin] Event stream disconnected")
    return nil
  }

  // MARK: - FlutterPlugin Method Handler

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      handleInitialize(call: call, result: result)

    case "detachVideoWindow":
      guard let args = call.arguments as? [String: Any],
        let token = args["token"] as? String, !token.isEmpty, token.count <= 80
      else { result(false); return }
      if detachedWindow != nil { result(detachedToken == token); return }
      guard let core = playerCore, core.isInitialized, pipController?.isActive != true,
        let layers = core.lendVideoLayersForPip()
      else { result(false); return }
      detachedToken = token
      core.isPipActive = true
      detachedWindow = MpvDetachedVideoWindow(
        title: String((args["title"] as? String ?? "PlezyNG").prefix(240)),
        labels: args["labels"] as? [String: String] ?? [:], layers: layers,
        geometryKey: args["geometryKey"] as? String ?? "",
        onAction: { [weak self] action in self?.detachedAction(action) },
        onRestore: { [weak self] in self?.restoreDetachedVideoWindow(notify: true) })
      result(true)

    case "attachVideoWindow":
      let token = (call.arguments as? [String: Any])?["token"] as? String
      guard detachedWindow == nil || token == detachedToken else { result(false); return }
      restoreDetachedVideoWindow(notify: false)
      result(true)

    case "dispose":
      handleDispose(result: result)

    case "setProperty":
      handleSetProperty(call: call, result: result)

    case "getProperty":
      handleGetProperty(call: call, result: result)

    case "observeProperty":
      handleObserveProperty(call: call, result: result)

    case "command":
      handleCommand(call: call, result: result)

    case "setVisible":
      handleSetVisible(call: call, result: result)

    case "setVideoRect":
      handleSetVideoRect(call: call, result: result)

    case "isInitialized":
      result(playerCore?.isInitialized ?? false)
    case "subtitlePcmCaptureAvailable", "setSubtitlePcmCaptureEnabled", "drainSubtitlePcmCapture":
      handleSubtitlePcmCapture(call: call, result: result)

    case "updateFrame":
      handleUpdateFrame(result: result)

    case "setVideoZoom":
      handleSetVideoZoom(call: call, result: result)

    case "setLogLevel":
      handleSetLogLevel(call: call, result: result)

    case "getAppleThermalStatus":
      result(Self.thermalStatus())

    // Display mode matching (DisplayModeService): refresh rate only, Match
    // Dynamic Range is Windows-only.
    case "isModeChanged":
      result(displayModes.isModeChanged)

    case "getCurrentDisplayMode":
      withFlutterWindow(result) { result(self.displayModes.currentMode(on: $0)) }

    case "getDisplayModes":
      withFlutterWindow(result) { result(self.displayModes.modes(on: $0)) }

    case "setDisplayMode":
      handleSetDisplayMode(call: call, result: result)

    case "restoreDisplayMode":
      result(displayModes.restore())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Maps Apple's process thermal tiers into the shared motion governor
  /// vocabulary. Unknown future enum values remain unknown and fail open.
  private static func thermalStatus() -> String? {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:
      return "none"
    case .fair:
      return "light"
    case .serious:
      return "moderate"
    case .critical:
      return "critical"
    @unknown default:
      return nil
    }
  }

  private func ensurePipController() -> MpvPipController {
    if let existing = pipController { return existing }
    let controller = MpvPipController()
    controller.delegate = self
    pipController = controller
    return controller
  }

  private func handlePipCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(MpvPipController.isSupported)
    case "enter":
      enterPip(manual: true, result: result)
    case "exit":
      pipController?.stopPip()
      result(nil)
    case "setAutoPipReady":
      if let args = call.arguments as? [String: Any], let ready = args["ready"] as? Bool {
        autoPipEnabled = ready
        let pip = ensurePipController()
        pip.setAutoStart(ready)
        if ready {
          NotificationCenter.default.removeObserver(
            self, name: NSApplication.didResignActiveNotification, object: nil)
          NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
          NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
          NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        } else {
          NotificationCenter.default.removeObserver(
            self, name: NSApplication.didResignActiveNotification, object: nil)
          NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
        }
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Enter PiP by lending the player's video layers to a PiP window.
  /// No VO switching — mpv keeps rendering into the same layers.
  private func enterPip(manual: Bool, result: FlutterResult? = nil) {
    guard let playerCore = playerCore else {
      result?([
        "success": false, "errorCode": "failed", "errorMessage": "Player not initialized",
      ])
      return
    }
    guard playerCore.dvBackend == nil else {
      result?([
        "success": false, "errorCode": "unsupported",
        "errorMessage": "Picture in Picture is unavailable with experimental Dolby Vision playback",
      ])
      return
    }
    guard let window = findFlutterWindow()?.0 else {
      result?(["success": false, "errorCode": "failed", "errorMessage": "No window"])
      return
    }

    let pip = ensurePipController()
    guard !pip.isActive && detachedWindow == nil else {
      result?(["success": false, "errorCode": "failed", "errorMessage": "PiP already active"])
      return
    }

    var aspectRatio = NSSize(width: 16, height: 9)
    if let videoSize = playerCore.videoSize {
      aspectRatio = NSSize(width: videoSize.width, height: videoSize.height)
    }

    guard let layers = playerCore.lendVideoLayersForPip() else {
      result?(["success": false, "errorCode": "failed", "errorMessage": "No video layer"])
      return
    }

    enteredPipViaAuto = !manual
    playerCore.isPipActive = true

    pip.startPip(layers: layers, window: window, aspectRatio: aspectRatio)
    pipChannel?.invokeMethod("onPipChanged", arguments: true)
    result?(["success": true])
  }

  /// App resigned active — auto-enter PiP if enabled and playing
  @objc private func appDidResignActive() {
    guard autoPipEnabled,
      let pc = playerCore,
      !pc.isPipActive,
      !pc.isPaused,
      pipController?.autoPipEnabled == true
    else { return }
    MpvLog.debug("[MpvPlayerPlugin] Auto-PiP: app resigned active, entering PiP")
    enterPip(manual: false)
  }

  /// App became active — auto-exit PiP if it was entered automatically
  @objc private func appDidBecomeActive() {
    guard enteredPipViaAuto, let pip = pipController, pip.isActive else { return }
    MpvLog.debug("[MpvPlayerPlugin] Auto-PiP: app became active, exiting PiP")
    pip.stopPip()
  }

  // MARK: - Platform-Specific Method Handlers

  private func handleInitialize(call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result(FlutterError(code: "ERROR", message: "Plugin deallocated", details: nil))
        return
      }

      if self.playerCore?.isInitialized == true {
        MpvLog.debug("[MpvPlayerPlugin] Already initialized")
        result(true)
        return
      }

      guard let (window, _, _) = self.findFlutterWindow() else {
        MpvLog.debug("[MpvPlayerPlugin] Failed to find Flutter window")
        result(
          FlutterError(
            code: "NO_WINDOW", message: "Could not find Flutter window", details: nil))
        return
      }

      let core = MpvPlayerCore()
      core.experimentalDolbyVisionRequested =
        (call.arguments as? [String: Any])?["experimentalDolbyVision"] as? Bool ?? false
      core.delegate = self

      guard core.initialize(in: window) else {
        MpvLog.debug("[MpvPlayerPlugin] Failed to initialize MPV")
        result(
          FlutterError(
            code: "MPV_INIT_FAILED", message: "Failed to initialize MPV", details: nil))
        return
      }

      self.playerCore = core

      core.setVisible(false)

      MpvLog.debug("[MpvPlayerPlugin] Initialized successfully")
      result(true)
    }
  }

  private func handleDispose(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { result(nil); return }
      self.restoreDetachedVideoWindow(notify: false)
      self.requestedVisible = false
      if let pip = self.pipController, pip.isActive {
        pip.stopPip()
        pip.detachLayers()
        // The controller is released below, before PiP's close callback
        // (pipDidStop) can arrive, so tell Dart PiP ended here; otherwise
        // later players stay covered by the PiP placeholder.
        self.playerCore?.isPipActive = false
        self.enteredPipViaAuto = false
        self.pipChannel?.invokeMethod("onPipChanged", arguments: false)
      }
      self.pipController = nil
      self.autoPipEnabled = false
      NotificationCenter.default.removeObserver(
        self, name: NSApplication.didResignActiveNotification, object: nil)
      NotificationCenter.default.removeObserver(
        self, name: NSApplication.didBecomeActiveNotification, object: nil)
      self.playerCore?.dispose()
      self.playerCore = nil
      MpvLog.debug("[MpvPlayerPlugin] Disposed")
      result(nil)
    }
  }

  private func detachedAction(_ action: String) {
    guard let token = detachedToken else { return }
    eventSink?(["type": "event", "name": "detached-window-action", "data": ["token": token, "action": action]])
  }

  private func restoreDetachedVideoWindow(notify: Bool) {
    guard let host = detachedWindow else { return }
    let layers = host.releaseLayers()
    playerCore?.isPipActive = false
    playerCore?.takeBackVideoLayers(layers)
    playerCore?.setVisible(requestedVisible)
    if notify { detachedAction("restored") }
    detachedWindow = nil
    detachedToken = nil
    host.close()
  }

  func didSetPauseProperty(value: String) {
    let isPlaying = value == "no"
    pipController?.setPlaying(isPlaying)
    playerCore?.setPaused(!isPlaying)
  }

  private func handleSetDisplayMode(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let width = args["width"] as? Int,
      let height = args["height"] as? Int,
      let refreshRate = (args["refreshRate"] as? NSNumber)?.doubleValue
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "Expected width, height and refreshRate", details: nil))
      return
    }
    withFlutterWindow(result) { window in
      self.displayModes.setMode(on: window, width: width, height: height, refreshRate: refreshRate) {
        result($0)
      }
    }
  }

  // MARK: - Helpers

  private func withFlutterWindow(_ result: @escaping FlutterResult, _ body: (NSWindow) -> Void) {
    guard let (window, _, _) = findFlutterWindow() else {
      result(FlutterError(code: "NO_WINDOW", message: "Could not find Flutter window", details: nil))
      return
    }
    body(window)
  }

  private func findFlutterWindow() -> (NSWindow, NSView, NSView)? {
    for window in NSApplication.shared.windows {
      if window is MainFlutterWindow,
        let contentView = window.contentView,
        let contentVC = window.contentViewController
      {
        let flutterView = contentVC.view
        return (window, contentView, flutterView)
      }
    }

    for window in NSApplication.shared.windows {
      if let contentView = window.contentView,
        let contentVC = window.contentViewController
      {
        let flutterView = contentVC.view
        return (window, contentView, flutterView)
      }
    }

    return nil
  }
}

/// A public AppKit window borrowing the same video/OSD layers as the owner.
/// Closing it returns those layers; no file or provider session is reopened.
private final class MpvDetachedVideoWindow: NSObject, NSWindowDelegate {
  private let window: NSWindow
  private let video: MpvPipVideoView
  private let onAction: (String) -> Void
  private let onRestore: () -> Void

  init(
    title: String, labels: [String: String], layers: [CALayer], geometryKey: String,
    onAction: @escaping (String) -> Void, onRestore: @escaping () -> Void
  ) {
    self.onAction = onAction
    self.onRestore = onRestore
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    video = MpvPipVideoView(layers: layers, size: NSSize(width: 800, height: 450))
    super.init()
    window.title = title
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenPrimary]
    window.contentMinSize = NSSize(width: 360, height: 240)
    let root = NSStackView()
    root.orientation = .vertical
    root.spacing = 0
    root.alignment = .width
    root.addArrangedSubview(video)
    let controls = NSStackView()
    controls.orientation = .horizontal
    controls.spacing = 12
    controls.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    for (action, key) in [
      ("seekBackward", "back"), ("togglePlayback", "playPause"),
      ("seekForward", "forward"), ("restore", "restore"),
    ] {
      let button = NSButton(
        title: String((labels[key] ?? action).prefix(240)), target: self, action: #selector(control(_:)))
      button.identifier = NSUserInterfaceItemIdentifier(action)
      button.setAccessibilityLabel(button.title)
      controls.addArrangedSubview(button)
    }
    root.addArrangedSubview(controls)
    video.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    controls.setContentHuggingPriority(.required, for: .vertical)
    window.contentView = root
    window.delegate = self
    window.center()
    if geometryKey.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
      let name = NSWindow.FrameAutosaveName("org.snapetech.plezyng.detached.\(geometryKey)")
      window.setFrameAutosaveName(name)
      window.setFrameUsingName(name)
      window.setFrame(window.constrainFrameRect(window.frame, to: window.screen ?? NSScreen.main), display: false)
    }
    window.makeKeyAndOrderFront(nil)
  }

  @objc private func control(_ sender: NSButton) {
    guard let action = sender.identifier?.rawValue else { return }
    if action == "restore" { onRestore() } else { onAction(action) }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool { onRestore(); return false }
  func releaseLayers() -> [CALayer] { video.releaseLayers() }
  func close() { window.delegate = nil; window.close() }
}

// MARK: - MpvPipDelegate

extension MpvPlayerPlugin: MpvPipDelegate {

  func pipWillStart() {
    MpvLog.debug("[MpvPlayerPlugin] PiP will start")
  }

  func pipDidStart() {
    MpvLog.debug("[MpvPlayerPlugin] PiP did start")
  }

  func pipDidStop(restored: Bool) {
    MpvLog.debug("[MpvPlayerPlugin] PiP did stop (restored: \(restored))")
    playerCore?.isPipActive = false
    enteredPipViaAuto = false

    let layers = pipController?.detachLayers() ?? []
    playerCore?.takeBackVideoLayers(layers)

    pipChannel?.invokeMethod("onPipChanged", arguments: false)
  }

  func pipSetPlaying(_ playing: Bool) {
    guard let playerCore else { return }
    playerCore.setPropertyAsync("pause", value: playing ? "no" : "yes") { [weak self] propertyResult in
      guard case .success = propertyResult else { return }
      self?.pipController?.setPlaying(playing)
      playerCore.setPaused(!playing)
    }
  }

  var isPipPlaying: Bool { !(playerCore?.isPaused ?? true) }
}
