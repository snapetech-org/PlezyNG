package com.edde746.plezy.music

import android.app.Activity
import android.net.Uri
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MusicNfcPlugin :
  FlutterPlugin,
  ActivityAware,
  MethodChannel.MethodCallHandler,
  NfcAdapter.ReaderCallback {
  private data class Write(val result: MethodChannel.Result, val message: NdefMessage, var writing: Boolean = false)
  private val handler = Handler(Looper.getMainLooper())
  private val lock = Any()
  private var activity: Activity? = null
  private var channel: MethodChannel? = null
  private var pending: Write? = null
  private val timeout = Runnable { finish(null, "timeout") }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "com.pleazyng/music_nfc").also { it.setMethodCallHandler(this) }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val host = activity
    val adapter = host?.let { NfcAdapter.getDefaultAdapter(it) }
    when (call.method) {
      "available" -> result.success(adapter?.isEnabled == true)
      "cancel" -> {
        finish(null, "cancelled")
        result.success(null)
      }
      "write" -> {
        if (host == null || adapter?.isEnabled != true) {
          result.error("unavailable", null, null)
          return
        }
        val link = call.argument<String>("uri") ?: ""
        val uri = Uri.parse(link)
        if (link.length > 2048 || uri.scheme != "pleazyng" || uri.host != "play" || !uri.path.isNullOrEmpty() || uri.fragment != null || uri.userInfo != null || uri.port != -1 || uri.queryParameterNames != setOf("server", "id") || uri.queryParameterNames.any { uri.getQueryParameters(it).size != 1 || uri.getQueryParameter(it).isNullOrBlank() }) {
          result.error("invalid_link", null, null)
          return
        }
        if (synchronized(lock) { pending != null }) {
          result.error("busy", null, null)
          return
        }
        synchronized(lock) { pending = Write(result, NdefMessage(arrayOf(NdefRecord.createUri(uri)))) }
        try {
          adapter.enableReaderMode(host, this, NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or NfcAdapter.FLAG_READER_NFC_F or NfcAdapter.FLAG_READER_NFC_V, null)
          handler.postDelayed(timeout, 30000)
        } catch (_: Exception) {
          finish(null, "unavailable")
        }
      }
      else -> result.notImplemented()
    }
  }

  override fun onTagDiscovered(tag: Tag) {
    val write = synchronized(lock) { pending?.takeUnless { it.writing }?.also { it.writing = true } } ?: return
    var error: String? = null
    try {
      val ndef = Ndef.get(tag)
      if (ndef != null) {
        ndef.use {
          it.connect()
          if (!it.isWritable || it.maxSize < write.message.toByteArray().size) throw IllegalStateException()
          if (synchronized(lock) { pending !== write }) return
          it.writeNdefMessage(write.message)
        }
      } else {
        val blank = NdefFormatable.get(tag) ?: throw IllegalStateException()
        blank.use {
          it.connect()
          if (synchronized(lock) { pending !== write }) return
          it.format(write.message)
        }
      }
    } catch (_: Exception) {
      error = "write_failed"
    }
    handler.post { finish(write, error) }
  }

  private fun finish(expected: Write?, error: String?) {
    val write = synchronized(lock) {
      val value = pending
      if (expected != null && expected !== value) return
      pending = null
      value
    } ?: return
    handler.removeCallbacks(timeout)
    activity?.let { runCatching { NfcAdapter.getDefaultAdapter(it)?.disableReaderMode(it) } }
    if (error == null) write.result.success(true) else write.result.error(error, null, null)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
  }
  override fun onDetachedFromActivityForConfigChanges() {
    onDetachedFromActivity()
  }
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    onAttachedToActivity(binding)
  }
  override fun onDetachedFromActivity() {
    finish(null, "cancelled")
    activity = null
  }
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    finish(null, "cancelled")
    channel?.setMethodCallHandler(null)
    channel = null
  }
}
