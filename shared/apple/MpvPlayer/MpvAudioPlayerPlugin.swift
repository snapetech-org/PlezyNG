import CoreFoundation

#if os(iOS) || os(tvOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Flutter plugin for the dedicated audio-only mpv core (music playback).
///
/// Registers `com.plezy/mpv_audio_player` + `/events` and delegates all
/// generic property/command/observe traffic to the shared [MpvPluginShared]
/// handlers. There is no render layer, so the visual hooks are no-ops and
/// `setVisible`/`updateFrame` succeed without doing anything. Shared across
/// iOS, tvOS, and macOS — unlike the video plugin there is nothing
/// platform-specific beyond the messenger accessor.
class MpvAudioPlayerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, MpvPluginShared {

  private var playerCore: MpvAudioPlayerCore?
  private var textureRegistry: FlutterTextureRegistry?
  private var visualizer: MilkRustFlutterTexture?
  private var visualizerTextureId: Int64 = -1
  private var visualizerSessionId: Int64 = 0
  var eventSink: FlutterEventSink?
  var nameToId: [String: Int] = [:]

  // MpvPluginShared conformance — the audio core has no visual surface.
  var coreBase: MpvPlayerCoreBase? { playerCore }
  func setPlayerVisible(_ visible: Bool, restoreOnWindowVisible _: Bool) {}
  func updatePlayerFrame() {}
  func setPlayerVideoRect(
    left _: Int, top _: Int, right _: Int, bottom _: Int, devicePixelRatio _: Double
  ) {}
  func setPlayerVideoZoom(_: Double) {}
  func didSetPauseProperty(value _: String) {}

  // MARK: - FlutterPlugin Registration

  static func register(with registrar: FlutterPluginRegistrar) {
    register(with: registrar, channelName: "com.plezy/mpv_audio_player")
    #if os(iOS) || os(tvOS)
      MusicSystemAudioRoutePlugin.register(with: registrar)
    #endif
  }

  static func registerOverlap(with registrar: FlutterPluginRegistrar) {
    register(with: registrar, channelName: "com.plezy/mpv_audio_player/overlap")
  }

  static func registerGroupOutput(with registrar: FlutterPluginRegistrar) {
    register(with: registrar, channelName: "com.plezy/mpv_audio_player/group_output")
  }

  private static func register(with registrar: FlutterPluginRegistrar, channelName: String) {
    #if os(macOS)
      let messenger = registrar.messenger
    #else
      let messenger = registrar.messenger()
    #endif

    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    let eventChannel = FlutterEventChannel(
      name: "\(channelName)/events",
      binaryMessenger: messenger
    )

    let instance = MpvAudioPlayerPlugin()
    #if os(macOS)
      instance.textureRegistry = registrar.textures
    #else
      instance.textureRegistry = registrar.textures()
    #endif
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  // MARK: - FlutterPlugin Method Handler

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method.hasPrefix("visualizer") { handleVisualizer(call, result: result); return }
    switch call.method {
    case "musicPcmCaptureAvailable", "setMusicPcmCaptureEnabled", "drainMusicPcmCapture":
      handleMusicPcmCapture(call: call, result: result)
    case "initialize":
      handleInitialize(result: result)
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
    case "isInitialized":
      result(playerCore?.isInitialized ?? false)
    case "setVisible", "updateFrame":
      // No render layer — succeed so shared Dart call sites stay unconditional.
      result(nil)
    case "setLogLevel":
      handleSetLogLevel(call: call, result: result)
    case "getAudioSpdifCodecs":
      result(MpvPlayerCoreBase.audioSpdifCodecs)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleInitialize(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(FlutterError(code: "ERROR", message: "Plugin deallocated", details: nil))
        return
      }

      if self.playerCore?.isInitialized == true {
        result(true)
        return
      }

      let core = MpvAudioPlayerCore()
      core.delegate = self

      guard core.initialize() else {
        result(
          FlutterError(
            code: "MPV_INIT_FAILED", message: "Failed to initialize MPV audio core", details: nil))
        return
      }

      self.playerCore = core
      result(true)
    }
  }

