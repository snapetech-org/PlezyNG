package com.edde746.plezy.mpv

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the packaged service boundary without a GPU or mpv dependency. */
@RunWith(AndroidJUnit4::class)
class MilkRustRendererServiceTest {
  @Test fun privateServiceStopsAndRejectsMalformedStartupWithoutKillingPlayer() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val component = ComponentName(context, MilkRustRendererService::class.java)
    @Suppress("DEPRECATION")
    val info = context.packageManager.getServiceInfo(component, 0)
    assertFalse("Renderer Binder must not be exported", info.exported)
    assertEquals(context.packageName + MilkRustServiceProtocol.PROCESS_SUFFIX, info.processName)
    val playerPid = Process.myPid()
    var previous: IBinder? = null
    // First stop before native startup, then rebind a new process and supply a
    // malformed startup message. Both must terminate only the renderer process.
    for (malformed in listOf(false, true)) {
      val connected = CountDownLatch(1)
      val died = CountDownLatch(1)
      val errorReply = CountDownLatch(1)
      val endpoint = AtomicReference<IBinder>()
      val callbackError = AtomicReference<Throwable>()
      val replyPid = AtomicReference<Int>()
      val replyReason = AtomicReference<String>()
      val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
          try {
            endpoint.set(service)
            service.linkToDeath({ died.countDown() }, 0)
          } catch (error: Throwable) { callbackError.set(error) }
          connected.countDown()
        }
        override fun onServiceDisconnected(name: ComponentName) = Unit
        override fun onNullBinding(name: ComponentName) {
          callbackError.set(AssertionError("Renderer returned a null Binder"))
          connected.countDown()
        }
      }
      val bound = context.bindService(Intent().setComponent(component), serviceConnection, Context.BIND_AUTO_CREATE)
      assertTrue("Renderer service did not bind", bound)
      try {
        assertTrue("Renderer binding timed out", connected.await(10, TimeUnit.SECONDS))
        callbackError.get()?.let { throw AssertionError("Renderer binding failed", it) }
        val service = checkNotNull(endpoint.get())
        assertNotEquals("A retired service process was reused", previous, service)
        previous = service
        val message = Message.obtain(null, if (malformed) MilkRustServiceProtocol.START else MilkRustServiceProtocol.STOP, 71, 0)
        if (malformed) {
          message.replyTo = Messenger(Handler(Looper.getMainLooper()) { reply ->
            if (reply.what == MilkRustServiceProtocol.ERROR && reply.arg1 == 71) {
              replyPid.set(reply.arg2)
              replyReason.set(reply.data.getString("reason"))
              errorReply.countDown()
            }
            true
          })
        }
        Messenger(service).send(message)
        if (malformed) {
          assertTrue("Malformed startup did not report its failure", errorReply.await(10, TimeUnit.SECONDS))
          assertTrue("Renderer PID was invalid", checkNotNull(replyPid.get()) > 0)
          assertNotEquals("Renderer ran in the player process", playerPid, replyPid.get())
          assertFalse("Startup error was empty", replyReason.get().isNullOrEmpty())
        }
        assertTrue("Renderer did not terminate", died.await(10, TimeUnit.SECONDS))
        assertFalse(service.isBinderAlive)
        assertEquals("Player process changed", playerPid, Process.myPid())
      } finally {
        runCatching { endpoint.get()?.let { Messenger(it).send(Message.obtain(null, MilkRustServiceProtocol.STOP, 71, 0)) } }
        context.unbindService(serviceConnection)
      }
    }
  }
}
