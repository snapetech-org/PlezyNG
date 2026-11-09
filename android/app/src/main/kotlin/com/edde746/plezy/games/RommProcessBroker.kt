// SPDX-License-Identifier: AGPL-3.0-only
package com.edde746.plezy.games

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
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** The app owns input descriptors and audio. Only this private service may load cores. */
object RommProcessBroker {
  private val main = Handler(Looper.getMainLooper())
  private var context: Context? = null
  private var active: Worker? = null
  private val cores = setOf("libgambatte_libretro.so", "libmgba_libretro.so", "libfceumm_libretro.so")

  @Synchronized
  fun attach(context: Context) {
    if (this.context != null) return
    System.loadLibrary("plezy_retro")
    initialize()
    this.context = context.applicationContext
  }

  @JvmStatic private external fun initialize()

  // Called by the trusted native proxy from a Dart worker thread, never the UI.
  @JvmStatic
  fun launch(core: String, rom: String, system: String): Worker {
    check(Looper.myLooper() != Looper.getMainLooper())
    require(core in cores) { "Core is not bundled." }
    val worker = synchronized(this) {
      val app = checkNotNull(context) { "Emulator service is unavailable." }
      check(active?.isDead() != false) { "Previous emulator is still terminating." }
      Worker(app, core, rom, system).also { active = it }
    }
    try {
      main.post { worker.bind() }
      check(worker.connected.await(8, TimeUnit.SECONDS) && worker.binder?.isBinderAlive == true) {
        "Emulator service did not connect."
      }
      worker.sendInputs()
      return worker
    } catch (error: Throwable) {
      worker.close()
      throw error
    }
  }

  class Worker internal constructor(
    private val app: Context,
    private val core: String,
    private val rom: String,
    private val system: String,
  ) : ServiceConnection {
    internal val connected = CountDownLatch(1)
    @Volatile internal var binder: IBinder? = null
    @Volatile private var dead = false
    @Volatile private var closing = false
    private var bound = false // main thread only
    private var pipe: ParcelFileDescriptor? = null

    internal fun bind() {
      if (closing) { dead = true; connected.countDown(); return }
      try {
        bound = app.bindService(Intent(app, RommIsolatedService::class.java), this, Context.BIND_AUTO_CREATE)
        if (!bound) { dead = true; connected.countDown() }
      } catch (_: Exception) {
        dead = true
        connected.countDown()
      }
    }

    override fun onServiceConnected(name: ComponentName, service: IBinder) {
      binder = service
      try {
        service.linkToDeath({ dead = true; close() }, 0)
        if (closing) close()
      } catch (_: Exception) {
        dead = true
        close()
      } finally {
        connected.countDown()
      }
    }

    override fun onServiceDisconnected(name: ComponentName) {
      // This callback is issued by Android after the hosting process dies.
      dead = true
      connected.countDown()
      close()
    }

    override fun onNullBinding(name: ComponentName) {
      // No inputs have been sent; no game files are owned by the service.
      dead = true
      connected.countDown()
      close()
    }

    override fun onBindingDied(name: ComponentName) {
      if (binder?.isBinderAlive != true) dead = true
      connected.countDown()
      close()
    }

    private fun input(file: File, maximum: Long): ParcelFileDescriptor {
      val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW, 0)
      try {
        val stat = Os.fstat(fd)
        require(OsConstants.S_ISREG(stat.st_mode) && stat.st_size in 1..maximum) { "Invalid game input." }
        return ParcelFileDescriptor.dup(fd)
      } finally {
        Os.close(fd)
      }
    }

    internal fun sendInputs() {
      val files = arrayListOf<ParcelFileDescriptor>()
      val names = arrayListOf<String>()
      val sockets = ParcelFileDescriptor.createSocketPair()
      try {
        if (rom.isNotEmpty()) {
          val game = File(rom)
          require(game.name.length <= 255)
          files.add(input(game, 128L * 1024 * 1024))
          names.add("/rom/${game.name}")
          val root = File(system).canonicalFile
          var total = 0L
          fun visit(directory: File, depth: Int) {
            require(depth <= 8)
            val children = directory.listFiles() ?: error("Firmware directory is unreadable.")
            require(children.size <= 64)
            for (file in children.sortedBy { it.name }) {
              // Do not follow symlinks, including directory links.
              require(file.canonicalFile == file.absoluteFile) { "Linked firmware is unsupported." }
              if (file.isDirectory) visit(file, depth + 1) else {
                require(files.size < 65)
                val path = file.relativeTo(root).invariantSeparatorsPath
                require(path.length <= 1024 && !path.split('/').contains(".."))
                val descriptor = input(file, 256L * 1024 * 1024)
                files.add(descriptor)
                total += descriptor.statSize
                require(total <= 256L * 1024 * 1024)
                names.add("/system/$path")
              }
            }
          }
          visit(root, 0)
        }
        val message = Message.obtain(null, RommIsolatedService.START).apply {
          data = Bundle().apply {
            putString("core", core)
            putStringArrayList("names", names)
            putParcelableArrayList("files", files)
            putParcelable("pipe", sockets[1])
          }
        }
        Messenger(checkNotNull(binder)).send(message)
        synchronized(this) {
          check(!closing)
          pipe = sockets[0]
        }
      } catch (error: Throwable) {
        sockets[0].close()
        throw error
      } finally {
        sockets[1].close()
        files.forEach { runCatching { it.close() } }
      }
    }

    @Synchronized
    fun detachFd(): Int {
      check(!closing)
      val descriptor = checkNotNull(pipe)
      pipe = null
      return descriptor.detachFd()
    }

    fun isDead(): Boolean = dead

    fun close() {
      synchronized(this) {
        closing = true
        runCatching { pipe?.close() }
        pipe = null
      }
      main.post {
        runCatching { binder?.let { Messenger(it).send(Message.obtain(null, RommIsolatedService.STOP)) } }
        if (bound) {
          bound = false
          runCatching { app.unbindService(this) }
        }
        // Unbinding is a stop request, not proof of exit. Only OS death
        // notification releases the native lease after inputs were sent.
      }
    }
  }
}
