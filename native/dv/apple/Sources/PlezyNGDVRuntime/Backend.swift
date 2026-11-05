import AetherEngine
import Combine
import Foundation
import PlezyNGDVRuntimeAPI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@_cdecl("PlezyNGDVRuntimeVersion")
public func runtimeVersion() -> Int32 { 1 }

@_cdecl("PlezyNGCreateDVBackend")
public func createBackend() -> UnsafeMutableRawPointer {
  Unmanaged.passRetained(AppleDVBackend()).toOpaque()
}

/// The app's ordinary transport controls and source ownership drive this
/// backend. Engine availability never stands in for FEL pixel qualification.
private final class AppleDVBackend: DVRuntimeBackend {
  private var engine: AetherEngine?
  private var surface: AetherPlayerView?
  private var timer: Timer?
  private var loadTask: Task<Void, Never>?
  private var subscriptions = Set<AnyCancellable>()
  private var observed = Set<String>()
  private var options: [String: String] = [:]
  private var headerItems: [String] = []
  private var scopedURL: URL?
  private var sourceID: Int64 = 0
  private var closed = false
  private var loaded = false
  private var restarted = false
  private var ended = false

  override func prepare() -> Bool {
    MainActor.assumeIsolated {
      guard AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn else { return false }
      do {
        let engine = try AetherEngine()
        let surface = AetherPlayerView()
        engine.bind(view: surface)
        self.engine = engine
        self.surface = surface
        engine.$state.receive(on: RunLoop.main).sink { [weak self] state in
          MainActor.assumeIsolated { self?.stateChanged(state) }
        }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.publish() }
        }
        return true
      } catch {
        return false
      }
    }
  }

  override func attach(to parent: NSObject) {
    MainActor.assumeIsolated {
      guard let surface else { return }
      #if os(macOS)
        guard let parent = parent as? NSView else { return }
        parent.addSubview(surface, positioned: .below, relativeTo: nil)
      #else
        guard let parent = parent as? UIView else { return }
        surface.isUserInteractionEnabled = false
        parent.addSubview(surface)
      #endif
      surface.frame = parent.bounds
    }
  }

  override func setFrame(_ frame: CGRect) {
    MainActor.assumeIsolated { surface?.frame = frame }
  }

  override func setVisible(_ visible: Bool) {
    MainActor.assumeIsolated { surface?.isHidden = !visible }
  }

  override func setProperty(_ name: String, value: String) {
    MainActor.assumeIsolated {
      guard !closed else { return }
      options[name] = value
      guard let engine else { return }
      switch name {
      case "pause":
        if value == "yes" { engine.pause() } else { engine.play() }
      case "volume", "mute":
        let volume = Float(options["volume"] ?? "100") ?? 100
        engine.volume = options["mute"] == "yes" ? 0 : min(max(volume / 100, 0), 1)
      case "speed":
        if let rate = Float(value), rate.isFinite, rate > 0 { engine.setRate(rate) }
      case "aid":
        if let id = Int(value) { engine.selectAudioTrack(index: id - 1) }
      case "sid":
        if value == "no" {
          engine.clearSubtitle()
        } else if let id = Int(value) {
          engine.selectSubtitleTrack(index: id - 1)
        }
      case "secondary-sid":
        if value == "no" {
          engine.clearSecondarySubtitle()
        } else if let id = Int(value) {
          engine.selectSecondarySubtitleTrack(index: id - 1)
        }
      default:
        break
      }
    }
  }

  override func property(_ name: String) -> String? {
    MainActor.assumeIsolated {
      guard let value = value(name) else { return nil }
      if let string = value as? String { return string }
      if let boolean = value as? Bool { return boolean ? "yes" : "no" }
      if JSONSerialization.isValidJSONObject(value),
        let data = try? JSONSerialization.data(withJSONObject: value)
      {
        return String(data: data, encoding: .utf8)
      }
      return String(describing: value)
    }
  }

  override func observe(_ name: String) {
    MainActor.assumeIsolated { observed.insert(name) }
  }

  override func command(_ arguments: [String], completion: @escaping (Int64?, NSError?) -> Void) {
    MainActor.assumeIsolated {
      guard !closed, let engine, let command = arguments.first else {
        completion(nil, NSError(domain: "PlezyNGDVRuntime", code: 1))
        return
      }
      switch command {
      case "loadfile":
        guard arguments.count > 1,
          let url = arguments[1].hasPrefix("/") ? URL(fileURLWithPath: arguments[1]) : URL(string: arguments[1])
        else {
          completion(nil, NSError(domain: "PlezyNGDVRuntime", code: 2))
          return
        }
        let fileOptions: [String: String]
        let headers: [String: String]
        do {
          fileOptions = try arguments.count > 4 ? MPVOptions.parse(arguments[4]) : [:]
          if fileOptions["http-header-fields-clr"] != nil {
            headers = [:]
          } else if let encoded = fileOptions["http-header-fields"] {
            headers = try MPVOptions.headers(encoded)
          } else {
            headers = try MPVOptions.headers(fromItems: headerItems)
          }
        } catch {
          completion(nil, NSError(domain: "PlezyNGDVRuntime", code: 2))
          return
        }
        loadTask?.cancel()
        engine.stop()
        releaseScopedURL()
        if url.isFileURL && url.startAccessingSecurityScopedResource() { scopedURL = url }
        sourceID += 1
        let owner = sourceID
        loaded = false
        restarted = false
        ended = false
        onEvent?("start-file", nil, owner)
        completion(owner, nil)
        var loadOptions = LoadOptions()
        loadOptions.httpHeaders = headers
        loadOptions.autoplay = options["pause"] != "yes"
        let conversion = options["dv-conversion-mode"] ?? "auto"
        loadOptions.preferDualLayerDolbyVision = conversion == "auto"
        if conversion == "hevc_strip" || conversion == "disabled" {
          loadOptions.dolbyVisionHandling = .baseLayerOnly
        }
        let start = Double(fileOptions["start"] ?? options["start"] ?? "0") ?? 0
        loadTask = Task { @MainActor [weak self, weak engine] in
          do {
            guard let engine else { return }
            try await engine.load(url: url, startPosition: max(0, start), options: loadOptions)
            guard let self, !Task.isCancelled, !self.closed, self.sourceID == owner else { return }
            self.loaded = true
            self.onEvent?("file-loaded", nil, owner)
            if self.options["pause"] == "yes" { engine.pause() } else { engine.play() }
            self.publish()
            self.stateChanged(engine.state)
          } catch is CancellationError {
          } catch {
            guard let self, !self.closed, self.sourceID == owner else { return }
            self.finish(reason: 4, error: -1)
          }
        }
      case "seek":
        guard arguments.count > 1, let position = Double(arguments[1]), position.isFinite else {
          completion(nil, NSError(domain: "PlezyNGDVRuntime", code: 2))
          return
        }
        let absolute = arguments.count > 2 && arguments[2].contains("absolute")
        let target = max(0, absolute ? position : engine.currentTime + position)
        let owner = sourceID
        Task { @MainActor [weak self, weak engine] in
          await engine?.seek(to: target)
          guard let self, !self.closed, self.sourceID == owner else { return }
          self.publish()
        }
        completion(nil, nil)
      case "stop":
        loadTask?.cancel()
        sourceID += 1
        loaded = false
        engine.stop()
        releaseScopedURL()
        completion(nil, nil)
      case "change-list":
        if arguments.count >= 3 && arguments[1] == "http-header-fields" {
          if arguments[2] == "clr" {
            headerItems.removeAll()
          } else if arguments[2] == "append" && arguments.count > 3 {
            headerItems.append(arguments[3])
          }
        }
        completion(nil, nil)
      default:
        completion(nil, nil)
      }
    }
  }

  override func close() {
    MainActor.assumeIsolated {
      guard !closed else { return }
      closed = true
      sourceID += 1
      loadTask?.cancel()
      timer?.invalidate()
      timer = nil
      subscriptions.removeAll()
      engine?.stop()
      releaseScopedURL()
      surface?.removeFromSuperview()
      surface = nil
      engine = nil
      onEvent = nil
      onProperty = nil
    }
  }

  @MainActor private func releaseScopedURL() {
    scopedURL?.stopAccessingSecurityScopedResource()
    scopedURL = nil
  }

  @MainActor private func stateChanged(_ state: PlaybackState) {
    guard !closed else { return }
    if loaded && state == .playing && !restarted {
      restarted = true
      onEvent?("playback-restart", nil, sourceID)
      onEvent?(
        "log-message",
        [
          "prefix": "dv-route", "level": "info",
          "text": "Apple runtime experiment active; FEL pixels and display output unqualified",
        ], sourceID)
    }
    if loaded {
      switch state {
      case .ended: finish(reason: 0)
      case .error: finish(reason: 4, error: -1)
      default: break
      }
    }
    publish()
  }

  @MainActor private func finish(reason: Int, error: Int? = nil) {
    guard !ended else { return }
    ended = true
    releaseScopedURL()
    var data: [String: Any] = ["reason": reason]
    if let error { data["error"] = error }
    onEvent?("end-file", data, sourceID)
  }

  @MainActor private func publish() {
    guard !closed else { return }
    for name in observed { onProperty?(name, value(name), sourceID == 0 ? nil : sourceID) }
  }

  @MainActor private func value(_ name: String) -> Any? {
    guard let engine else { return nil }
    switch name {
    case "time-pos": return engine.currentTime
    case "duration": return engine.duration
    case "pause": return engine.state != .playing
    case "paused-for-cache", "demuxer-cache-idle": return engine.isBuffering
    case "seeking": return engine.isSeeking
    case "seekable": return engine.canSeek
    case "idle-active": return engine.state == .idle
    case "eof-reached": return engine.state == .ended
    case "width": return Int(engine.sourceVideoWidth)
    case "height": return Int(engine.sourceVideoHeight)
    case "container-fps", "estimated-vf-fps": return engine.sourceVideoFrameRate
    case "video-codec": return engine.sourceVideoCodecName
    case "current-vo": return "aether"
    case "hwdec-current": return engine.activeVideoDecoder
    case "plezyng-dv-engine": return "plezyng-apple-dv-runtime-v1"
    case "current-tracks/video/dolby-vision-profile": return engine.sourceDVProfile
    case "track-list":
      return engine.audioTracks.map { track in
        [
          "id": track.id + 1, "type": "audio", "codec": track.codec,
          "lang": track.language ?? "", "title": track.name,
          "selected": engine.activeAudioTrackIndex == track.id,
        ] as [String: Any]
      }
        + engine.subtitleTracks.map { track in
          [
            "id": track.id + 1, "type": "sub", "codec": track.codec,
            "lang": track.language ?? "", "title": track.name,
            "selected": engine.activeSubtitleTrackIndex == track.id,
          ] as [String: Any]
        }
    default: return options[name]
    }
  }
}