  private func handleDispose(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { result(nil); return }
      self.disposeVisualizer()
      self.playerCore?.dispose()
      self.playerCore = nil
      result(nil)
    }
  }
  private func disposeVisualizer() {
    visualizer?.host.close()
    if visualizerTextureId >= 0 { textureRegistry?.unregisterTexture(visualizerTextureId) }
    visualizer = nil; visualizerTextureId = -1; visualizerSessionId &+= 1
    _ = playerCore?.setVisualizationTap(false)
  }

  private func handleVisualizer(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let engine = args["engine"] as? String ?? "projectm"
    func reason() -> String {
      guard playerCore?.isInitialized == true else { return "Initialize the music player before opening a preset." }
      guard engine == "milkrust" else {
        return "Select native MilkRust on Apple platforms; this host does not bundle projectM."
      }
      guard PlezyVisualizationTapAvailable() else { return "This mpv build lacks the visualization PCM tap ABI v1." }
      return PlezyMilkRustHost.dependencyError()
    }
    if call.method == "visualizerCapabilities" {
      let unavailable = reason()
      result([
        "available": unavailable.isEmpty, "reason": unavailable, "engine": "milkrust-native-abi2",
        "audioTap": PlezyVisualizationTapAvailable(),
      ]); return
    }
    do {
      if call.method == "visualizerCreate" {
        let unavailable = reason()
        guard unavailable.isEmpty, let core = playerCore, let registry = textureRegistry else {
          result(FlutterError(code: "VISUALIZER_UNAVAILABLE", message: unavailable, details: nil)); return
        }
        disposeVisualizer()
        guard core.setVisualizationTap(true) >= 0 else {
          result(FlutterError(code: "VISUALIZER_AUDIO", message: "Could not attach to music PCM.", details: nil));
          return
        }
        let lease = visualizerSessionId
        let host: PlezyMilkRustHost?
        do {
          host = try PlezyMilkRustHost(
            audioReader: { [weak core] output, size in
              core?.readVisualizationAudio(output, size: size) ?? -1001
            },
            frameAvailable: { [weak self] in
              DispatchQueue.main.async { [weak self] in
                guard let self, self.visualizerSessionId == lease, self.visualizerTextureId >= 0 else { return }
                self.textureRegistry?.textureFrameAvailable(self.visualizerTextureId)
              }
            })
        } catch { _ = core.setVisualizationTap(false); throw error }
        guard let host else {
          _ = core.setVisualizationTap(false)
          result(
            FlutterError(code: "VISUALIZER_CREATE", message: "Could not create the native renderer.", details: nil));
          return
        }
        let texture = MilkRustFlutterTexture(host: host)
        let id = registry.register(texture)
        guard id >= 0 else {
          host.close(); _ = core.setVisualizationTap(false)
          result(FlutterError(code: "VISUALIZER_CREATE", message: "Flutter rejected the texture.", details: nil));
          return
        }
        visualizer = texture; visualizerTextureId = id
        result(["sessionId": visualizerSessionId, "textureId": id]); return
      }
      guard let texture = visualizer, (args["sessionId"] as? NSNumber)?.int64Value == visualizerSessionId else {
        result(FlutterError(code: "VISUALIZER_STALE", message: "This visualization session has ended.", details: nil));
        return
      }
      switch call.method {
      case "visualizerDispose": disposeVisualizer()
      case "visualizerLoad":
        guard let path = args["path"] as? String, let root = args["root"] as? String else {
          result(
            FlutterError(code: "INVALID_ARGS", message: "A preset path and pack root are required.", details: nil));
          return
        }
        let transition: Double
        if let value = args["transitionSeconds"] {
          guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            result(
              FlutterError(code: "INVALID_ARGS", message: "A numeric transition duration is required.", details: nil))
            return
          }
          transition = number.doubleValue
        } else {
          transition = 3
        }
        try texture.host.loadPreset(
          path, root: root, transitionSeconds: transition,
          allowInterrupted: args["allowInterrupted"] as? Bool ?? false)
      case "visualizerResize":
        guard let width = args["width"] as? Int, let height = args["height"] as? Int,
          width > 0, height > 0, width <= 16384, height <= 16384
        else {
          result(FlutterError(code: "INVALID_ARGS", message: "Invalid dimensions.", details: nil)); return
        }
        texture.host.resizeWidth(width, height: height)
      case "visualizerSetPaused":
        guard let paused = args["paused"] as? Bool else {
          result(FlutterError(code: "INVALID_ARGS", message: "A paused boolean is required.", details: nil)); return
        }
        texture.host.setPaused(paused)
      case "visualizerSetMouse":
        guard let down = args["down"] as? Bool,
          let x = args["x"] as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID(),
          let y = args["y"] as? NSNumber, CFGetTypeID(y) != CFBooleanGetTypeID(),
          let dx = args["dx"] as? NSNumber, CFGetTypeID(dx) != CFBooleanGetTypeID(),
          let dy = args["dy"] as? NSNumber, CFGetTypeID(dy) != CFBooleanGetTypeID(),
          x.doubleValue.isFinite, y.doubleValue.isFinite, dx.doubleValue.isFinite, dy.doubleValue.isFinite
        else {
          result(FlutterError(code: "INVALID_ARGS", message: "Finite mouse state is required.", details: nil)); return
        }
        texture.host.setMouseState(down, x: x.doubleValue, y: y.doubleValue, dx: dx.doubleValue, dy: dy.doubleValue)
      case "visualizerStatus": result(texture.host.status()); return
      default: result(FlutterMethodNotImplemented); return
      }
      result(nil)
    } catch { result(FlutterError(code: "VISUALIZER_NATIVE", message: error.localizedDescription, details: nil)) }
  }

  deinit { disposeVisualizer() }

}

