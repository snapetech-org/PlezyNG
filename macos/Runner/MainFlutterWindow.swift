import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var workspaceViews: WorkspaceDesktopWindows?

  private var downloadStorageChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    let engine = FlutterEngine(name: "Pleazyng", project: project, allowHeadlessExecution: false)
    // This Flutter SDK exposes multiview setup on the engine before any view
    // controller is attached. Keep the ordinary main view available if it
    // disappears in a future SDK and disable detached views in that case.
    let enableMultiView = NSSelectorFromString("enableMultiView")
    let supportsMultiView = engine.responds(to: enableMultiView)
    if supportsMultiView { _ = engine.perform(enableMultiView) }
    let flutterViewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    workspaceViews = WorkspaceDesktopWindows(engine: engine, parent: self, available: supportsMultiView)
    DownloadBackupPolicy.refreshExistingRoots()
    let storageChannel = FlutterMethodChannel(
      name: "com.pleazyng/download_storage", binaryMessenger: flutterViewController.engine.binaryMessenger)
    storageChannel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup", let path = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        result(try DownloadBackupPolicy.exclude(URL(fileURLWithPath: path)))
      } catch {
        result(FlutterError(code: "backup_exclusion", message: "Could not update download backup policy", details: nil))
      }
    }
    downloadStorageChannel = storageChannel
    let preparationWorker = CommandLine.arguments.contains("--plezy-preparation-worker")
    if preparationWorker {
      NSApp.setActivationPolicy(.prohibited)
      self.orderOut(nil)
      RegisterGeneratedPlugins(registry: flutterViewController)
      self.contentViewController = flutterViewController
      return
    }

    // Keep the window itself opaque so WindowServer does not have to blend the
    // whole video window with the desktop every frame. Flutter stays clear so
    // the native video layer behind it remains visible.
    self.isOpaque = true
    self.backgroundColor = NSColor.black
    flutterViewController.backgroundColor = NSColor.clear

    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Configure window chrome before restoring the saved frame.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    // Add forwarding toolbar for click-through in titlebar area
    let toolbar = ForwardingToolbar(flutterViewController: flutterViewController)
    self.toolbar = toolbar

    MpvPlayerPlugin.register(
      with: flutterViewController.registrar(forPlugin: "MpvPlayerPlugin"))

    MpvPlayerPlugin.registerWorkspace(
      with: flutterViewController.registrar(forPlugin: "MpvWorkspacePlayerPlugin"))

    MpvAudioPlayerPlugin.register(
      with: flutterViewController.registrar(forPlugin: "MpvAudioPlayerPlugin"))

    WindowUtilsPlugin.register(
      with: flutterViewController.registrar(forPlugin: "WindowUtilsPlugin"))
    WindowUtilsPlugin.setWindow(self)
    WindowUtilsPlugin.installWindowDelegate()
    WindowUtilsPlugin.syncWindowChrome()

    AppLookupPlugin.register(
      with: flutterViewController.registrar(forPlugin: "AppLookupPlugin"))

    DeepLinkPlugin.register(
      with: flutterViewController.registrar(forPlugin: "DeepLinkPlugin"))

    PlezySteamPlugin.register(with: flutterViewController.registrar(forPlugin: "PlezySteamPlugin"))

    RegisterGeneratedPlugins(registry: flutterViewController)

    self.setFrameAutosaveName("org.snapetech.plezyng.MainWindow")
    WindowUtilsPlugin.syncWindowChrome()

    super.awakeFromNib()
  }
}

/// Additional Flutter views share the existing engine, isolate and session owners.
private final class WorkspaceDesktopWindows: NSObject {
  private let engine: FlutterEngine
  private let available: Bool
  private let channel: FlutterMethodChannel
  private var windows: [String: WorkspaceDesktopWindow] = [:]
  private var closingObserver: NSObjectProtocol?

  init(engine: FlutterEngine, parent: NSWindow, available: Bool) {
    self.engine = engine
    self.available = available
    channel = FlutterMethodChannel(name: "com.pleazyng/workspace_views", binaryMessenger: engine.binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      self.handle(call, result: result)
    }
    closingObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: parent, queue: .main
    ) { [weak self] _ in self?.closeAll() }
  }

  deinit {
    if let closingObserver { NotificationCenter.default.removeObserver(closingObserver) }
    channel.setMethodCallHandler(nil)
    closeAll()
  }

  private func closeAll() {
    let previous = windows
    windows.removeAll()
    for window in previous.values { window.retire() }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "available" { result(available); return }
    guard let args = call.arguments as? [String: Any],
      let token = args["token"] as? String,
      token.range(of: "^[A-Za-z0-9_-]{32}$", options: .regularExpression) != nil
    else {
      result(FlutterError(code: "INVALID_WINDOW", message: "Invalid window identity", details: nil))
      return
    }
    switch call.method {
    case "create":
      guard available, windows.count < 8, windows[token] == nil,
        let geometry = args["geometryKey"] as? String,
        geometry.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
        let title = args["title"] as? String, title.utf8.count <= 1024
      else {
        result(FlutterError(code: "INVALID_WINDOW", message: "Invalid window configuration", details: nil))
        return
      }
      let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
      let window = WorkspaceDesktopWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = title
      window.minSize = NSSize(width: 320, height: 240)
      window.contentViewController = controller
      window.setFrameAutosaveName("org.snapetech.pleazyng.workspace." + geometry)
      window.delegate = window
      window.requestClose = { [weak self] in
        self?.channel.invokeMethod("closeRequested", arguments: ["token": token])
      }
      if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
        window.center()
      }
      windows[token] = window
      result(["viewId": controller.viewIdentifier])
    case "show":
      windows[token]?.makeKeyAndOrderFront(nil)
      result(nil)
    case "close":
      windows.removeValue(forKey: token)?.retire()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private final class WorkspaceDesktopWindow: NSWindow, NSWindowDelegate {
  var requestClose: (() -> Void)?
  private var retiring = false
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if retiring { return true }
    requestClose?()
    return false
  }

  func retire() {
    guard !retiring else { return }
    retiring = true
    requestClose = nil
    contentViewController = nil
    close()
  }
}
