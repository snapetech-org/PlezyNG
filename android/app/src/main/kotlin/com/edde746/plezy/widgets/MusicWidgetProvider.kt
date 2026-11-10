package com.edde746.plezy.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.RemoteViews
import com.edde746.os_media_controls.MusicCarApi
import com.edde746.plezy.PlezyActivity
import com.edde746.plezy.R

class MusicWidgetProvider : AppWidgetProvider() {
  companion object {
    private const val TRANSPORT = "com.edde746.plezy.MUSIC_WIDGET_TRANSPORT"
    private var attached = false

    fun attach(context: Context) {
      if (attached) return
      attached = true
      val application = context.applicationContext
      MusicCarApi.addListener { refresh(application) }
      refresh(application)
    }

    private fun refresh(context: Context) {
      val manager = AppWidgetManager.getInstance(context)
      val ids = manager.getAppWidgetIds(ComponentName(context, MusicWidgetProvider::class.java))
      val snapshot = MusicCarApi.snapshot
      val scope = snapshot["scope"] as? String
      val revision = (snapshot["revision"] as? Number)?.toLong()
      val available = MusicCarApi.ready && scope != null && revision != null && snapshot["title"] is String
      val labels = snapshot["labels"] as? Map<*, *>
      for (id in ids) {
        val views = RemoteViews(context.packageName, R.layout.music_widget)
        views.setTextViewText(R.id.music_widget_title, if (available) snapshot["title"] as String else context.applicationInfo.loadLabel(context.packageManager))
        views.setTextViewText(R.id.music_widget_artist, if (available) snapshot["artist"] as? String ?: "" else "")
        views.setViewVisibility(R.id.music_widget_transport, if (available) View.VISIBLE else View.GONE)
        val open = PendingIntent.getActivity(
          context,
          id,
          Intent(context, PlezyActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
          },
          PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(R.id.music_widget_title, open)
        views.setOnClickPendingIntent(R.id.music_widget_artist, open)
        val playing = snapshot["playing"] == true
        views.setImageViewResource(R.id.music_widget_toggle, if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play)
        if (available) {
          for ((button, command) in listOf(R.id.music_widget_previous to "previous", R.id.music_widget_toggle to if (playing) "pause" else "play", R.id.music_widget_next to "next")) {
            val intent = Intent(context, MusicWidgetProvider::class.java).apply {
              action = TRANSPORT
              data = Uri.Builder().scheme("pleazyng-widget").authority("transport").appendPath(scope).appendPath(revision.toString()).appendPath(command).build()
              putExtra("scope", scope)
              putExtra("revision", revision)
              putExtra("command", command)
            }
            views.setOnClickPendingIntent(button, PendingIntent.getBroadcast(context, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            views.setContentDescription(button, labels?.get(command) as? String ?: "")
          }
        }
        manager.updateAppWidget(id, views)
      }
    }
  }

  override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
    refresh(context)
  }

  override fun onReceive(context: Context, intent: Intent) {
    super.onReceive(context, intent)
    if (intent.action != TRANSPORT) return
    val scope = intent.getStringExtra("scope") ?: return
    val revision = intent.getLongExtra("revision", -1)
    val command = intent.getStringExtra("command") ?: return
    if (!MusicCarApi.ready || MusicCarApi.snapshot["scope"] != scope || (MusicCarApi.snapshot["revision"] as? Number)?.toLong() != revision || command !in setOf("previous", "play", "pause", "next")) {
      refresh(context)
      return
    }
    val pending = goAsync()
    val handler = Handler(Looper.getMainLooper())
    var finished = false
    fun finish() {
      if (!finished) {
        finished = true
        pending.finish()
      }
    }
    val timeout = Runnable { finish() }
    handler.postDelayed(timeout, 8000)
    MusicCarApi.request("transport", mapOf("scope" to scope, "revision" to revision, "command" to command)) {
      handler.removeCallbacks(timeout)
      refresh(context)
      finish()
    }
  }
}
