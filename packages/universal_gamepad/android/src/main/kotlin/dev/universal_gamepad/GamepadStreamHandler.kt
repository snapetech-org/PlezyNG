package dev.universal_gamepad

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * [EventChannel.StreamHandler] implementation that forwards native gamepad
 * events to the Dart side.
 *
 * Events received before a listener is attached are queued and flushed as soon
 * as [onListen] is called.
 */
class GamepadStreamHandler : EventChannel.StreamHandler {

    private var eventSink: EventChannel.EventSink? = null

    /** Events received before the Dart side starts listening. */
    private val pendingEvents = mutableListOf<Any>()

    private val mainHandler = Handler(Looper.getMainLooper())

    private val lock = Any()

    // -- EventChannel.StreamHandler --------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        synchronized(lock) {
            eventSink = events

            // Flush any events that arrived before the listener was attached.
            if (events != null) {
                for (event in pendingEvents) {
                    events.success(event)
                }
            }
            pendingEvents.clear()
        }
    }

    override fun onCancel(arguments: Any?) {
        synchronized(lock) {
            eventSink = null
        }
    }

    // -- Internal API ----------------------------------------------------------

    /**
     * Sends a gamepad event list to Dart.
     *
     * If the sink is not yet available the event is queued. Events are always
     * dispatched on the main (UI) thread to satisfy Flutter platform-channel
     * requirements.
     */
    fun send(event: Any) {
        synchronized(lock) {
            val sink = eventSink
            if (sink != null) {
                if (Looper.myLooper() == Looper.getMainLooper()) {
                    sink.success(event)
                } else {
                    mainHandler.post { sink.success(event) }
                }
            } else {
                pendingEvents.add(event)
            }
        }
    }
}
