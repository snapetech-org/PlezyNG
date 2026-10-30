package com.edde746.plezy.mpv

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicInteger

/** Admission stays occupied until the old Binder process is confirmed dead. */
private object MilkRustRendererAdmission {
  private var owner: Any? = null
  @Synchronized fun acquire(candidate: Any) {
    check(owner == null) { "The previous visualization service is still terminating. Retry shortly." }
    owner = candidate
  }
  @Synchronized fun release(candidate: Any) {
    if (owner === candidate) owner = null
  }
}

internal class MilkRustVisualizer(
  context: Context,
  registry: TextureRegistry,
  private val playerSession: Long,
) : AutoCloseable {
  companion object { private val nextNonce = AtomicInteger(1) }
  private val context = context.applicationContext
  private val nonce = nextNonce.getAndIncrement().also { check(it > 0) { "Renderer identity exhausted." } }
  private val handler = Handler(Looper.getMainLooper())
  private var entry: TextureRegistry.SurfaceTextureEntry? = null
  private var surface: Surface? = null
  private var parentPipe: ParcelFileDescriptor? = null
  private var childPipe: ParcelFileDescriptor? = null
  private var remote: Messenger? = null
  private var binder: IBinder? = null
  private var bound = false
  private var closed = false
  private var stopping = false
  private var failure: String? = null
  private var handle = 0L
  private var width = 640
  private var height = 360
  private var paused = true
  private data class Preset(val path: String, val root: String, val transition: Double)
  private var preset: Preset? = null
  private var mouseDown = false
  private var mouseClick = false
  private var mouseX = 0.5
  private var mouseY = 0.5
  private var mouseDx = 0.0
  private var mouseDy = 0.0
  val textureId: Long get() = checkNotNull(entry).id()
  private val startupTimeout = Runnable { fail("Visualization service startup timed out.") }
  private val death = IBinder.DeathRecipient { handler.post { disconnected() } }
  private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
    if (message.arg1 == nonce && !stopping) {
      when (message.what) {
        MilkRustServiceProtocol.READY -> {
          if (message.arg2 <= 0 || message.arg2 == Process.myPid()) {
            fail("Visualization service did not start in its private process.")
          } else if (handle == 0L) {
            try {
              handle = MilkRustNativeBridge.create(playerSession, checkNotNull(parentPipe).fd)
              check(handle != 0L) { "Visualization session could not be created." }
              MilkRustNativeBridge.resize(handle, width, height)
              preset?.let { MilkRustNativeBridge.load(handle, it.path, it.root, it.transition) }
              MilkRustNativeBridge.pause(handle, paused)
              if (!paused) flushMouse()
              handler.removeCallbacks(startupTimeout)
            } catch (error: Throwable) {
              fail(error.message ?: "Visualization session could not be created.")
            }
          }
        }
        MilkRustServiceProtocol.ERROR -> fail(message.data.getString("reason") ?: "Visualization service failed.")
      }
    }
    true
  })
  private val connection = object : ServiceConnection {
    override fun onServiceConnected(name: ComponentName, service: IBinder) {
      binder = service
      remote = Messenger(service)
      try {
        service.linkToDeath(death, 0)
        if (stopping) {
          stopService()
          return
        }
        val message = Message.obtain(null, MilkRustServiceProtocol.START, nonce, 0).apply {
          replyTo = replies
          data = Bundle().apply {
            putParcelable("pipe", checkNotNull(childPipe))
            putParcelable("surface", checkNotNull(surface))
            putInt("parentPid", Process.myPid())
          }
        }
        checkNotNull(remote).send(message)
        childPipe?.close()
        childPipe = null
      } catch (error: Exception) {
        fail(error.message ?: "Could not connect to the visualization service.")
        if (!service.isBinderAlive) disconnected()
      }
    }
    override fun onServiceDisconnected(name: ComponentName) = disconnected()
    override fun onBindingDied(name: ComponentName) {
      fail("Visualization service binding ended.")
      if (binder?.isBinderAlive != true) disconnected()
    }
    override fun onNullBinding(name: ComponentName) {
      fail("The visualization service is not installed in its private process.")
      disconnected()
    }
  }

  init {
    checkMainThread()
    MilkRustRendererAdmission.acquire(this)
    try {
      entry = registry.createSurfaceTexture()
      surface = Surface(checkNotNull(entry).surfaceTexture())
      val pair = ParcelFileDescriptor.createSocketPair()
      parentPipe = pair[0]
      childPipe = pair[1]
      bound = this.context.bindService(
        Intent(this.context, MilkRustRendererService::class.java), connection, Context.BIND_AUTO_CREATE,
      )
      check(bound) { "The visualization service is unavailable." }
      handler.postDelayed(startupTimeout, MilkRustServiceProtocol.STARTUP_TIMEOUT_MS)
    } catch (error: Throwable) {
      close()
      throw error
    }
  }

  private fun checkMainThread() = check(Looper.myLooper() == Looper.getMainLooper())
  private fun checkActive() {
    checkMainThread()
    check(!stopping) { failure ?: "This visualization session has ended." }
  }
  private fun unbind() {
    if (bound) {
      bound = false
      runCatching { context.unbindService(connection) }
    }
  }
  private fun stopService() {
    runCatching { remote?.send(Message.obtain(null, MilkRustServiceProtocol.STOP, nonce, 0)) }
    // Keep the death recipient after unbinding. A successful STOP message or
    // unbind is not evidence that a GPU-stalled process has actually exited.
    if (binder != null) unbind()
  }
  private fun retire() {
    stopping = true
    handler.removeCallbacks(startupTimeout)
    val retired = handle
    handle = 0L
    if (retired != 0L) runCatching { MilkRustNativeBridge.destroy(retired) }
    runCatching { parentPipe?.close() }
    runCatching { childPipe?.close() }
    parentPipe = null
    childPipe = null
    stopService()
    // A late onServiceConnected must still receive STOP. Retain that pending
    // binding and the admission lease until it reports death or a null binding.
    if (!bound && binder == null) MilkRustRendererAdmission.release(this)
  }
  private fun fail(reason: String) {
    if (failure == null && !closed) failure = reason.take(8192)
    retire()
  }
  private fun disconnected() {
    if (!stopping) fail("The visualization service exited. Music playback is still active.")
    else retire()
    unbind()
    binder = null
    remote = null
    MilkRustRendererAdmission.release(this)
  }

  fun load(path: String, root: String, transitionSeconds: Double) {
    checkActive()
    require(listOf(path, root).all { it.isNotEmpty() && '\u0000' !in it && it.toByteArray(Charsets.UTF_8).size <= 32768 }) {
      "Invalid visualization preset path."
    }
    require(transitionSeconds.isFinite() && transitionSeconds in 0.0..10.0) { "Invalid visualization transition." }
    preset = Preset(path, root, transitionSeconds)
    if (handle != 0L) MilkRustNativeBridge.load(handle, path, root, transitionSeconds)
  }
  fun resize(width: Int, height: Int) {
    checkActive()
    require(width in 1..16384 && height in 1..16384) { "Invalid visualization dimensions." }
    this.width = width
    this.height = height
    if (handle != 0L) MilkRustNativeBridge.resize(handle, width, height)
  }
  fun setMouseState(down: Boolean, x: Double, y: Double, dx: Double, dy: Double) {
    checkActive()
    require(listOf(x, y, dx, dy).all { it.isFinite() } && x in 0.0..1.0 && y in 0.0..1.0 && dx in -1.0..1.0 && dy in -1.0..1.0) {
      "Invalid visualization pointer input."
    }
    if (handle != 0L) {
      MilkRustNativeBridge.setMouseState(handle, down, x, y, dx, dy)
    } else if (!paused) {
      mouseClick = mouseClick || (down && !mouseDown)
      mouseDown = down
      mouseX = x
      mouseY = y
      mouseDx = (mouseDx + dx).coerceIn(-1.0, 1.0)
      mouseDy = (mouseDy + dy).coerceIn(-1.0, 1.0)
    }
  }
  private fun flushMouse() {
    MilkRustNativeBridge.setMouseState(handle, mouseDown || mouseClick, mouseX, mouseY, mouseDx, mouseDy)
    if (mouseClick && !mouseDown) MilkRustNativeBridge.setMouseState(handle, false, mouseX, mouseY, 0.0, 0.0)
    mouseClick = false
    mouseDx = 0.0
    mouseDy = 0.0
  }
  fun pause(paused: Boolean) {
    checkActive()
    this.paused = paused
    if (paused) {
      mouseDown = false
      mouseClick = false
      mouseDx = 0.0
      mouseDy = 0.0
    }
    if (handle != 0L) MilkRustNativeBridge.pause(handle, paused)
  }
  fun status(): Map<String, Any> {
    checkMainThread()
    if (handle != 0L) {
      val values = MilkRustNativeBridge.status(handle)
      check(values.size == 6) { "Invalid native status." }
      if (values[0] == "failed") fail(values[1])
      return mapOf(
        "state" to values[0], "reason" to values[1], "hasFrame" to (values[2] == "1"),
        "droppedFrames" to values[3].toLong(), "width" to values[4].toInt(), "height" to values[5].toInt(),
        "engine" to "milkrust",
      )
    }
    return mapOf(
      "state" to if (failure != null) "failed" else if (closed) "closed" else "starting",
      "reason" to (failure ?: ""), "hasFrame" to false, "droppedFrames" to 0L,
      "width" to width.coerceAtMost(1280), "height" to height.coerceAtMost(720), "engine" to "milkrust",
    )
  }
  override fun close() {
    checkMainThread()
    if (closed) return
    closed = true
    retire()
    surface?.release()
    surface = null
    entry?.release()
    entry = null
  }
}
