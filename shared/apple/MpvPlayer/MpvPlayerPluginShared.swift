import AVFoundation
import UniformTypeIdentifiers
import Foundation

#if os(iOS) || os(tvOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Protocol for shared MpvPlayerPlugin method handlers across iOS, tvOS, and macOS.
/// Platform-specific methods (PiP, initialization, window finding) remain
/// in the per-platform MpvPlayerPlugin files.
protocol MpvPluginShared: AnyObject, MpvPlayerDelegate {
  var coreBase: MpvPlayerCoreBase? { get }
  var eventSink: FlutterEventSink? { get }
  var nameToId: [String: Int] { get set }

  func setPlayerVisible(_ visible: Bool, restoreOnWindowVisible: Bool)
  func updatePlayerFrame()
  func setPlayerVideoRect(
    left: Int,
    top: Int,
    right: Int,
    bottom: Int,
    devicePixelRatio: Double
  )
  /// Viewer zoom as a transform on the display layer: mpv's `video-zoom`
  /// would push every frame through vo_avfoundation's Core Image path.
  func setPlayerVideoZoom(_ scale: Double)

  /// Invoked after the `pause` property is applied via setProperty so each
  /// platform can sync its PiP/idle bookkeeping (iOS: invalidate the PiP
  /// playback state + timebase; macOS: setPlaying/setPaused).
  func didSetPauseProperty(value: String)
}

extension MpvPluginShared {

