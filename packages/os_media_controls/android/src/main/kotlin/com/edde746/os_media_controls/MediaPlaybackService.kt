package com.edde746.os_media_controls

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.os.Build
import android.os.IBinder
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.view.KeyEvent
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps audio playback alive while the app is
 * backgrounded (Android's cached-app freezer would otherwise suspend it) and
 * renders the plugin's MediaSession as a MediaStyle notification.
 *
 * The service owns no playback state of its own: everything in the
 * notification is read from the session (via [MediaSessionHolder.sessionToken])
 * through a [MediaControllerCompat], and a controller callback refreshes the
 * notification on every state/metadata change — so plugin-side updates
 * (including asynchronously downloaded artwork) propagate automatically.
 *
 * Lifecycle transitions are decided by [ForegroundStatePolicy]. The plugin
 * starts the service with `startForegroundService` and afterwards calls
 * [promoteToForeground] / [demoteKeepNotification] / [stopAndCancel] directly
 * on the instance (same process, main thread).
 */
class MediaPlaybackService : Service() {

    companion object {
        const val NOTIFICATION_CHANNEL_ID = "media_playback"
        const val NOTIFICATION_ID = 0x6D6470 // "mdp"

        /** Delete-intent action: the user dismissed the (paused) notification. */
        private const val ACTION_STOP_SERVICE =
            "com.edde746.os_media_controls.action.STOP_SERVICE"
    }

    private var controller: MediaControllerCompat? = null
    private var stopped = false

    /**
     * Whether this instance ever managed to show its notification (via
     * startForeground or notify). Gates the promote fallback in
     * [promoteToForeground]: an instance that has never shown anything must
     * not notify() its way into an orphan.
     */
    private var hasShownNotification = false

    private val controllerCallback = object : MediaControllerCompat.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackStateCompat?) = refreshNotification()

        override fun onMetadataChanged(metadata: MediaMetadataCompat?) = refreshNotification()

        override fun onSessionDestroyed() = stopAndCancel()
    }

    private val notificationManager: NotificationManager
        get() = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    override fun onCreate() {
        super.onCreate()
        MediaSessionHolder.service = this
        createNotificationChannel()
        MediaSessionHolder.sessionToken?.let { token ->
            controller = MediaControllerCompat(this, token).also {
                it.registerCallback(controllerCallback)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_SERVICE) {
            stopAndCancel()
            return START_NOT_STICKY
        }

        // Always enter the foreground first: when launched via
        // startForegroundService the system *requires* a startForeground call,
        // and it is harmless when started from a notification action.
        promoteToForeground()

        if (controller == null) {
            // No live session (e.g. a stale notification outlived the app
            // process and its action restarted us) — nothing to control.
            stopAndCancel()
            return START_NOT_STICKY
        }

        // Notification transport actions arrive as media-button intents and
        // are routed into the session (-> plugin callback -> Dart event).
        keyEventFrom(intent)?.let { controller?.dispatchMediaButtonEvent(it) }

        // Converge with the policy: a pause/stop/disable may have raced the
        // asynchronous service start.
        applyPolicy()
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The user swiped the app away: never leave an orphaned notification
        // or a headless playback service behind. Drop the opt-in *before*
        // stopping so throttled "playing" updates racing the engine teardown
        // cannot restart the service — a revived instance may be denied
        // startForeground (background FGS-start restrictions) and anything it
        // posts would outlive the imminent hard process kill (which skips
        // onDestroy) as an uncancellable orphan. The Dart side re-asserts the
        // opt-in on the next track open, so a surviving session self-heals.
        MediaSessionHolder.backgroundModeEnabled = false
        stopAndCancel()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        controller?.unregisterCallback(controllerCallback)
        controller = null
        // Belt and braces: no graceful destroy path may leave the
        // notification behind — a dead service cannot keep it updated, and a
        // demote-detached notification is not removed by service teardown.
        notificationManager.cancel(NOTIFICATION_ID)
        if (MediaSessionHolder.service === this) {
            MediaSessionHolder.service = null
        }
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // Policy transitions (called by the plugin and onStartCommand)
    // ------------------------------------------------------------------

    /** [ForegroundStatePolicy.Decision.PROMOTE_TO_FOREGROUND]: idempotent. */
    fun promoteToForeground() {
        if (stopped) return
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            hasShownNotification = true
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException and friends.
            if (hasShownNotification) {
                // A previously shown (now demoted) notification stays
                // visible and updatable; the next allowed playing state
                // re-promotes.
                notificationManager.notify(NOTIFICATION_ID, notification)
            } else {
                // This instance has never shown anything and cannot enter
                // the foreground (e.g. revived while the app is background).
                // A notify()-posted notification here is not tied to the
                // service and would survive a hard process kill as an orphan
                // nothing can update or cancel — shut down instead.
                stopAndCancel()
            }
        }
    }

    /**
     * [ForegroundStatePolicy.Decision.DEMOTE_KEEP_NOTIFICATION]: leave the
     * foreground but keep the service started and the notification alive
     * (updatable and now dismissible). Idempotent.
     */
    fun demoteKeepNotification() {
        if (stopped) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(false)
        }
        // Re-post so the action row flips to "play" and ongoing is dropped.
        refreshNotification()
    }

    /** [ForegroundStatePolicy.Decision.STOP_SERVICE_AND_CANCEL]. */
    fun stopAndCancel() {
        if (stopped) return
        stopped = true
        // Unregister before touching the notification so no queued controller
        // callback can re-post after the cancel below (onDestroy repeats the
        // unregister harmlessly).
        controller?.unregisterCallback(controllerCallback)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        notificationManager.cancel(NOTIFICATION_ID)
        stopSelf()
    }

    private fun applyPolicy() {
        val state = controller?.playbackState?.state ?: PlaybackStateCompat.STATE_NONE
        val decision = ForegroundStatePolicy.decide(
            backgroundModeEnabled = MediaSessionHolder.backgroundModeEnabled,
            playback = ForegroundStatePolicy.playbackOf(state),
            serviceStarted = true,
        )
        when (decision) {
            ForegroundStatePolicy.Decision.START_FOREGROUND_SERVICE,
            ForegroundStatePolicy.Decision.PROMOTE_TO_FOREGROUND -> promoteToForeground()
            ForegroundStatePolicy.Decision.DEMOTE_KEEP_NOTIFICATION -> demoteKeepNotification()
            ForegroundStatePolicy.Decision.STOP_SERVICE_AND_CANCEL -> stopAndCancel()
            ForegroundStatePolicy.Decision.NONE -> {}
        }
    }

    // ------------------------------------------------------------------
    // Notification
    // ------------------------------------------------------------------

    private fun refreshNotification() {
        if (stopped) return
        notificationManager.notify(NOTIFICATION_ID, buildNotification())
        hasShownNotification = true
    }

    private fun buildNotification(): Notification {
        val metadata = controller?.metadata
        val playbackState = controller?.playbackState
        val actions = playbackState?.actions ?: 0L
        val isPlaying = playbackState?.state == PlaybackStateCompat.STATE_PLAYING ||
            playbackState?.state == PlaybackStateCompat.STATE_BUFFERING

        val artwork: Bitmap? = metadata?.getBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART)
            ?: metadata?.getBitmap(MediaMetadataCompat.METADATA_KEY_ART)

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(smallIconRes())
            .setContentTitle(metadata?.getString(MediaMetadataCompat.METADATA_KEY_TITLE) ?: "")
            .setContentText(metadata?.getString(MediaMetadataCompat.METADATA_KEY_ARTIST) ?: "")
            .setSubText(metadata?.getString(MediaMetadataCompat.METADATA_KEY_ALBUM))
            .setLargeIcon(artwork)
            .setContentIntent(launchPendingIntent())
            .setDeleteIntent(stopServicePendingIntent())
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(isPlaying)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)

        // Action row: previous / play-pause / next, only those the session
        // has enabled; all of them fit the compact (collapsed) view.
        var index = 0
        val compactIndices = ArrayList<Int>(3)
        if (actions and PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS != 0L) {
            builder.addAction(
                android.R.drawable.ic_media_previous,
                "Previous",
                mediaButtonPendingIntent(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            )
            compactIndices.add(index++)
        }
        val playPauseMask = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE
        if (actions and playPauseMask != 0L) {
            if (isPlaying) {
                builder.addAction(
                    android.R.drawable.ic_media_pause,
                    "Pause",
                    mediaButtonPendingIntent(KeyEvent.KEYCODE_MEDIA_PAUSE)
                )
            } else {
                builder.addAction(
                    android.R.drawable.ic_media_play,
                    "Play",
                    mediaButtonPendingIntent(KeyEvent.KEYCODE_MEDIA_PLAY)
                )
            }
            compactIndices.add(index++)
        }
        if (actions and PlaybackStateCompat.ACTION_SKIP_TO_NEXT != 0L) {
            builder.addAction(
                android.R.drawable.ic_media_next,
                "Next",
                mediaButtonPendingIntent(KeyEvent.KEYCODE_MEDIA_NEXT)
            )
            compactIndices.add(index++)
        }

        val style = androidx.media.app.NotificationCompat.MediaStyle()
            .setMediaSession(MediaSessionHolder.sessionToken)
            .setShowActionsInCompactView(*compactIndices.toIntArray())
        builder.setStyle(style)

        return builder.build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Media playback",
            NotificationManager.IMPORTANCE_LOW // no sound, no heads-up
        ).apply {
            description = "Playback controls for the currently playing media"
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        notificationManager.createNotificationChannel(channel)
    }

    /**
     * Apps can override the status-bar icon by shipping a drawable named
     * `os_media_controls_notification_icon`; otherwise the launcher icon is
     * used, with a framework glyph as last resort.
     */
    private fun smallIconRes(): Int {
        val custom = resources.getIdentifier(
            "os_media_controls_notification_icon", "drawable", packageName
        )
        if (custom != 0) return custom
        val appIcon = applicationInfo.icon
        return if (appIcon != 0) appIcon else android.R.drawable.ic_media_play
    }

    private fun launchPendingIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun mediaButtonPendingIntent(keyCode: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            setClass(this@MediaPlaybackService, MediaPlaybackService::class.java)
            putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        }
        // Request code = key code, so the three actions get distinct intents.
        return PendingIntent.getService(
            this,
            keyCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun stopServicePendingIntent(): PendingIntent {
        val intent = Intent(ACTION_STOP_SERVICE).apply {
            setClass(this@MediaPlaybackService, MediaPlaybackService::class.java)
        }
        return PendingIntent.getService(
            this,
            1,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun keyEventFrom(intent: Intent?): KeyEvent? {
        if (intent?.action != Intent.ACTION_MEDIA_BUTTON) return null
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
        }
    }
}
