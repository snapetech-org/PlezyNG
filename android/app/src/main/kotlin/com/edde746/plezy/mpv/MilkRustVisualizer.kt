package com.edde746.plezy.mpv

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.Surface
import java.io.File

/** Optional native engine. The AAR session token is never an mpv pointer. */
internal object MilkRustNativeBridge {
  val loadError: String? = try {
    System.loadLibrary("plezy_milkrust_host")
    null
  } catch (_: UnsatisfiedLinkError) {
    "Native MilkRust host is not installed in this build."
  }
  external fun dependencyError(): String
  external fun create(playerSession: Long, channel: Int): Long
  external fun startHelper(channel: Int, surface: Surface)
  external fun destroy(handle: Long)
  external fun load(handle: Long, path: String, root: String, transitionSeconds: Double)
  external fun resize(handle: Long, width: Int, height: Int)
  external fun setMouseState(handle: Long, down: Boolean, x: Double, y: Double, dx: Double, dy: Double)
  external fun pause(handle: Long, paused: Boolean)
  external fun status(handle: Long): Array<String>
  external fun subtitlePcmCaptureAvailable(): Boolean
  external fun subtitlePcmCaptureEnable(playerSession: Long, enabled: Boolean): Int

  /** Returns one bounded packet: pts double, four uint32 fields, then float32 PCM. */
  external fun subtitlePcmCaptureRead(playerSession: Long): ByteArray?

  // Called on the native consumer, never on the playback callback or UI thread.
  @JvmStatic fun decodeTexture(path: String): Bitmap {
    val file = File(path)
    val encodedSize = file.length()
    require(encodedSize in 1..16L * 1024 * 1024) { "Texture exceeds its byte budget." }
    val bytes = file.inputStream().use { stream ->
      val buffer = ByteArray(encodedSize.toInt())
      var offset = 0
      while (offset < buffer.size) {
        val count = stream.read(buffer, offset, buffer.size - offset)
        check(count > 0) { "Texture changed during read." }
        offset += count
      }
      check(stream.read() == -1) { "Texture changed during read." }
      buffer
    }
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    require(
      bounds.outWidth in 1..4096 &&
        bounds.outHeight in 1..4096 &&
        bounds.outWidth.toLong() * bounds.outHeight <= 8L * 1024 * 1024
    ) { "Texture dimensions exceed the decoded image budget." }
    val options = BitmapFactory.Options().apply {
      inPreferredConfig = Bitmap.Config.ARGB_8888
      inScaled = false
      inPremultiplied = false
    }
    return checkNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)) { "Texture decode failed." }
  }
}