  func handleSubtitlePcmCapture(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let core = coreBase else {
      result(
        FlutterError(code: "SUBTITLE_PCM_UNAVAILABLE", message: "The video MPV session is not available.", details: nil)
      )
      return
    }
    switch call.method {
    case "subtitlePcmCaptureAvailable":
      result(core.subtitlePcmCaptureAvailable())
    case "setSubtitlePcmCaptureEnabled":
      guard let args = call.arguments as? [String: Any], let enabled = args["enabled"] as? Bool else {
        result(FlutterError(code: "INVALID_ARGS", message: "An enabled boolean is required.", details: nil))
        return
      }
      result(core.setSubtitlePcmCaptureEnabled(enabled) >= 0)
    case "drainSubtitlePcmCapture":
      guard let batch = core.drainSubtitlePcmCapture() else {
        result(
          FlutterError(code: "SUBTITLE_PCM_UNAVAILABLE", message: "The video MPV session has ended.", details: nil))
        return
      }
      if batch.error < 0 {
        result(
          FlutterError(
            code: "SUBTITLE_PCM_READ", message: "The native PCM capture tap failed (\(batch.error)).", details: nil))
        return
      }
      let packets = batch.packets.map { packet -> [String: Any] in
        var encoded = packet
        if let pcm = packet["pcm"] as? Data {
          encoded["pcm"] = FlutterStandardTypedData(bytes: pcm)
        }
        return encoded
      }
      result(packets)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func handleSetProperty(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let name = args["name"] as? String,
      let value = args["value"] as? String
    else {
      result(
        FlutterError(
          code: "INVALID_ARGS", message: "Missing 'name' or 'value' argument",
          details: nil))
      return
    }

    guard let core = coreBase else {
      result(
        FlutterError(
          code: "NOT_INITIALIZED", message: "MPV player is not initialized", details: nil))
      return
    }

    core.setPropertyAsync(name, value: value) { [weak self] propertyResult in
      switch propertyResult {
      case .success:
        if name == "pause" {
          self?.didSetPauseProperty(value: value)
        }
        result(nil)
      case .failure(let error):
        if error is MpvLifecycleUnavailableError {
          result(
            FlutterError(
              code: "NOT_INITIALIZED", message: "MPV player is not initialized", details: nil))
          return
        }
        // The mpv error string is the only thing that tells a rejected option
        // apart from a cancelled write; the property name says which write.
        result(
          FlutterError(
            code: "SET_PROPERTY_FAILED",
            message: "MPV rejected or cancelled the property write '\(name)': \(error.localizedDescription)",
            details: name))
      }
    }
  }

  func handleGetProperty(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let name = args["name"] as? String
    else {
      result(
        FlutterError(code: "INVALID_ARGS", message: "Missing 'name' argument", details: nil)
      )
      return
    }
    coreBase?.getPropertyAsync(name) { propertyResult in
      switch propertyResult {
      case .success(let value):
        result(value)
      case .failure:
        result(nil)
      }
    } ?? result(nil)
  }

  func handleObserveProperty(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let name = args["name"] as? String,
      let format = args["format"] as? String,
      let id = args["id"] as? Int
    else {
      result(
        FlutterError(
          code: "INVALID_ARGS", message: "Missing 'name', 'format', or 'id' argument",
          details: nil))
      return
    }

    nameToId[name] = id
    coreBase?.observeProperty(name, format: format)
    result(nil)
  }

  func handleCommand(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let commandArgs = args["args"] as? [String]
    else {
      result(
        FlutterError(code: "INVALID_ARGS", message: "Missing 'args' argument", details: nil)
      )
      return
    }

    // `loadfile` answers with the playlist entry it created so Dart can tie
    // the load to that source's start-file/playback-restart/end-file events;
    // every other command answers nil.
    coreBase?.commandAsync(commandArgs) { commandResult in
      switch commandResult {
      case .success(let playlistEntryId):
        result(playlistEntryId.map { ["playlistEntryId": $0] })
      case .failure(let error):
        result(
          FlutterError(
            code: "COMMAND_FAILED", message: error.localizedDescription, details: nil))
      }
    } ?? result(nil)
  }

  func handleSetVisible(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let visible = args["visible"] as? Bool
    else {
      result(
        FlutterError(
          code: "INVALID_ARGS", message: "Missing 'visible' argument", details: nil))
      return
    }
    let restoreOnWindowVisible = args["restoreOnWindowVisible"] as? Bool ?? false

    DispatchQueue.main.async { [weak self] in
      self?.setPlayerVisible(visible, restoreOnWindowVisible: restoreOnWindowVisible)
      if visible { self?.updatePlayerFrame() }
      result(nil)
    }
  }

  func handleUpdateFrame(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      self?.updatePlayerFrame()
      result(nil)
    }
  }

  func handleSetVideoRect(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let left = args["left"] as? Int,
      let top = args["top"] as? Int,
      let right = args["right"] as? Int,
      let bottom = args["bottom"] as? Int,
      let devicePixelRatio = args["devicePixelRatio"] as? Double,
      devicePixelRatio.isFinite,
      devicePixelRatio > 0
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "Invalid video rectangle", details: nil))
      return
    }

    DispatchQueue.main.async { [weak self] in
      self?.setPlayerVideoRect(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        devicePixelRatio: devicePixelRatio
      )
      result(nil)
    }
  }

  func handleSetVideoZoom(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let rawScale = (call.arguments as? [String: Any])?["scale"]
    let scale: Double?
    switch rawScale {
    case let value as Double: scale = value
    case let value as NSNumber: scale = value.doubleValue
    case let value as String: scale = Double(value)
    default: scale = nil
    }
    guard let scale else {
      result(FlutterError(code: "INVALID_ARGS", message: "setVideoZoom requires scale", details: nil))
      return
    }
    setPlayerVideoZoom(scale)
    result(nil)
  }

  func handleSetLogLevel(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let level = args["level"] as? String
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "Missing 'level'", details: nil))
      return
    }
    // The same switch drives mpv's own verbosity and the Swift-side traces, so
    // enabling "Debug Logging" in the app opens both.
    MpvLog.isDebugEnabled = MpvLog.isVerbose(level)
    coreBase?.setLogLevel(level)
    result(nil)
  }

  // MARK: - MpvPlayerDelegate

  func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {
    guard let eventSink = eventSink, let propId = nameToId[name] else { return }
    let message: [Any?] = [propId, value, sourceId]
    eventSink(message)
  }

  func onEvent(name: String, data: [String: Any]?) {
    guard let eventSink = eventSink else { return }
    var event: [String: Any] = ["type": "event", "name": name]
    if let data = data { event["data"] = data }
    eventSink(event)
  }
}

