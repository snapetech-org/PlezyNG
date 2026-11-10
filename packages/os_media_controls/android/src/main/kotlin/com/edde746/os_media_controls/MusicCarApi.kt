package com.edde746.os_media_controls

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Catalog/commands only. The existing MediaSession and Dart player own transport. */
object MusicCarApi {
    private var channel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())
    private val listeners = mutableSetOf<() -> Unit>()
    private var epoch = 0
    var hasCarHost = false
        private set
    var ready = false
        private set
    var snapshot: Map<*, *> = emptyMap<Any, Any>()
        private set

    fun attach(messenger: BinaryMessenger) {
        epoch++
        ready = false
        channel = MethodChannel(messenger, "com.pleazyng/music_car").also { pipe ->
            pipe.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> { epoch++; ready = true; if (hasCarHost) connection(true); listeners.toList().forEach { it() }; result.success(null) }
                    "catalogChanged" -> { listeners.toList().forEach { it() }; result.success(null) }
                    "snapshot" -> { snapshot = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>(); listeners.toList().forEach { it() }; result.success(null) }
                    "close" -> { epoch++; ready = false; snapshot = emptyMap<Any, Any>(); listeners.toList().forEach { it() }; result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
    }
    fun detach() { epoch++; ready = false; snapshot = emptyMap<Any, Any>(); channel?.setMethodCallHandler(null); channel = null }
    fun addListener(listener: () -> Unit) { listeners.add(listener) }
    fun removeListener(listener: () -> Unit) { listeners.remove(listener) }
    fun connection(connected: Boolean) { hasCarHost = connected; channel?.invokeMethod("connection", mapOf("connected" to connected)) }
    fun request(method: String, args: Any?, done: (Any?) -> Unit) {
        val pipe = channel
        if (pipe == null || !ready) { done(null); return }
        val expected = epoch
        var finished = false
        fun finish(value: Any?) { if (!finished) { finished = true; done(if (ready && expected == epoch) value else null) } }
        val timeout = Runnable { finish(null) }
        handler.postDelayed(timeout, 10000)
        pipe.invokeMethod(method, args, object : MethodChannel.Result {
            override fun success(result: Any?) { handler.removeCallbacks(timeout); finish(result) }
            override fun error(code: String, message: String?, details: Any?) { handler.removeCallbacks(timeout); finish(null) }
            override fun notImplemented() { handler.removeCallbacks(timeout); finish(null) }
        })
    }
}
