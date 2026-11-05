package com.edde746.plezy.mpv

import android.app.ActivityManager
import android.app.Application
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import android.view.Surface

internal object MilkRustServiceProtocol {
  const val START = 1
  const val STOP = 2
  const val READY = 3
  const val ERROR = 4
  const val STARTUP_TIMEOUT_MS = 5000L
  const val PROCESS_SUFFIX = ":milkrust_visualizer"
}

/** One renderer per process. A driver hang must never hold the music player. */
class MilkRustRendererService : Service() {
  private var privateProcess = false
  private var started = false
  private var nonce = 0
  private val handler = Handler(Looper.getMainLooper()) { message ->
    when (message.what) {
      MilkRustServiceProtocol.START -> startRenderer(message)
      MilkRustServiceProtocol.STOP -> {
        if (!started || message.arg1 == nonce) terminate()
      }
    }
    true
  }
  private val messenger = Messenger(handler)
  private val startupTimeout = Runnable { terminate() }

  override fun onCreate() {
    super.onCreate()
    val processName = if (Build.VERSION.SDK_INT >= 28) {
      Application.getProcessName()
    } else {
      (getSystemService(ACTIVITY_SERVICE) as ActivityManager)
        .runningAppProcesses?.firstOrNull { it.pid == Process.myPid() }?.processName
    }
    // Fail closed if packaging puts this service in the player process. Never
    // kill a process merely because the caller supplied a PID or a name.
    privateProcess = processName == packageName + MilkRustServiceProtocol.PROCESS_SUFFIX
  }

  override fun onBind(intent: Intent): IBinder? = if (privateProcess) messenger.binder else null

  private fun terminate() {
    handler.removeCallbacks(startupTimeout)
    if (privateProcess) Process.killProcess(Process.myPid()) else stopSelf()
  }

  private fun reply(recipient: Messenger?, what: Int, token: Int, reason: String? = null) {
    try {
      recipient?.send(Message.obtain(null, what, token, Process.myPid()).apply {
        if (reason != null) data = Bundle().apply { putString("reason", reason.take(8192)) }
      })
    } catch (_: Exception) {
      terminate()
    }
  }

  @Suppress("DEPRECATION")
  private fun startRenderer(message: Message) {
    var pipe: ParcelFileDescriptor? = null
    var surface: Surface? = null
    try {
      pipe = message.data.getParcelable("pipe")
      surface = message.data.getParcelable("surface")
      check(privateProcess && !started && message.arg1 > 0) { "Renderer service is not available." }
      check(message.data.getInt("parentPid") != Process.myPid()) { "Renderer service shares the player process." }
      val channel = checkNotNull(pipe) { "Renderer socket is missing." }
      val target = checkNotNull(surface) { "Renderer surface is missing." }
      check(target.isValid) { "Renderer surface is no longer valid." }
      started = true
      nonce = message.arg1
      val token = nonce
      val recipient = message.replyTo
      handler.postDelayed(startupTimeout, MilkRustServiceProtocol.STARTUP_TIMEOUT_MS)
      // Native setup can enter a platform driver. Keep the service's main
      // Handler free to honor STOP and its independent startup deadline.
      Thread({
        try {
          check(MilkRustNativeBridge.loadError == null) { MilkRustNativeBridge.loadError.orEmpty() }
          // JNI duplicates this FD before returning; Java always closes its copy.
          MilkRustNativeBridge.startHelper(channel.fd, target)
          handler.post {
            handler.removeCallbacks(startupTimeout)
            reply(recipient, MilkRustServiceProtocol.READY, token)
          }
        } catch (error: Throwable) {
          handler.post {
            reply(recipient, MilkRustServiceProtocol.ERROR, token, error.message ?: "Renderer startup failed.")
            terminate()
          }
        } finally {
          runCatching { channel.close() }
          target.release()
        }
      }, "MilkRust-service-start").apply { isDaemon = true }.start()
      pipe = null
      surface = null
    } catch (error: Throwable) {
      runCatching { pipe?.close() }
      surface?.release()
      reply(message.replyTo, MilkRustServiceProtocol.ERROR, message.arg1, error.message ?: "Renderer startup failed.")
      terminate()
    }
  }

  override fun onDestroy() {
    super.onDestroy()
    // Do not unwind into native GL cleanup. This process has no playback state.
    terminate()
  }
}