// Independent bounded audio analysis. No player core or AVAudioSession is used.
// AVAssetReader accepts only assets the installed OS marks readable; DRM and
// live/HLS sources are not downgraded to a different playback/audio route.
private final class SubtitleAnalysisRequest {
  let id: String
  private let lock = NSLock()
  private var cancelled = false
  private var asset: AVURLAsset?
  private var reader: AVAssetReader?
  let deadline = ProcessInfo.processInfo.systemUptime + 90
  init(_ id: String) { self.id = id }
  func cancel() {
    lock.lock(); cancelled = true; let a = asset; let r = reader; lock.unlock()
    a?.cancelLoading(); r?.cancelReading()
  }
  func bind(_ value: AVURLAsset) { lock.lock(); asset = value; let stop = cancelled; lock.unlock(); if stop { value.cancelLoading() } }
  func bind(_ value: AVAssetReader) { lock.lock(); reader = value; let stop = cancelled; lock.unlock(); if stop { value.cancelReading() } }
  func check() throws {
    lock.lock(); let stopped = cancelled; lock.unlock()
    if stopped || ProcessInfo.processInfo.systemUptime >= deadline { throw SubtitleAnalysisFailure.unavailable }
  }
}
private enum SubtitleAnalysisFailure: Error { case unavailable }

// AVAssetReader can request bounded random ranges without inheriting server
// credentials or redirect policy. The source owner renews upstream access.
private final class SubtitleAnalysisHttpLoader: NSObject, AVAssetResourceLoaderDelegate {
  let source: URL
  let assetURL: URL
  let request: SubtitleAnalysisRequest
  let length: Int64
  let type: String?
  let queue = DispatchQueue(label: "com.plezy.subtitle-analysis-ranges", qos: .utility)
  private var closed = false
  private let closeLock = NSLock()
  private static func configuration() -> URLSessionConfiguration {
    let value = URLSessionConfiguration.ephemeral
    value.timeoutIntervalForRequest = 10; value.timeoutIntervalForResource = 20
    value.httpCookieStorage = nil; value.httpShouldSetCookies = false; value.urlCache = nil
    value.requestCachePolicy = .reloadIgnoringLocalCacheData
    return value
  }
  private final class Fetch: NSObject, URLSessionDataDelegate {
    let owner: SubtitleAnalysisRequest
    let head: Bool
    let complete = DispatchSemaphore(value: 0)
    var bytes = Data(), response: HTTPURLResponse?, failed = false
    init(owner: SubtitleAnalysisRequest, head: Bool) { self.owner = owner; self.head = head }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
      guard let headers = response as? HTTPURLResponse, headers.statusCode == (head ? 200 : 206),
        head || response.expectedContentLength <= 262144 else { failed = true; completionHandler(.cancel); return }
      self.response = headers; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      do { try owner.check() } catch { failed = true; dataTask.cancel(); return }
      if head || bytes.count + data.count > 262144 { failed = true; dataTask.cancel(); return }
      bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      if error != nil { failed = true }; complete.signal()
    }
  }
  init(source: URL, request: SubtitleAnalysisRequest) throws {
    self.source = source; self.request = request
    var components = URLComponents(url: source, resolvingAgainstBaseURL: false)!
    components.scheme = "plezy-subtitle-analysis"; self.assetURL = components.url!
    var head = URLRequest(url: source); head.httpMethod = "HEAD"; head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let (_, response) = try Self.fetch(head, owner: request)
    guard response.statusCode == 200, let size = response.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }),
      size > 0, size <= 1_099_511_627_776 else { throw SubtitleAnalysisFailure.unavailable }
    length = size
    type = response.mimeType.flatMap { UTType(mimeType: $0)?.identifier }
    super.init()
  }
  func close() { closeLock.lock(); closed = true; closeLock.unlock() }
  private static func fetch(_ value: URLRequest, owner: SubtitleAnalysisRequest) throws -> (Data, HTTPURLResponse) {
    try owner.check()
    let receiver = Fetch(owner: owner, head: value.httpMethod == "HEAD")
    let session = URLSession(configuration: configuration(), delegate: receiver, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: value); task.resume()
    guard receiver.complete.wait(timeout: .now()+22) == .success else { task.cancel(); throw SubtitleAnalysisFailure.unavailable }
    try owner.check()
    guard !receiver.failed, let response = receiver.response else { throw SubtitleAnalysisFailure.unavailable }
    return (receiver.bytes, response)
  }
  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loading: AVAssetResourceLoadingRequest) -> Bool {
    do {
      closeLock.lock(); let stopped = closed; closeLock.unlock()
      guard !stopped, loading.request.url == assetURL else { throw SubtitleAnalysisFailure.unavailable }
      try request.check()
      if let info = loading.contentInformationRequest {
        info.contentType = type; info.contentLength = length; info.isByteRangeAccessSupported = true
      }
      if let data = loading.dataRequest {
        var offset = max(data.requestedOffset, data.currentOffset)
        guard data.requestedOffset >= 0, offset >= 0, offset <= length, data.requestedLength >= 0 else { throw SubtitleAnalysisFailure.unavailable }
        let requestedEnd = data.requestsAllDataToEndOfResource ? length :
          data.requestedOffset + min(length - data.requestedOffset, Int64(data.requestedLength))
        while offset < requestedEnd {
          try request.check()
          if loading.isCancelled { throw SubtitleAnalysisFailure.unavailable }
          let end = min(requestedEnd, offset+262144)-1
          var value = URLRequest(url: source)
          value.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
          value.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
          let (bytes, headers) = try Self.fetch(value, owner: request)
          guard headers.statusCode == 206, headers.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(length)",
            Int64(bytes.count) == end-offset+1, bytes.count <= 262144,
            headers.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) != false else { throw SubtitleAnalysisFailure.unavailable }
          data.respond(with: bytes); offset += Int64(bytes.count)
        }
      }
      loading.finishLoading()
    } catch { loading.finishLoading(with: SubtitleAnalysisFailure.unavailable) }
    return true
  }
}

