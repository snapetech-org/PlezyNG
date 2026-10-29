package dev.universal_gamepad

import android.app.Activity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.Window
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android platform implementation of the gamepad Flutter plugin.
 *
 * Registers a [MethodChannel] (`dev.universal_gamepad/methods`) and an
 * [EventChannel] (`dev.universal_gamepad/events`) with the Flutter engine.
 *
 * Wraps the Activity's [Window.Callback] to intercept gamepad key events
 * before Flutter processes them as UI navigation, and attaches a
 * [View.OnGenericMotionListener] on the decor view for axis/trigger input.
 */
class GamepadPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    private var streamHandler: GamepadStreamHandler? = null
    private var inputManager: GamepadInputManager? = null
    private val effects = GamepadEffects()

    private var flutterPluginBinding: FlutterPlugin.FlutterPluginBinding? = null
    private var activityBinding: ActivityPluginBinding? = null

    /** The view we've attached our motion listener to. */
    private var attachedView: View? = null

    /** The original Window.Callback we replaced, for restoration on detach. */
    private var originalWindowCallback: Window.Callback? = null
    private var attachedWindow: Window? = null
    private var inputPaused = false

    // -- FlutterPlugin ---------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        flutterPluginBinding = binding

        val handler = GamepadStreamHandler()
        streamHandler = handler

        methodChannel = MethodChannel(binding.binaryMessenger, "dev.universal_gamepad/methods").also {
            it.setMethodCallHandler(this)
        }

        eventChannel = EventChannel(binding.binaryMessenger, "dev.universal_gamepad/events").also {
            it.setStreamHandler(handler)
        }

        val manager = GamepadInputManager(binding.applicationContext, handler, effects::remove)
        inputManager = manager
        manager.start()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        tearDown()
        flutterPluginBinding = null
    }

    // -- MethodChannel.MethodCallHandler ---------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method.startsWith("plezy")) {
            try {
                val token = call.argument<String>("owner") ?: ""
                val id = call.argument<Int>("deviceId") ?: -1
                when (call.method) {
                    "plezyClaimEffects" -> result.success(effects.claim(token))
                    "plezyReleaseEffects" -> { effects.release(token); result.success(null) }
                    "plezyControllerState" -> result.success(effects.state(token, id)?.toList())
                    "plezyControllerEffects" -> result.success(effects.apply(token, id,
                        call.argument<Int>("flags") ?: 0,
                        call.argument<Int>("low") ?: 0, call.argument<Int>("high") ?: 0,
                        call.argument<Int>("duration") ?: 0,
                        call.argument<Int>("leftTrigger") ?: 0, call.argument<Int>("rightTrigger") ?: 0,
                        call.argument<Int>("triggerDuration") ?: 0, call.argument<Boolean>("sensors") == true))
                    else -> result.notImplemented()
                }
            } catch (_: RuntimeException) { result.success(false) }
            return
        }
        when (call.method) {
            "listGamepads" -> {
                result.success(inputManager?.listGamepads() ?: emptyList<HashMap<String, Any>>())
            }
            "dispose" -> {
                effects.stop()
                inputManager?.stop()
                detachInputListeners()
                result.success(null)
            }
            "pause" -> {
                effects.stop()
                inputPaused = true
                detachInputListeners()
                result.success(null)
            }
            "resume" -> {
                inputPaused = false
                activityBinding?.activity?.let { attachInputListeners(it) }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // -- ActivityAware ---------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        if (!inputPaused) {
            attachInputListeners(binding.activity)
        }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachInputListeners()
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        if (!inputPaused) {
            attachInputListeners(binding.activity)
        }
    }

    override fun onDetachedFromActivity() {
        detachInputListeners()
        activityBinding = null
    }

    // -- Input listener management ---------------------------------------------

    /**
     * Attaches input listeners to the Activity:
     * - Wraps [Window.Callback] to intercept gamepad key events (buttons, stick
     *   clicks) before Flutter's view processes them as UI navigation.
     * - Sets [View.OnGenericMotionListener] on the decor view for axis/trigger
     *   motion events.
     */
    private fun attachInputListeners(activity: Activity) {
        val window = activity.window ?: return
        val view = window.decorView
        if (attachedWindow == window && attachedView == view && window.callback is GamepadWindowCallback) {
            return
        }
        detachInputListeners()

        attachedView = view
        attachedWindow = window

        // Motion events (sticks, triggers, hat/dpad) - listener on decor view is fine.
        view.setOnGenericMotionListener { _, event ->
            inputManager?.onGenericMotionEvent(event) ?: false
        }

        // Key events - wrap Window.Callback to intercept before Flutter's view
        // consumes them as navigation actions (BUTTON_A -> Enter, etc.).
        val original = window.callback
        originalWindowCallback = original
        window.callback = GamepadWindowCallback(original, inputManager)
    }

    /**
     * Removes input listeners and restores the original Window.Callback.
     */
    private fun detachInputListeners() {
        effects.stop()
        attachedView?.setOnGenericMotionListener(null)
        attachedView = null

        // Restore original Window.Callback only if ours is still installed.
        val window = attachedWindow
        val original = originalWindowCallback
        if (window != null && original != null && window.callback is GamepadWindowCallback) {
            window.callback = original
        }
        originalWindowCallback = null
        attachedWindow = null
    }

    /**
     * Full tear-down: stops the input manager, removes listeners, clears channels.
     */
    private fun tearDown() {
        inputManager?.stop()
        inputManager = null
        inputPaused = false

        detachInputListeners()

        methodChannel?.setMethodCallHandler(null)
        methodChannel = null

        eventChannel?.setStreamHandler(null)
        eventChannel = null

        streamHandler = null
    }
}

/**
 * Wraps the Activity's [Window.Callback] to intercept gamepad key events
 * before they reach Flutter's view hierarchy.
 *
 * Without this, gamepad face buttons (A/B/X/Y) and stick clicks are processed
 * by Flutter as navigation keys (Enter, etc.) and never reach the plugin's
 * event stream.
 */
private class GamepadWindowCallback(
    private val original: Window.Callback,
    private val inputManager: GamepadInputManager?,
) : Window.Callback by original {

    // Guards against the FlutterView redispatch loop: when Flutter doesn't
    // handle a key event, KeyboardManager.redispatch() re-sends the same
    // KeyEvent object through DecorView → this callback. We track forwarded
    // events by identity so the second pass returns false, letting DecorView
    // fall through to Activity.onKeyDown/onKeyUp (which handles BACK etc.).
    private var lastForwardedEvent: KeyEvent? = null

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isGamepadKeyEvent(event)) {
            if (inputManager?.onKeyEvent(event) == true) return true
            // Unmapped key from gamepad-source device (e.g. KEYCODE_BACK from
            // a virtual remote). On redispatch, return false so DecorView falls
            // through to Activity.onKeyDown → onBackPressed.
            if (event === lastForwardedEvent) {
                lastForwardedEvent = null
                return false
            }
            lastForwardedEvent = event
            return original.dispatchKeyEvent(event)
        }
        return original.dispatchKeyEvent(event)
    }

    private fun isGamepadKeyEvent(event: KeyEvent): Boolean {
        val source = event.source
        return (source and InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD ||
                (source and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK
    }
}
