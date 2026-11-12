package com.edde746.plezy.music

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.cast.MediaQueueItem
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Rearms only the acknowledged, paused item. Never loads media or starts playback. */
class CastMusicQueuePlugin :
  FlutterPlugin,
  MethodChannel.MethodCallHandler {
  private val handler = Handler(Looper.getMainLooper())
  private var context: Context? = null
  private var channel: MethodChannel? = null
  private var pending: ((Boolean) -> Unit)? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "com.pleazyng/cast_music_queue").also { it.setMethodCallHandler(this) }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = null
    pending?.invoke(false)
    channel?.setMethodCallHandler(null)
    channel = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "armRepeat") {
      result.notImplemented()
      return
    }
    val appContext = context
    val sessionId = call.argument<String>("session")
    val device = call.argument<String>("device")
    val mediaSession = call.argument<Number>("mediaSession")?.toLong()
    val itemId = call.argument<Number>("item")?.toInt()
    val token = call.argument<String>("token")
    val occurrence = call.argument<String>("occurrence")
    val contentId = call.argument<String>("contentId")
    val repeat = when (call.argument<String>("repeat")) {
      "SINGLE" -> MediaStatus.REPEAT_MODE_REPEAT_SINGLE
      "ALL" -> MediaStatus.REPEAT_MODE_REPEAT_ALL
      else -> null
    }
    if (pending != null ||
      appContext == null ||
      sessionId.isNullOrEmpty() ||
      device.isNullOrEmpty() ||
      mediaSession == null ||
      mediaSession <= 0 ||
      itemId == null ||
      itemId <= 0 ||
      token.isNullOrEmpty() ||
      token.length > 128 ||
      occurrence.isNullOrEmpty() ||
      contentId != "pleazyng:$token:$occurrence" ||
      repeat == null
    ) {
      result.success(false)
      return
    }
    try {
      val cast = CastContext.getSharedInstance(appContext)
      val session = cast.sessionManager.currentCastSession
      val remote = session?.remoteMediaClient
      fun owned(): Boolean {
        if (context == null ||
          session == null ||
          remote == null ||
          cast.sessionManager.currentCastSession !== session ||
          !session.isConnected ||
          session.sessionId != sessionId ||
          session.castDevice?.deviceId != device
        ) {
          return false
        }
        val status = remote.mediaStatus ?: return false
        val media = status.mediaInfo ?: return false
        return status.toJson().optLong("mediaSessionId") == mediaSession &&
          status.currentItemId == itemId &&
          status.playerState == MediaStatus.PLAYER_STATE_PAUSED &&
          status.queueRepeatMode == repeat &&
          media.contentId == contentId &&
          media.customData?.optString("pleazyngOwner") == token &&
          media.customData?.optString("pleazyngOccurrence") == occurrence
      }
      if (!owned()) {
        result.success(false)
        return
      }
      val item = remote?.mediaStatus?.getQueueItemById(itemId)
      val media = item?.media
      if (item == null ||
        media?.contentId != contentId ||
        media.customData?.optString("pleazyngOwner") != token ||
        media.customData?.optString("pleazyngOccurrence") != occurrence
      ) {
        result.success(false)
        return
      }
      lateinit var finish: (Boolean) -> Unit
      val timeout = Runnable { pending?.takeIf { it === finish }?.invoke(false) }
      finish = { success ->
        if (pending === finish) {
          pending = null
          handler.removeCallbacks(timeout)
          result.success(success && owned() && remote.mediaStatus?.getQueueItemById(itemId)?.autoplay == true)
        }
      }
      pending = finish
      handler.postDelayed(timeout, 8000)
      try {
        remote.queueUpdateItems(arrayOf(MediaQueueItem.Builder(item).setAutoplay(true).build()), null)
          .setResultCallback { finish(it.status.isSuccess) }
      } catch (_: Exception) {
        finish(false)
      }
    } catch (_: Exception) {
      result.success(false)
    }
  }
}