final class SubtitleAnalysisBridge {
  private let worker = DispatchQueue(label: "com.plezy.subtitle-analysis", qos: .utility)
  private var active: SubtitleAnalysisRequest? // Main queue only.
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.plezy/subtitle_analysis", binaryMessenger: messenger)
    let bridge = SubtitleAnalysisBridge()
    channel.setMethodCallHandler { [bridge] call, result in bridge.handle(call, result) }
  }
  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    if call.method == "capabilities" { result(["version": 1, "backend": "Apple AVAssetReader", "maxWindowMs": 64000]); return }
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "cancel" { if active?.id == args["id"] as? String { active?.cancel() }; result(nil); return }
    guard call.method == "decode" else { result(FlutterMethodNotImplemented); return }
    guard let id = args["id"] as? String, id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
      let source = args["uri"] as? String, let url = URL(string: source), url.user == nil, url.password == nil, url.fragment == nil,
      (url.isFileURL && (url.host ?? "").isEmpty || url.scheme == "http" && url.host == "127.0.0.1"),
      let start = args["startMs"] as? Int, let end = args["endMs"] as? Int,
      start >= 0, end > start, end <= 28_800_000, end-start <= 64_000,
      let ordinal = args["audioOrdinal"] as? Int, (0...63).contains(ordinal) else {
      result(FlutterError(code: "ANALYSIS_ARGUMENTS", message: "Invalid owned source or bounded audio window", details: nil)); return
    }
    guard active == nil else { result(FlutterError(code: "ANALYSIS_BUSY", message: "Another analysis decoder is closing or active", details: nil)); return }
    let request = SubtitleAnalysisRequest(id); active = request
    worker.async { [weak self] in
      do {
        let data = try Self.decode(url, start: start, end: end, ordinal: ordinal, request: request)
        DispatchQueue.main.async { self?.active = nil; result(FlutterStandardTypedData(bytes: data)) }
      } catch {
        DispatchQueue.main.async {
          self?.active = nil
          result(FlutterError(code: "ANALYSIS_DECODE", message: "Native audio decoding failed, timed out, was cancelled, or encountered an unreadable/protected source", details: nil))
        }
      }
    }
  }
  private static func decode(_ url: URL, start: Int, end: Int, ordinal: Int, request: SubtitleAnalysisRequest) throws -> Data {
    let loader: SubtitleAnalysisHttpLoader?
    if url.isFileURL { loader = nil } else { loader = try SubtitleAnalysisHttpLoader(source: url, request: request) }
    defer { loader?.close() }
    let asset = AVURLAsset(url: loader?.assetURL ?? url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    if let loader { asset.resourceLoader.setDelegate(loader, queue: loader.queue) }
    request.bind(asset)
    let ready = DispatchSemaphore(value: 0)
    let keys = ["tracks", "readable", "hasProtectedContent"]
    asset.loadValuesAsynchronously(forKeys: keys) { ready.signal() }
    guard ready.wait(timeout: .now() + 20) == .success else { asset.cancelLoading(); throw SubtitleAnalysisFailure.unavailable }
    try request.check()
    for key in keys { var error: NSError?; guard asset.statusOfValue(forKey: key, error: &error) == .loaded else { throw SubtitleAnalysisFailure.unavailable } }
    guard asset.isReadable, !asset.hasProtectedContent else { throw SubtitleAnalysisFailure.unavailable }
    let tracks = asset.tracks(withMediaType: .audio)
    guard ordinal < tracks.count else { throw SubtitleAnalysisFailure.unavailable }
    let reader = try AVAssetReader(asset: asset); request.bind(reader)
    defer { reader.cancelReading() }
    reader.timeRange = CMTimeRange(start: CMTime(value: Int64(start), timescale: 1000),
      duration: CMTime(value: Int64(end-start), timescale: 1000))
    let output = AVAssetReaderTrackOutput(track: tracks[ordinal], outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw SubtitleAnalysisFailure.unavailable }
    reader.add(output)
    guard reader.startReading() else { throw SubtitleAnalysisFailure.unavailable }
    let count = (end-start)*16
    var bytes = [UInt8](repeating: 0, count: count*2), present = [Bool](repeating: false, count: count)
    while reader.status == .reading {
      try request.check()
      guard let sample = output.copyNextSampleBuffer() else { break }
      guard let format = CMSampleBufferGetFormatDescription(sample),
        let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format),
        audio.pointee.mSampleRate == 16000, audio.pointee.mChannelsPerFrame == 1,
        audio.pointee.mBytesPerFrame == 2, audio.pointee.mFormatID == kAudioFormatLinearPCM,
        audio.pointee.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian) == 0,
        let block = CMSampleBufferGetDataBuffer(sample) else { throw SubtitleAnalysisFailure.unavailable }
      let length = CMBlockBufferGetDataLength(block)
      guard length > 0, length <= 4*1024*1024, length % 2 == 0 else { throw SubtitleAnalysisFailure.unavailable }
      var data = [UInt8](repeating: 0, count: length)
      let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
      guard copied == kCMBlockBufferNoErr else { throw SubtitleAnalysisFailure.unavailable }
      let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
      guard seconds.isFinite, abs(seconds) < 86400 else { throw SubtitleAnalysisFailure.unavailable }
      let first = Int(((seconds - Double(start)/1000)*16000).rounded())
      for frame in 0..<(length/2) {
        let index = first+frame
        if index >= 0 && index < count { bytes[index*2] = data[frame*2]; bytes[index*2+1] = data[frame*2+1]; present[index] = true }
      }
    }
    try request.check()
    guard reader.status == .completed else { throw SubtitleAnalysisFailure.unavailable }
    var gap = 0, longest = 0
    for found in present { gap = found ? 0 : gap+1; longest = max(longest, gap) }
    guard present.contains(true), longest <= 4000 else { throw SubtitleAnalysisFailure.unavailable }
    return Data(bytes)
  }
}
