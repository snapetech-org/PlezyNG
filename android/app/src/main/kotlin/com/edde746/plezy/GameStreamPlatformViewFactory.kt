package com.edde746.plezy

import android.app.Activity
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

/** Flutter adapter for a retained Moonlight receiver in the workspace. */
internal class GameStreamPlatformViewFactory(
  private val messenger: BinaryMessenger,
  private val activity: Activity
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  companion object {
    const val VIEW_TYPE = "com.plezy/games/moonlight_stream"
  }

  private val sessions = mutableMapOf<String, Session>()

  fun closeAll() {
    sessions.values.toList().forEach { it.close() }
  }

  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val parameters = args as? Map<*, *> ?: throw IllegalArgumentException("Missing GameStream arguments")
    val requestedKey = parameters["sessionKey"]
    require(requestedKey is String && requestedKey.matches(Regex("^[0-9a-f]{32}-[0-9]{1,10}$")))
    val key = requestedKey
    val session = sessions[key] ?: run {
      check(sessions.isEmpty()) { "Moonlight supports one active native session" }
      val viewClass = Class.forName("org.snapetech.plezyng.games.MoonlightStreamView")
      val target = viewClass.getConstructor(Context::class.java, Map::class.java).newInstance(activity, parameters)
      Session(key, parameters.toMap(), target as View, target).also { sessions[key] = it }
    }
    check(!session.closed && session.parameters == parameters) { "GameStream session identity changed" }
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
    var closed = false
      private set

    fun bind(viewId: Int) {
      channel?.setMethodCallHandler(null)
      channel = MethodChannel(messenger, "com.plezy/games/moonlight_stream/$viewId")
      channel?.setMethodCallHandler(this)
      invoke(
        "setOnStateChanged",
        arrayOf(Runnable::class.java),
        Runnable {
          if (!closed) {
            val state = target.javaClass.getMethod("getSessionState").invoke(target)
            channel?.invokeMethod("sessionState", state)
          }
        }
      )
    }

    fun suspendInput() {
      runCatching { invoke("setInputEnabled", arrayOf(Boolean::class.javaPrimitiveType!!), false) }
    }

    fun close() {
      if (closed) return
      closed = true
      runCatching { invoke("setOnStateChanged", arrayOf(Runnable::class.java), Runnable {}) }
      runCatching { invoke("close") }
      Thread({
        val stopped = runCatching { invoke("awaitTermination") }.isSuccess
        Handler(Looper.getMainLooper()).post {
          if (stopped) {
            sessions.remove(key, this@Session)
            channel?.setMethodCallHandler(null)
          }
        }
      }, "PleazyMoonlightRetire").apply { isDaemon = true }.start()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
      try {
        if (closed && call.method != "disconnect") {
          result.error("STREAM_RETIRED", "The game session has ended", null)
          return
        }
        when (call.method) {
          "setInputEnabled" -> invoke(
            "setInputEnabled",
            arrayOf(Boolean::class.javaPrimitiveType!!),
            call.argument<Boolean>("enabled") == true
          )
          "setAudioEnabled" -> invoke(
            "setAudioEnabled",
            arrayOf(Boolean::class.javaPrimitiveType!!),
            call.argument<Boolean>("enabled") == true
          )
          "resetInput" -> invoke("resetInput")
          "getSessionState" -> {
            result.success(target.javaClass.getMethod("getSessionState").invoke(target))
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
            }, "PleazyMoonlightDisconnect").apply { isDaemon = true }.start()
            return
          }
          else -> {
            result.notImplemented()
            return
          }
        }
        result.success(null)
      } catch (_: Exception) {
        result.error("STREAM_CONTROL_FAILED", "The game stream control could not be applied", null)
      }
    }

    private fun invoke(name: String, types: Array<Class<*>> = emptyArray(), vararg arguments: Any) {
      target.javaClass.getMethod(name, *types).invoke(target, *arguments)
    }
  }
}
