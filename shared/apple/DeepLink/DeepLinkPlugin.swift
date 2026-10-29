import CryptoKit
import Foundation

#if os(iOS) || os(tvOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Answers `com.plezy/deep_link` on iOS, iPadOS, tvOS and macOS. It hands every `plezy:` or
/// `plezxyng:` URL the system opens to Dart unchanged.
///
/// Dart owns the link grammar (lib/services/deep_links/deep_link.dart), so only the scheme is
/// checked here. A link stays retained until Dart takes it: `getInitialLink` returns it and
/// switches the engine to live delivery, after which `onLink` delivers each new link and only a
/// `true` reply clears it. Compiled into the iOS, tvOS and macOS Runners.
final class DeepLinkPlugin: NSObject, FlutterPlugin {
  private static let schemes: Set<String> = ["plezy", "plezxyng"]
  // Process-wide so a link received before a (re)created engine registers is not lost.
  private static let delivery = DeepLinkDeliveryCoordinator()
  private static var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
      let messenger = registrar.messenger
    #else
      let messenger = registrar.messenger()
    #endif
    let channel = FlutterMethodChannel(name: "com.plezy/deep_link", binaryMessenger: messenger)
    Self.channel = channel
    delivery.bindEngine()
    let instance = DeepLinkPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    let subtitleChannel = FlutterMethodChannel(
      name: "com.plezy/subtitle_import", binaryMessenger: messenger)
    AppleSubtitleInbox.shared.bind(subtitleChannel)
    registrar.addMethodCallDelegate(instance, channel: subtitleChannel)
    #if os(macOS)
      registrar.addApplicationDelegate(instance)
    #else
      registrar.addSceneDelegate(instance)
    #endif
  }

  /// The string Dart receives for `url`, or nil when it is not a Plezy link.
  static func forwardedLink(for url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
    return url.absoluteString
  }

  /// Takes `url` when it is a Plezy link, delivering it now or retaining it for Dart.
  static func receive(_ url: URL) -> Bool {
    if url.isFileURL { return AppleSubtitleInbox.shared.receive(url) }
    guard let link = forwardedLink(for: url) else { return false }
    if case let .deliver(event) = delivery.receive(url: link) {
      deliverLive(event)
    }
    return true
  }

  /// Offers every URL to `handler` and reports whether any was taken.
  static func receiveAll(
    _ urls: [URL],
    using handler: (URL) -> Bool = DeepLinkPlugin.receive
  ) -> Bool {
    var handled = false
    for url in urls where handler(url) {
      handled = true
    }
    return handled
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPendingSubtitleFiles":
      AppleSubtitleInbox.shared.pending(result)
    case "acknowledgeSubtitleFiles":
      AppleSubtitleInbox.shared.acknowledge(call.arguments as? [String] ?? [], result: result)
    case "getInitialLink":
      let event = Self.delivery.beginLiveDelivery()
      result(event?.url)
      if let event, let next = Self.delivery.complete(event, succeeded: true) {
        Self.deliverLive(next)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  #if os(macOS)
    func handleOpen(_ urls: [URL]) -> Bool {
      Self.receiveAll(urls)
    }
  #endif

  private static func deliverLive(_ event: DeepLinkDeliveryCoordinator.Event) {
    guard let channel else { return }
    channel.invokeMethod("onLink", arguments: event.flutterArguments) { reply in
      // Anything but `true` (no handler yet, error, not implemented) keeps the link retained.
      let succeeded = reply as? Bool == true
      if let next = delivery.complete(event, succeeded: succeeded) {
        deliverLive(next)
      }
    }
  }
}

/// Copies external documents while their security scope is alive. Only immutable
/// app-owned files cross into Dart; an engine restart cannot lose the native inbox.
/// Kept in this shared Runner source so every Apple target uses the same protocol.
private final class AppleSubtitleInbox {
  static let shared = AppleSubtitleInbox()
  private let worker = DispatchQueue(label: "org.plezy.subtitle-inbox", qos: .utility)
  private let admission = NSLock()
  private var admitted = 0
  private var channel: FlutterMethodChannel?
  private let maximumFiles = 12
  private let maximumBytes = 128 * 1024 * 1024
  private let lifetime: TimeInterval = 7 * 24 * 60 * 60
  private let extensions: Set<String> = [
    "ass", "idx", "mpl", "scc", "smi", "srt", "ssa",
    "sub", "sup", "ttml", "dfxp", "imsc", "sami", "sbv", "lrc", "vtt",
    "xml", "zip", "tar", "tgz", "gz"
  ]

  func bind(_ channel: FlutterMethodChannel) { self.channel = channel }

  private func limit(_ url: URL) -> Int? {
    let ext = url.pathExtension.lowercased(), name = url.lastPathComponent.lowercased()
    guard extensions.contains(ext), ext != "gz" || name.hasSuffix(".tar.gz") else { return nil }
    return ["zip", "tar", "tgz", "gz"].contains(ext) ? 50 * 1024 * 1024 : 32 * 1024 * 1024
  }

  private func root() throws -> URL {
    let manager = FileManager.default
    let cache = try manager.url(for: .cachesDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let directory = cache.appendingPathComponent("plezyng_apple_subtitle_inbox", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  // Worker queue only. Files created here have random names and are never edited.
  private func snapshot() throws -> [(url: URL, bytes: Int)] {
    let manager = FileManager.default, directory = try root()
    let files = try manager.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
    var result: [(url: URL, bytes: Int)] = []
    var bytes = 0
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
      let count = values.fileSize ?? 0
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let maximum = limit(file), count > 0, count <= maximum,
        let modified = values.contentModificationDate, Date().timeIntervalSince(modified) <= lifetime,
        result.count < maximumFiles, bytes + count <= maximumBytes else {
        try? manager.removeItem(at: file)
        continue
      }
      result.append((file, count))
      bytes += count
    }
    return result
  }

  func receive(_ url: URL) -> Bool {
    guard url.isFileURL, url.path.utf8.count <= 8192, limit(url) != nil else { return false }
    admission.lock()
    guard admitted < maximumFiles else { admission.unlock(); return false }
    admitted += 1
    admission.unlock()
    // An Inbox copy may already be readable without a sandbox extension. A false
    // result is not a reason to bypass filesystem permissions or retain a grant.
    let scoped = url.startAccessingSecurityScopedResource()
    worker.async {
      defer {
        if scoped { url.stopAccessingSecurityScopedResource() }
        self.admission.lock()
        self.admitted -= 1
        self.admission.unlock()
      }
      do {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
          error: &coordinationError) { coordinated in
          do { try self.stage(coordinated, identity: url) }
          catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        DispatchQueue.main.async { self.channel?.invokeMethod("filesAvailable", arguments: nil) }
      } catch {
        // Do not expose external paths or provider credentials to logs or Dart.
        DispatchQueue.main.async {
          self.channel?.invokeMethod("importFailed", arguments: nil)
        }
      }
    }
    return true
  }

  private func stage(_ source: URL, identity: URL) throws {
    let entries = try snapshot()
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    let expected = values.fileSize ?? 0
    guard let maximum = limit(identity), values.isRegularFile == true, values.isSymbolicLink != true,
      expected > 0, expected <= maximum else { throw CocoaError(.fileReadCorruptFile) }
    // Hash only the original parent and stem to keep IDX/SUB companions together;
    // no provider URL is persisted. A new admission after acknowledgement gets a
    // new UUID, so opening an updated subtitle cannot overwrite an older import.
    let key = SHA256.hash(data: Data(identity.deletingPathExtension().absoluteString.utf8))
      .prefix(16).map { String(format: "%02x", $0) }.joined()
    let prefix = entries.first(where: { $0.url.lastPathComponent.hasPrefix(key + "_") })
      .map { String($0.url.lastPathComponent.prefix(69)) } ?? key + "_" + UUID().uuidString
    let rawName = identity.lastPathComponent
    guard rawName.utf8.count <= 174 else { throw CocoaError(.fileReadInvalidFileName) }
    let name = rawName.unicodeScalars.map { scalar -> String in
      CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._ -")
        .contains(scalar) ? String(scalar) : "_"
    }.joined()
    let destination = try root().appendingPathComponent(prefix + "_" + name)
    if entries.contains(where: { $0.url == destination }) { return }
    let retained = entries.reduce(0) { $0 + $1.bytes }
    guard entries.count < maximumFiles, retained + expected <= maximumBytes else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    let partial = destination.appendingPathExtension("part")
    defer { try? FileManager.default.removeItem(at: partial) }
    guard let input = InputStream(url: source), let output = OutputStream(url: partial, append: false) else {
      throw CocoaError(.fileReadUnknown)
    }
    input.open(); output.open()
    defer { input.close(); output.close() }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var copied = 0
    let deadline = Date().addingTimeInterval(60)
    while true {
      guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
      let count = input.read(&buffer, maxLength: 64 * 1024)
      guard count >= 0 else { throw input.streamError ?? CocoaError(.fileReadUnknown) }
      if count == 0 { break }
      copied += count
      guard copied <= expected, copied <= maximum else { throw CocoaError(.fileReadCorruptFile) }
      try buffer.withUnsafeBufferPointer { bytes in
        var written = 0
        while written < count {
          let size = output.write(bytes.baseAddress!.advanced(by: written), maxLength: count - written)
          guard size > 0 else { throw output.streamError ?? CocoaError(.fileWriteUnknown) }
          written += size
        }
      }
    }
    guard copied == expected else { throw CocoaError(.fileReadCorruptFile) }
    output.close()
    try FileManager.default.moveItem(at: partial, to: destination)
  }

  func pending(_ result: @escaping FlutterResult) {
    worker.async {
      do {
        let files = try self.snapshot().map { ["id": $0.url.lastPathComponent, "path": $0.url.path] }
        DispatchQueue.main.async { result(files) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "subtitle_inbox", message: "Could not read the subtitle inbox.", details: nil))
        }
      }
    }
  }

  func acknowledge(_ ids: [String], result: @escaping FlutterResult) {
    worker.async {
      do {
        let accepted = Set(ids.prefix(self.maximumFiles))
        // IDs are compared against our directory listing, never appended to a path.
        for entry in try self.snapshot() where accepted.contains(entry.url.lastPathComponent) {
          try FileManager.default.removeItem(at: entry.url)
        }
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "subtitle_inbox", message: "Could not acknowledge subtitle files.", details: nil))
        }
      }
    }
  }
}

#if os(iOS) || os(tvOS)
  extension DeepLinkPlugin: FlutterSceneLifeCycleDelegate {
    // A cold launch carries its link in the connection options; `scene(_:openURLContexts:)` only
    // fires for links that arrive while the scene is connected.
    func scene(
      _ scene: UIScene,
      willConnectTo session: UISceneSession,
      options connectionOptions: UIScene.ConnectionOptions?
    ) -> Bool {
      guard let connectionOptions else { return false }
      return Self.receiveAll(connectionOptions.urlContexts.map(\.url))
    }

    func scene(
      _ scene: UIScene,
      openURLContexts URLContexts: Set<UIOpenURLContext>
    ) -> Bool {
      Self.receiveAll(URLContexts.map(\.url))
    }
  }
#endif
