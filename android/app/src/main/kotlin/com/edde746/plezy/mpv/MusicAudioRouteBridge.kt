package com.edde746.plezy.mpv

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable

/**
 * Anticipated routing for a media AudioTrack, never an available/communication
 * device list. Unknown stable identities and pre-33 devices cannot arm a car.
 * Reading/observing does not activate audio, change routing or start playback.
 */
internal object MusicAudioRouteSnapshot {
  val attributes: AudioAttributes
    get() = AudioAttributes.Builder()
      .setUsage(AudioAttributes.USAGE_MEDIA)
      .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
      .build()

  fun read(audio: AudioManager): Map<String, Any>? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
    return try {
      val routed = audio.getAudioDevicesForAttributes(attributes)
      if (routed.isEmpty()) return null
      val outputs = routed.asSequence().filter { it.isSink }.mapNotNull { device ->
        val address = device.address
        // Product names and connection-scoped numeric IDs are not stable keys.
        if (address.isEmpty() ||
          address.length > 480 ||
          address.contains('\u0000') ||
          address == "02:00:00:00:00:00" ||
          address == "00:00:00:00:00:00"
        ) {
          return@mapNotNull null
        }
        val bluetooth = device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
          device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
          device.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
          device.type == AudioDeviceInfo.TYPE_BLE_SPEAKER ||
          device.type == AudioDeviceInfo.TYPE_HEARING_AID
        mapOf(
          "id" to "${device.type}:$address",
          "name" to device.productName.toString().take(256),
          "type" to "android:${device.type}",
          "bluetooth" to bluetooth,
          "channels" to 0
        )
      }.distinctBy { it["id"] }.sortedBy { it["id"] as String }.take(16).toList()
      mapOf(
        "version" to 1,
        "outputs" to outputs,
        // Supported channel/sample-rate arrays are capabilities, not current
        // measurements; zero explicitly represents an unavailable measurement.
        "sampleRate" to 0.0,
        "outputChannels" to 0,
        "outputLatencyMs" to 0.0,
        "ioBufferMs" to 0.0
      )
    } catch (_: RuntimeException) {
      // A refused route query or vendor service failure remains unknown.
      null
    }
  }
}

internal class MusicAudioRouteBridge(context: Context, messenger: BinaryMessenger) :
  MethodChannel.MethodCallHandler,
  EventChannel.StreamHandler,
  Closeable {
  private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
  private val methods = MethodChannel(messenger, "com.pleazyng/music_audio_route")
  private val events = EventChannel(messenger, "com.pleazyng/music_audio_route/events")
  private val handler = Handler(Looper.getMainLooper())
  private var sink: EventChannel.EventSink? = null
  private var registered = false
  private var published = false
  private var last: Map<String, Any>? = null
  private val devices = object : AudioDeviceCallback() {
    override fun onAudioDevicesAdded(addedDevices: Array<AudioDeviceInfo>) {
      publish()
    }
    override fun onAudioDevicesRemoved(removedDevices: Array<AudioDeviceInfo>) {
      publish()
    }
  }
  private val poll = object : Runnable {
    override fun run() {
      if (sink == null) return
      publish()
      handler.postDelayed(this, 2000)
    }
  }

  init {
    methods.setMethodCallHandler(this)
    events.setStreamHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method == "snapshot") {
      result.success(MusicAudioRouteSnapshot.read(audio))
    } else {
      result.notImplemented()
    }
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
    stop()
    sink = events
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      events.error("unsupported", "Selected media routing requires Android 13.", null)
      return
    }
    try {
      audio.registerAudioDeviceCallback(devices, handler)
      registered = true
      poll.run()
    } catch (_: RuntimeException) {
      stop()
      events.error("unavailable", "The selected media route is unavailable.", null)
    }
  }

  private fun publish() {
    val listener = sink ?: return
    val next = MusicAudioRouteSnapshot.read(audio)
    if (published && last == next) return
    published = true
    last = next
    if (next == null) {
      listener.error("unavailable", "The selected media route is unavailable.", null)
    } else {
      listener.success(next)
    }
  }

  override fun onCancel(arguments: Any?) {
    stop()
  }

  private fun stop() {
    sink = null
    handler.removeCallbacks(poll)
    if (registered) {
      try {
        audio.unregisterAudioDeviceCallback(devices)
      } catch (_: RuntimeException) {
        // A detached service cannot retain an app-owned polling callback.
      }
    }
    registered = false
    published = false
    last = null
  }

  override fun close() {
    stop()
    methods.setMethodCallHandler(null)
    events.setStreamHandler(null)
  }
}
