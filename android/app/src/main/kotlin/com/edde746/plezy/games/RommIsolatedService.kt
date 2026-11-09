// SPDX-License-Identifier: AGPL-3.0-only
package com.edde746.plezy.games

import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process

/** Android supplies a separate isolated UID, with no app files or permissions. */
class RommIsolatedService : Service() {
  companion object {
    const val START = 1
    const val STOP = 2
  }
  private var isolated = false
  private var started = false
  private val handler = Handler(Looper.getMainLooper()) { message ->
    if (message.what == STOP) terminate() else if (message.what == START) start(message)
    true
  }
  private val messenger = Messenger(handler)
  private val idleTimeout = Runnable { terminate() }

  override fun onCreate() {
    super.onCreate()
    // Includes Android's per-app zygote range. Never kill an ordinary app UID
    // if the manifest's isolatedProcess declaration is missing or overridden.
    isolated = Process.myUid() % 100000 in 90000..99999
    if (isolated) handler.postDelayed(idleTimeout, 10000)
  }

  override fun onBind(intent: Intent): IBinder? = if (isolated) messenger.binder else null

  private fun terminate() {
    handler.removeCallbacks(idleTimeout)
    if (isolated) Process.killProcess(Process.myPid()) else stopSelf()
  }

  @Suppress("DEPRECATION")
  private fun start(message: Message) {
    var pipe: ParcelFileDescriptor? = null
    var files: ArrayList<ParcelFileDescriptor>? = null
    try {
      check(isolated && !started)
      pipe = message.data.getParcelable("pipe")
      files = message.data.getParcelableArrayList("files")
      val names = checkNotNull(message.data.getStringArrayList("names"))
      val core = checkNotNull(message.data.getString("core"))
      val inputs = checkNotNull(files)
      val socket = checkNotNull(pipe)
      require(names.size == inputs.size && names.size <= 65)
      require(core in setOf("libgambatte_libretro.so", "libmgba_libretro.so", "libfceumm_libretro.so"))
      started = true
      handler.removeCallbacks(idleTimeout)
      Thread({
        try {
          System.loadLibrary("plezy_retro_worker")
          runWorker(socket.fd, core, names.toTypedArray(), inputs.map { it.fd }.toIntArray())
        } finally {
          runCatching { socket.close() }
          inputs.forEach { runCatching { it.close() } }
          terminate()
        }
      }, "RomM-isolated-core").apply { isDaemon = true }.start()
      pipe = null
      files = null
    } catch (_: Throwable) {
      runCatching { pipe?.close() }
      files?.forEach { runCatching { it.close() } }
      terminate()
    }
  }

  private external fun runWorker(pipe: Int, core: String, names: Array<String>, descriptors: IntArray)

  override fun onDestroy() {
    super.onDestroy()
    terminate()
  }
}
