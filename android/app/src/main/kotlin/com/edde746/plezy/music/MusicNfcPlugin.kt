package com.edde746.plezy.music

import android.app.Activity
import android.app.AlertDialog
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
  MethodChannel.MethodCallHandler {
  private class Scan(val result: MethodChannel.Result, val message: NdefMessage?, var claimed: Boolean = false)
  private val handler = Handler(Looper.getMainLooper())
  private val lock = Any()
  private var activity: Activity? = null
  private var channel: MethodChannel? = null
  private var pending: Scan? = null
  private var promptDialog: AlertDialog? = null
  private val timeout = Runnable { finish(null, "timeout") }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "com.pleazyng/music_nfc").also { it.setMethodCallHandler(this) }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val host = activity
    val adapter = host?.let { NfcAdapter.getDefaultAdapter(it) }
    when (call.method) {
      "available", "readAvailable" -> result.success(adapter?.isEnabled == true)
      "cancel" -> {
        finish(null, "cancelled")
        result.success(null)
      }
      "read", "write" -> {
        if (host == null || adapter?.isEnabled != true) {
          result.error("unavailable", null, null)
          return
        }
        if (synchronized(lock) { pending != null }) {
          result.error("busy", null, null)
          return
        }
        val message = if (call.method == "write") {
          val uri = musicUri(call.argument<String>("uri")?.let(Uri::parse))
          if (uri == null) {
            result.error("invalid_link", null, null)
            return
          }
          NdefMessage(arrayOf(NdefRecord.createUri(uri)))
        } else {
          null
        }
        val scan = Scan(result, message)
        synchronized(lock) { pending = scan }
        try {
          adapter.enableReaderMode(
            host,
            { tag -> onTagDiscovered(scan, tag) },
            NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or NfcAdapter.FLAG_READER_NFC_F or NfcAdapter.FLAG_READER_NFC_V,
            null
          )
          handler.postDelayed(timeout, 30000)
          if (message == null) {
            call.argument<String>("prompt")?.takeIf { it.isNotBlank() }?.let { prompt ->
              promptDialog = AlertDialog.Builder(host)
                .setMessage(prompt)
                .setNegativeButton(android.R.string.cancel) { _, _ -> finish(scan, "cancelled") }
                .setOnCancelListener { finish(scan, "cancelled") }
                .show()
            }
          }
        } catch (_: Exception) {
          finish(scan, "unavailable")
        }
      }
      else -> result.notImplemented()
    }
  }

  private fun onTagDiscovered(scan: Scan, tag: Tag) {
    synchronized(lock) {
      if (pending !== scan || scan.claimed) return
      scan.claimed = true
    }
    var error: String? = null
    var value: Any? = null
    try {
      val ndef = Ndef.get(tag)
      val message = scan.message
      if (message == null) {
        value = ndef?.use {
          it.connect()
          it.ndefMessage?.records?.asSequence()
            ?.filter { record -> record.tnf == NdefRecord.TNF_WELL_KNOWN && record.type.contentEquals(NdefRecord.RTD_URI) }
            ?.mapNotNull { record -> musicUri(record.toUri()) }
            ?.singleOrNull()
            ?.toString()
        }
        if (value == null) error = "invalid_link"
      } else if (ndef != null) {
        ndef.use {
          it.connect()
          if (!it.isWritable || it.maxSize < message.toByteArray().size) throw IllegalStateException()
          if (synchronized(lock) { pending !== scan }) return
          it.writeNdefMessage(message)
        }
        value = true
      } else {
        val blank = NdefFormatable.get(tag) ?: throw IllegalStateException()
        blank.use {
          it.connect()
          if (synchronized(lock) { pending !== scan }) return
          it.format(message)
        }
        value = true
      }
    } catch (_: Exception) {
      error = if (scan.message == null) "read_failed" else "write_failed"
    }
    handler.post { finish(scan, error, value) }
  }

  private fun musicUri(uri: Uri?): Uri? {
    if (uri == null ||
      uri.scheme != "pleazyng" ||
      uri.encodedAuthority != "play" ||
      !uri.path.isNullOrEmpty() ||
      uri.fragment != null ||
      uri.toString().toByteArray().size > 2048 ||
      uri.queryParameterNames != setOf("server", "id") ||
      uri.queryParameterNames.any { uri.getQueryParameters(it).size != 1 || uri.getQueryParameter(it).isNullOrBlank() }
    ) {
      return null
    }
    return uri
  }

  private fun finish(expected: Scan?, error: String?, result: Any? = null) {
    val scan = synchronized(lock) {
      val value = pending
      if (expected != null && expected !== value) return
      pending = null
      value
    } ?: return
    handler.removeCallbacks(timeout)
    promptDialog?.dismiss()
    promptDialog = null
    activity?.let { runCatching { NfcAdapter.getDefaultAdapter(it)?.disableReaderMode(it) } }
    if (error == null) scan.result.success(result) else scan.result.error(error, null, null)
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
