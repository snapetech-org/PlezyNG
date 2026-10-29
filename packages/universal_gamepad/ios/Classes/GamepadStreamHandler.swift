import Flutter

/// FlutterStreamHandler that forwards native gamepad events to Dart.
///
/// Events are queued if no sink is attached yet; once a listener subscribes
/// all queued events are flushed immediately.
public class GamepadStreamHandler: NSObject, FlutterStreamHandler {

    /// The active event sink provided by Flutter's EventChannel.
    private var eventSink: FlutterEventSink?

    /// Events received before the Dart side starts listening.
    private var pendingEvents: [[Any]] = []

    /// Thread-safety lock for sink / queue access.
    private let lock = NSLock()

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?,
                         eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        lock.lock()
        eventSink = events

        // Flush any events that arrived before the listener was attached.
        for event in pendingEvents {
            events(event)
        }
        pendingEvents.removeAll()
        lock.unlock()

        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        lock.lock()
        eventSink = nil
        lock.unlock()

        return nil
    }

    // MARK: - Internal API

    /// Sends a gamepad event array to Dart.
    ///
    /// If the sink is not yet available the event is queued. Events are
    /// delivered on the main thread; when already on it (the usual case,
    /// since GameController handlers default to the main queue) the event is
    /// sent synchronously to avoid an extra runloop hop.
    func send(event: [Any]) {
        lock.lock()
        if eventSink == nil {
            pendingEvents.append(event)
            lock.unlock()
            return
        }
        lock.unlock()

        if Thread.isMainThread {
            deliver(event)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.deliver(event)
            }
        }
    }

    /// Re-reads the sink at delivery time so events never hit a sink that
    /// was cancelled between enqueue and dispatch.
    private func deliver(_ event: [Any]) {
        lock.lock()
        let sink = eventSink
        lock.unlock()
        sink?(event)
    }
}
