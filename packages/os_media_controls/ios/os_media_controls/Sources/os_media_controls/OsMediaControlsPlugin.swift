import Flutter
import UIKit
import MediaPlayer
import AVFoundation

/// Serializes AVAudioSession activation off the main thread.
///
/// `setActive` is synchronous and can block on the audio server and route
/// negotiation; Xcode's runtime checker reports it as a UI-hang risk when it
/// runs on the main thread. A private serial queue keeps activate/deactivate
/// transitions in submission order without stalling Flutter's UI thread.
final class AudioSessionActivationQueue {
    typealias Activation = (Bool, AVAudioSession.SetActiveOptions) throws -> Void

    private let queue = DispatchQueue(label: "com.edde746.os_media_controls.audio-session")
    private let activation: Activation

    init(
        activation: @escaping Activation = { active, options in
            try AVAudioSession.sharedInstance().setActive(active, options: options)
        }
    ) {
        self.activation = activation
    }

    /// `completion` runs on the private queue with `nil` on success.
    func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions = [],
        completion: @escaping (Error?) -> Void
    ) {
        queue.async {
            do {
                try self.activation(active, options)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }
}

public class OsMediaControlsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, UIGestureRecognizerDelegate {
    private var eventSink: FlutterEventSink?
    private let nowPlayingCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let audioSessionQueue = AudioSessionActivationQueue()

    private var currentMetadata: [String: Any] = [:]
    private var handlersCleared = false

    // The artwork URL of the most recent setMetadata call. Downloads are
    // async; a slow response for track A must not overwrite track B's
    // now-playing info (last-writer-wins race on fast track changes).
    private var latestArtworkUrl: String?

    #if os(tvOS)
    private weak var tvPlayPauseGestureRecognizer: UITapGestureRecognizer?
    private var lastTvPlayPauseEventTime: TimeInterval = 0
    private let tvPlayPauseDuplicateWindow: TimeInterval = 0.2
    #endif


    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.edde746.os_media_controls/methods",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "com.edde746.os_media_controls/events",
            binaryMessenger: registrar.messenger()
        )

        let instance = OsMediaControlsPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)

        #if os(tvOS)
        let viewController = registrar.viewController
        DispatchQueue.main.async { [weak instance, weak viewController] in
            instance?.setupTvPlayPauseGestureRecognizer(on: viewController?.view)
        }
        #endif
    }

    public override init() {
        super.init()

        // Ensure app receives remote control events for Now Playing controls
        DispatchQueue.main.async {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }

        setupRemoteCommandCenter()
        setupAudioSessionObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        #if os(tvOS)
        if let recognizer = tvPlayPauseGestureRecognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        #endif
    }

    private func setupAudioSessionObservers() {
        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    private func setupRemoteCommandCenter() {
        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] event in
            self?.sendPlaybackCommand(defaultType: "play")
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] event in
            self?.sendPlaybackCommand(defaultType: "pause")
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] event in
            self?.sendPlaybackCommand(defaultType: "togglePlayPause")
            return .success
        }

        // Next track command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            self?.sendEvent(["type": "next"])
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            self?.sendEvent(["type": "previous"])
            return .success
        }

        // Change playback position command (seek)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                self?.sendEvent([
                    "type": "seek",
                    "position": positionEvent.positionTime
                ])
            }
            return .success
        }

        // Skip forward command
        commandCenter.skipForwardCommand.isEnabled = false // Disabled by default
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                self?.sendEvent([
                    "type": "skipForward",
                    "interval": skipEvent.interval
                ])
            } else {
                self?.sendEvent(["type": "skipForward"])
            }
            return .success
        }

        // Skip backward command
        commandCenter.skipBackwardCommand.isEnabled = false // Disabled by default
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                self?.sendEvent([
                    "type": "skipBackward",
                    "interval": skipEvent.interval
                ])
            } else {
                self?.sendEvent(["type": "skipBackward"])
            }
            return .success
        }

        // Change playback rate command
        commandCenter.changePlaybackRateCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1.0, 1.5, 2.0]
        commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
            if let rateEvent = event as? MPChangePlaybackRateCommandEvent {
                self?.sendEvent([
                    "type": "setSpeed",
                    "speed": rateEvent.playbackRate
                ])
            }
            return .success
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setMetadata":
            setMetadata(arguments: call.arguments as? [String: Any])
            result(nil)

        case "setPlaybackState":
            setPlaybackState(arguments: call.arguments as? [String: Any])
            result(nil)

        case "enableControls":
            enableControls(arguments: call.arguments as? [String])
            result(nil)

        case "disableControls":
            disableControls(arguments: call.arguments as? [String])
            result(nil)

        case "setSkipIntervals":
            setSkipIntervals(arguments: call.arguments as? [String: Any])
            result(nil)

        case "setQueueInfo":
            setQueueInfo(arguments: call.arguments as? [String: Any])
            result(nil)

        case "clear":
            clear()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func setMetadata(arguments: [String: Any]?) {
        ensureHandlersRegistered()

        guard let args = arguments else { return }

        // Store metadata for later use
        for (key, value) in args {
            if key != "artwork" {
                currentMetadata[key] = value
            }
        }

        var nowPlayingInfo = nowPlayingCenter.nowPlayingInfo ?? [:]

        if let title = args["title"] as? String {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }
        if let artist = args["artist"] as? String {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        }
        if let album = args["album"] as? String {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }
        if let albumArtist = args["albumArtist"] as? String {
            nowPlayingInfo[MPMediaItemPropertyAlbumArtist] = albumArtist
        }
        if let duration = args["duration"] as? Double {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
        // Handle artwork from bytes (takes precedence over URL)
        if let artworkData = args["artwork"] as? FlutterStandardTypedData {
            latestArtworkUrl = nil
            if let image = UIImage(data: artworkData.data) {
                nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        } else if let artworkUrlString = args["artworkUrl"] as? String, let artworkUrl = URL(string: artworkUrlString) {
            // Clear the previous track's artwork right away (the download may
            // be slow or fail); it is re-set below if this track's fetch wins.
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
            latestArtworkUrl = artworkUrlString
            // Handle artwork from URL - download asynchronously
            URLSession.shared.dataTask(with: artworkUrl) { [weak self] data, response, error in
                guard let self = self else { return }
                guard error == nil, let data = data, let image = UIImage(data: data) else {
                    return
                }

                DispatchQueue.main.async {
                    // Drop the result if another track's metadata replaced
                    // this request while the download was in flight.
                    guard self.latestArtworkUrl == artworkUrlString else { return }
                    var updatedInfo = self.nowPlayingCenter.nowPlayingInfo ?? [:]
                    updatedInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    self.nowPlayingCenter.nowPlayingInfo = updatedInfo
                }
            }.resume()
        } else {
            // No artwork for this track — don't keep the previous track's.
            latestArtworkUrl = nil
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        nowPlayingCenter.nowPlayingInfo = nowPlayingInfo
    }

    private func setPlaybackState(arguments: [String: Any]?) {
        ensureHandlersRegistered()

        guard let args = arguments,
              let stateString = args["state"] as? String,
              let position = args["position"] as? Double,
              let speed = args["speed"] as? Double else { return }

        // Only claim the audio session when actually playing. The session is
        // non-mixing, so activating it interrupts other apps' audio; doing it
        // on paused pushes made an interrupted-while-paused app fight the
        // interrupter in a play/pause loop (plezy#1496).
        if stateString == "playing" {
            setAudioSessionActive(true)
        }

        var nowPlayingInfo = nowPlayingCenter.nowPlayingInfo ?? [:]

        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] =
            stateString == "playing" ? speed : 0.0

        nowPlayingCenter.nowPlayingInfo = nowPlayingInfo

        setNativePlaybackState(stateString)
    }

    private func enableControls(arguments: [String]?) {
        ensureHandlersRegistered()

        guard let controls = arguments else { return }

        for control in controls {
            switch control {
            case "play":
                commandCenter.playCommand.isEnabled = true
            case "pause":
                commandCenter.pauseCommand.isEnabled = true
            case "stop":
                // iOS doesn't have a dedicated stop command
                break
            case "next":
                commandCenter.nextTrackCommand.isEnabled = true
            case "previous":
                commandCenter.previousTrackCommand.isEnabled = true
            case "seek":
                commandCenter.changePlaybackPositionCommand.isEnabled = true
            case "skipForward":
                commandCenter.skipForwardCommand.isEnabled = true
            case "skipBackward":
                commandCenter.skipBackwardCommand.isEnabled = true
            case "changeSpeed":
                commandCenter.changePlaybackRateCommand.isEnabled = true
            default:
                break
            }
        }
    }

    private func disableControls(arguments: [String]?) {
        guard let controls = arguments else { return }

        for control in controls {
            switch control {
            case "play":
                commandCenter.playCommand.isEnabled = false
            case "pause":
                commandCenter.pauseCommand.isEnabled = false
            case "next":
                commandCenter.nextTrackCommand.isEnabled = false
            case "previous":
                commandCenter.previousTrackCommand.isEnabled = false
            case "seek":
                commandCenter.changePlaybackPositionCommand.isEnabled = false
            case "skipForward":
                commandCenter.skipForwardCommand.isEnabled = false
            case "skipBackward":
                commandCenter.skipBackwardCommand.isEnabled = false
            case "changeSpeed":
                commandCenter.changePlaybackRateCommand.isEnabled = false
            default:
                break
            }
        }
    }

    private func setSkipIntervals(arguments: [String: Any]?) {
        ensureHandlersRegistered()

        guard let args = arguments else { return }

        if let forward = args["forward"] as? Int {
            commandCenter.skipForwardCommand.isEnabled = true
            commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)]
        }

        if let backward = args["backward"] as? Int {
            commandCenter.skipBackwardCommand.isEnabled = true
            commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: backward)]
        }
    }

    private func setQueueInfo(arguments: [String: Any]?) {
        ensureHandlersRegistered()

        guard let args = arguments,
              let currentIndex = args["currentIndex"] as? Int,
              let queueLength = args["queueLength"] as? Int else { return }

        var nowPlayingInfo = nowPlayingCenter.nowPlayingInfo ?? [:]

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueLength

        nowPlayingCenter.nowPlayingInfo = nowPlayingInfo
    }

    private func clear() {
        setNativePlaybackState("stopped")

        nowPlayingCenter.nowPlayingInfo = nil
        currentMetadata.removeAll()
        latestArtworkUrl = nil

        // Deactivate audio session to force iOS to remove controls from Control Center
        setAudioSessionActive(false, options: .notifyOthersOnDeactivation)

        // Disable all command center buttons
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackRateCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false

        handlersCleared = true
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue.uintValue) else {
            return
        }

        switch type {
        case .began:
            sendEvent(["type": "audioInterruptionBegan"])
        case .ended:
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue?.uintValue ?? 0)
            let shouldResume = options.contains(.shouldResume)
            let event: [String: Any] = ["type": "audioInterruptionEnded", "shouldResume": shouldResume]
            if shouldResume {
                // Reclaim the session before the app resumes playback so the
                // resume lands on an active session, as it did when this was
                // synchronous.
                setAudioSessionActive(true) { [weak self] in
                    self?.sendEvent(event)
                }
            } else {
                sendEvent(event)
            }
        @unknown default:
            break
        }
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? NSNumber,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue.uintValue) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            guard let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription,
                  routeHasPrivateAudioOutput(previousRoute) else {
                return
            }
            sendEvent(["type": "audioRouteOldDeviceUnavailable"])
        case .newDeviceAvailable:
            guard routeHasPrivateAudioOutput(AVAudioSession.sharedInstance().currentRoute) else {
                return
            }
            sendEvent(["type": "audioRouteNewDeviceAvailable"])
        default:
            break
        }
    }

    private func routeHasPrivateAudioOutput(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                return true
            default:
                return false
            }
        }
    }

    /// `completion` runs on the audio-session queue after the transition,
    /// whether or not it succeeded; failures are logged and not retried.
    private func setAudioSessionActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions = [],
        completion: (() -> Void)? = nil
    ) {
        audioSessionQueue.setActive(active, options: options) { error in
            if let error = error {
                print("Failed to \(active ? "activate" : "deactivate") audio session: \(error)")
            }
            completion?()
        }
    }

    private func ensureHandlersRegistered() {
        guard handlersCleared else { return }
        setupRemoteCommandCenter()
        handlersCleared = false
    }

    private func sendPlaybackCommand(defaultType: String) {
        let eventType = playbackCommandEventType(defaultType)
        #if os(tvOS)
        if eventType == "togglePlayPause" && shouldSuppressDuplicateTvPlayPauseEvent() {
            return
        }
        #endif
        sendEvent(["type": eventType])
    }

    private func playbackCommandEventType(_ defaultType: String) -> String {
        #if os(tvOS)
        // The Siri Remote has one Play/Pause button, but tvOS may surface it
        // through playCommand or pauseCommand depending on system state. Emit a
        // toggle so the app can decide from its authoritative player state.
        return "togglePlayPause"
        #else
        return defaultType
        #endif
    }

    #if os(tvOS)
    private func setupTvPlayPauseGestureRecognizer(on view: UIView?) {
        guard tvPlayPauseGestureRecognizer == nil, let view = view else { return }

        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTvPlayPauseGesture(_:)))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
        tvPlayPauseGestureRecognizer = recognizer
    }

    @objc private func handleTvPlayPauseGesture(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .recognized else { return }
        sendPlaybackCommand(defaultType: "togglePlayPause")
    }

    private func shouldSuppressDuplicateTvPlayPauseEvent() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTvPlayPauseEventTime < tvPlayPauseDuplicateWindow {
            return true
        }
        lastTvPlayPauseEventTime = now
        return false
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
    #endif

    private func setNativePlaybackState(_ stateString: String) {
        #if os(iOS) || os(tvOS)
        if #available(iOS 13.0, tvOS 13.0, *) {
            switch stateString {
            case "playing":
                nowPlayingCenter.playbackState = .playing
            case "paused":
                nowPlayingCenter.playbackState = .paused
            case "stopped":
                nowPlayingCenter.playbackState = .stopped
            default:
                nowPlayingCenter.playbackState = .unknown
            }
        }
        #endif
    }

    private func sendEvent(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?,
                        eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