private final class MilkRustFlutterTexture: NSObject, FlutterTexture {
  let host: PlezyMilkRustHost
  init(host: PlezyMilkRustHost) { self.host = host; super.init() }
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let buffer = host.copyPixelBuffer() else { return nil }
    return Unmanaged.passRetained(buffer)
  }
}

#if os(iOS) || os(tvOS)
  import AVFAudio
  import AVKit

  /// OS-selected routes only. Inspection and observation never activate the
  /// audio session, change its category, claim focus or start media.
  private class MusicSystemAudioRoutePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var notification: NSObjectProtocol?
    private var events: FlutterEventSink?

    static func register(with registrar: FlutterPluginRegistrar) {
      let bridge = MusicSystemAudioRoutePlugin()
      let messenger = registrar.messenger()
      let methods = FlutterMethodChannel(name: "com.pleazyng/music_audio_route", binaryMessenger: messenger)
      registrar.addMethodCallDelegate(bridge, channel: methods)
      FlutterEventChannel(name: "com.pleazyng/music_audio_route/events", binaryMessenger: messenger)
        .setStreamHandler(bridge)
      registrar.register(MusicAudioRoutePickerFactory(), withId: "com.pleazyng/music_audio_route_picker")
    }

    private static func snapshot() -> [String: Any] {
      let session = AVAudioSession.sharedInstance()
      let outputs = session.currentRoute.outputs.prefix(16).map { port -> [String: Any] in
        [
          "id": String(port.uid.prefix(512)),
          "name": String(port.portName.prefix(256)),
          "type": String(port.portType.rawValue.prefix(128)),
          "bluetooth": port.portType == .bluetoothA2DP || port.portType == .bluetoothHFP
            || port.portType == .bluetoothLE,
          "channels": port.channels?.count ?? 0,
        ]
      }
      return [
        "version": 1, "outputs": outputs,
        "sampleRate": session.sampleRate,
        "outputChannels": session.outputNumberOfChannels,
        "outputLatencyMs": session.outputLatency * 1000,
        "ioBufferMs": session.ioBufferDuration * 1000,
      ]
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      if call.method == "snapshot" { result(Self.snapshot()) } else { result(FlutterMethodNotImplemented) }
    }

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
      stopObserving()
      self.events = events
      notification = NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.events?(Self.snapshot())
      }
      events(Self.snapshot())
      return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
      stopObserving()
      return nil
    }

    private func stopObserving() {
      if let notification { NotificationCenter.default.removeObserver(notification) }
      notification = nil
      events = nil
    }

    deinit { stopObserving() }
  }

  private class MusicAudioRoutePickerFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
      FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier _: Int64, arguments args: Any?) -> FlutterPlatformView {
      MusicAudioRoutePicker(frame: frame, arguments: args as? [String: Any])
    }
  }

  private class MusicAudioRoutePicker: NSObject, FlutterPlatformView {
    private let picker: AVRoutePickerView

    init(frame: CGRect, arguments: [String: Any]?) {
      picker = AVRoutePickerView(frame: frame)
      if #available(iOS 13.0, tvOS 13.0, *) { picker.prioritizesVideoDevices = false }
      if let color = arguments?["tint"] as? NSNumber {
        let argb = color.uint32Value
        picker.tintColor = UIColor(
          red: CGFloat((argb >> 16) & 255) / 255,
          green: CGFloat((argb >> 8) & 255) / 255,
          blue: CGFloat(argb & 255) / 255,
          alpha: CGFloat((argb >> 24) & 255) / 255
        )
      }
      super.init()
    }

    func view() -> UIView { picker }
  }
#endif
