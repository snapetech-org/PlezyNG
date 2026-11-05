package com.edde746.plezy

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Flutter adapter for the optional retained Steam view in the :steam module. */
internal class SteamStreamPlatformViewFactory(private val messenger: BinaryMessenger, private val activity: android.app.Activity) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  companion object {
    const val VIEW_TYPE = "com.plezy/games/steam_stream"
    private const val MICROPHONE_PERMISSION = 27039
  }

  private val sessions = mutableMapOf<String, Session>()
  private var microphonePermission: MethodChannel.Result? = null

  fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, results: IntArray): Boolean {
    if (requestCode != MICROPHONE_PERMISSION) return false
    val granted = permissions.size == 1 && permissions[0] == android.Manifest.permission.RECORD_AUDIO &&
      results.size == 1 && results[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
    microphonePermission?.success(granted)
    microphonePermission = null
    return true
  }

  private fun requestMicrophonePermission(result: MethodChannel.Result) {
    if (activity.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
      result.success(true)
    } else if (microphonePermission != null || activity.isFinishing || activity.isDestroyed) {
      result.success(false)
    } else {
      microphonePermission = result
      try {
        activity.requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), MICROPHONE_PERMISSION)
      } catch (_: RuntimeException) {
        microphonePermission = null
        result.success(false)
      }
    }
  }

  fun closeAll() {
    microphonePermission?.success(false)
    microphonePermission = null
    sessions.values.toList().forEach { it.close() }
    sessions.clear()
  }

  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val parameters = args as? Map<*, *> ?: throw IllegalArgumentException("Missing Steam stream arguments")
    val requestedKey = parameters["sessionKey"]
    val key = if (requestedKey == null) "legacy:$viewId" else {
      require(requestedKey is String && requestedKey.matches(Regex("^[0-9a-f]{32}-[0-9]{1,10}$")))
      requestedKey
    }
    val session = sessions[key] ?: run {
      check(sessions.size < 8) { "Too many Steam sessions" }
      val viewClass = Class.forName("org.snapetech.plezyng.games.steam.SteamStreamView")
      val target = viewClass.getConstructor(Context::class.java, Map::class.java).newInstance(context, parameters)
      Session(key, parameters.toMap(), target as View, target).also { sessions[key] = it }
    }
    check(!session.closed && session.parameters == parameters) { "Steam session identity changed" }
    val container = FrameLayout(context)
    (session.view.parent as? ViewGroup)?.removeView(session.view)
    container.addView(session.view, FrameLayout.LayoutParams(-1, -1))
    session.bind(viewId)
    return object : PlatformView {
      override fun getView(): View = container
      override fun dispose() {
        if (session.view.parent === container) {
          session.suspendInput()
          container.removeView(session.view)
        }
        // The owning Dart session disconnects explicitly. Older clients retain
        // their original view-owned teardown behavior.
        if (requestedKey == null) session.close()
      }
    }
  }

  private inner class Session(
    val key: String,
    val parameters: Map<*, *>,
    val view: View,
    private val target: Any
  ) : MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private val booleanType = Boolean::class.javaPrimitiveType!!
    var closed = false
      private set

    fun bind(viewId: Int) {
      channel?.setMethodCallHandler(null)
      channel = MethodChannel(messenger, "com.plezy/games/steam_stream/$viewId")
      channel?.setMethodCallHandler(this)
      invoke("setOnStateChanged", arrayOf(Runnable::class.java), Runnable {
        if (!closed) channel?.invokeMethod("sessionState", target.javaClass.getMethod("getSessionState").invoke(target))
      })
    }

    fun suspendInput() {
      runCatching { invoke("setInputEnabled", arrayOf(booleanType), false) }
    }

    fun close() {
      if (closed) return
      closed = true
      runCatching { invoke("setOnStateChanged", arrayOf(Runnable::class.java), Runnable {}) }
      runCatching { invoke("close") }
      Thread({
        if (runCatching { invoke("awaitTermination") }.isSuccess) {
          Handler(Looper.getMainLooper()).post {
            sessions.remove(key, this@Session)
            channel?.setMethodCallHandler(null)
          }
        }
      }, "PlezySteamRetire").apply { isDaemon = true }.start()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
      try {
        if (closed && call.method != "disconnect") {
          result.error("STREAM_RETIRED", "The game session has ended", null)
          return
        }
        when (call.method) {
          "requestMicrophonePermission" -> {
            requestMicrophonePermission(result)
            return
          }
          "setTouchControllerState" -> {
            invoke("setTouchControllerState", arrayOf(Map::class.java, Map::class.java), call.argument<Map<*, *>>("buttons") ?: emptyMap<Any, Any>(), call.argument<Map<*, *>>("axes") ?: emptyMap<Any, Any>())
            result.success(null)
            return
          }
          "releaseTouchControls" -> { invoke("releaseTouchControls"); result.success(null); return }
          "readControllerFeedback" -> {
            result.success(target.javaClass.getMethod("readControllerFeedback").invoke(target))
            return
          }
          "setControllerMotion" -> {
            val values = listOf("gx", "gy", "gz", "ax", "ay", "az").map { call.argument<Number>(it)?.toDouble() ?: Double.NaN }.toDoubleArray()
            result.success(target.javaClass.getMethod("setControllerMotion", Int::class.javaPrimitiveType, DoubleArray::class.java)
              .invoke(target, call.argument<Number>("deviceId")?.toInt() ?: -1, values) == true)
            return
          }
          "getMicrophoneState" -> {
            result.success(target.javaClass.getMethod("getMicrophoneState").invoke(target))
            return
          }
          "setMicrophoneEnabled" -> {
            result.success(target.javaClass.getMethod("setMicrophoneEnabled", booleanType)
              .invoke(target, call.argument<Boolean>("enabled") == true) == true)
            return
          }
          "disconnect" -> {
            close()
            Thread({
              val stopped = runCatching { invoke("awaitTermination") }.isSuccess
              Handler(Looper.getMainLooper()).post {
                if (stopped) {
                  sessions.remove(key, this@Session)
                  channel?.setMethodCallHandler(null)
                  result.success(null)
                } else {
                  result.error("STREAM_STOP_PENDING", "The previous stream is still stopping", null)
                }
              }
            }, "PlezySteamDisconnect").apply { isDaemon = true }.start()
            return
          }
          "getSessionState" -> {
            result.success(target.javaClass.getMethod("getSessionState").invoke(target))
            return
          }
          "getStreamMetrics" -> {
            result.success(target.javaClass.getMethod("getStreamMetrics").invoke(target))
            return
          }
          "setControllerMapping" -> {
            val mapping = call.argument<List<*>>("mapping") ?: throw IllegalArgumentException("Missing mapping")
            result.success(target.javaClass.getMethod("setControllerMapping", Int::class.javaPrimitiveType, List::class.java)
              .invoke(target, call.argument<Int>("seat") ?: 0, mapping))
            return
          }
          "setAudioEnabled" -> invoke("setAudioEnabled", arrayOf(booleanType), call.argument<Boolean>("enabled") == true)
          "setInputEnabled" -> invoke("setInputEnabled", arrayOf(booleanType), call.argument<Boolean>("enabled") == true)
          "setControllerState" -> invoke(
            "setControllerState",
            arrayOf(Map::class.java, Map::class.java),
            call.argument<Map<*, *>>("buttons") ?: emptyMap<Any, Any>(),
            call.argument<Map<*, *>>("axes") ?: emptyMap<Any, Any>()
          )
          "setControllerDeviceState" -> invoke(
            "setControllerDeviceState",
            arrayOf(Int::class.javaPrimitiveType!!, Map::class.java, Map::class.java),
            call.argument<Int>("deviceId") ?: throw IllegalArgumentException("Missing controller"),
            call.argument<Map<*, *>>("buttons") ?: emptyMap<Any, Any>(),
            call.argument<Map<*, *>>("axes") ?: emptyMap<Any, Any>()
          )
          "disconnectController" -> invoke(
            "disconnectController",
            arrayOf(Int::class.javaPrimitiveType!!),
            call.argument<Int>("deviceId") ?: throw IllegalArgumentException("Missing controller")
          )
          "inputText" -> {
            val text = call.argument<ByteArray>("text") ?: throw IllegalArgumentException("Missing text")
            if (text.size > 512) throw IllegalArgumentException("Text too long")
            result.success(target.javaClass.getMethod("inputText", ByteArray::class.java).invoke(target, text) == true)
            return
          }
          "inputKey" -> invoke(
            "inputKey",
            arrayOf(String::class.java, booleanType),
            call.argument<String>("key") ?: "",
            call.argument<Boolean>("down") == true
          )
          "resetInput" -> invoke("resetInput")
          else -> {
            result.notImplemented()
            return
          }
        }
        result.success(null)
      } catch (error: Exception) {
        result.error("STREAM_CONTROL_FAILED", "The game stream control could not be applied", null)
      }
    }

    private fun invoke(name: String, types: Array<Class<*>> = emptyArray(), vararg arguments: Any) {
      target.javaClass.getMethod(name, *types).invoke(target, *arguments)
    }

  }
}
