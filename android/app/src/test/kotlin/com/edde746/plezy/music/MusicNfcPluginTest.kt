package com.edde746.plezy.music

import android.app.Activity
import android.content.pm.PackageManager
import android.nfc.NfcAdapter
import android.os.Looper
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNfcAdapter
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class MusicNfcPluginTest {
  @Test
  fun cancelledReaderCallbackDoesNotConsumeReplacementScan() {
    shadowOf(RuntimeEnvironment.getApplication().packageManager).setSystemFeature(PackageManager.FEATURE_NFC, true)
    val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    ShadowNfcAdapter.setNfcHardwareExists(true)
    val adapter = shadowOf(NfcAdapter.getDefaultAdapter(activity))
    adapter.setEnabled(true)
    val binding = ActivityPluginBinding::class.java
    val plugin = MusicNfcPlugin()
    plugin.onAttachedToActivity(
      Proxy.newProxyInstance(binding.classLoader, arrayOf(binding)) { _, method, _ ->
        check(method.name == "getActivity")
        activity
      } as ActivityPluginBinding
    )
    try {
      assertEquals(listOf(true), plugin.invoke("readAvailable").replies)
      val first = plugin.invoke("read")
      val stale = ReflectionHelpers.getField<NfcAdapter.ReaderCallback>(adapter, "readerCallback")
      assertEquals(listOf(null), plugin.invoke("cancel").replies)
      assertEquals(listOf("cancelled"), first.replies)
      val replacement = plugin.invoke("read")
      assertTrue(adapter.isInReaderMode)
      stale.onTagDiscovered(ShadowNfcAdapter.createMockTag())
      shadowOf(Looper.getMainLooper()).idle()
      assertTrue(replacement.replies.isEmpty())
      adapter.dispatchTagDiscovered(ShadowNfcAdapter.createMockTag())
      shadowOf(Looper.getMainLooper()).idle()
      assertEquals(listOf("invalid_link"), replacement.replies)
      assertFalse(adapter.isInReaderMode)
    } finally {
      plugin.onDetachedFromActivity()
    }
  }

  private fun MusicNfcPlugin.invoke(method: String): Reply = Reply().also { onMethodCall(MethodCall(method, null), it) }

  private class Reply : MethodChannel.Result {
    val replies = mutableListOf<Any?>()
    override fun success(result: Any?) {
      replies.add(result)
    }

    override fun error(code: String, message: String?, details: Any?) {
      replies.add(code)
    }

    override fun notImplemented() {
      error("not_implemented", null, null)
    }
  }
}
