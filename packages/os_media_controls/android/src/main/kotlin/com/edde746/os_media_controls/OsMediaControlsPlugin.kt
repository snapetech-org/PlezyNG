package com.edde746.os_media_controls

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** OsMediaControlsPlugin */
class OsMediaControlsPlugin: FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val MAX_ARTWORK_DIMENSION = 512
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    private lateinit var mediaSession: MediaSessionCompat

    private var currentState: Int = PlaybackStateCompat.STATE_NONE
    private var currentPosition: Long = 0
    private var currentSpeed: Float = 1.0f
    private val enabledControls = mutableSetOf(
        "play",
        "pause",
        "stop",
        "next",
        "previous",
        "seek",
        "skipForward",
        "skipBackward",
        "changeSpeed"
    )

    // Audio becoming noisy (headphone/Bluetooth disconnect) handling
    private var noisyAudioReceiver: BroadcastReceiver? = null
    private var isNoisyReceiverRegistered = false

    // Artwork URL download machinery: a single background thread with a
    // 1-entry decoded-bitmap cache (repeat metadata updates for the same
    // item are free).
    private val mainHandler = Handler(Looper.getMainLooper())
    private var artworkExecutor: ExecutorService? = null
    private var latestArtworkUrl: String? = null
    private var cachedArtworkUrl: String? = null
    private var cachedArtworkBitmap: Bitmap? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(
            binding.binaryMessenger,
            "com.edde746.os_media_controls/methods"
        )
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(
            binding.binaryMessenger,
            "com.edde746.os_media_controls/events"
        )
        eventChannel.setStreamHandler(this)

        MusicCarApi.attach(binding.binaryMessenger)
        setupMediaSession()
        MediaSessionHolder.setMediaSession(mediaSession.sessionToken)
    }

    private fun setupMediaSession() {
        mediaSession = MediaSessionCompat(context, "OsMediaControls").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlayFromMediaId(mediaId: String?, extras: android.os.Bundle?) {
                    if (mediaId != null) MusicCarApi.request("playItem", mapOf("id" to mediaId)) { }
                }

                override fun onPlayFromSearch(query: String?, extras: android.os.Bundle?) {
                    if (!query.isNullOrBlank()) MusicCarApi.request("playSearch", mapOf("query" to query)) { }
                }

                override fun onSkipToQueueItem(id: Long) {
                    MusicCarApi.request("jump", mapOf("index" to id, "revision" to MusicCarApi.snapshot["revision"])) { }
                }

                override fun onPlay() {
                    sendSessionEvent(mapOf("type" to "play"))
                }

                override fun onPause() {
                    sendSessionEvent(mapOf("type" to "pause"))
                }

                override fun onStop() {
                    sendSessionEvent(mapOf("type" to "stop"))
                }

                override fun onSkipToNext() {
                    sendSessionEvent(mapOf("type" to "next"))
                }

                override fun onSkipToPrevious() {
                    sendSessionEvent(mapOf("type" to "previous"))
                }

                override fun onSeekTo(position: Long) {
                    sendSessionEvent(mapOf(
                        "type" to "seek",
                        "position" to position / 1000.0 // Convert to seconds
                    ))
                }

                override fun onSetPlaybackSpeed(speed: Float) {
                    sendSessionEvent(mapOf(
                        "type" to "setSpeed",
                        "speed" to speed.toDouble()
                    ))
                }

                override fun onFastForward() {
                    sendSessionEvent(mapOf(
                        "type" to "skipForward",
                        "interval" to 15.0
                    ))
                }

                override fun onRewind() {
                    sendSessionEvent(mapOf(
                        "type" to "skipBackward",
                        "interval" to 15.0
                    ))
                }
            })

            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            isActive = false
        }
    }

    private fun createNoisyAudioReceiver(): BroadcastReceiver {
        return object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    // Only send pause if currently playing
                    if (currentState == PlaybackStateCompat.STATE_PLAYING) {
                        sendEvent(mapOf("type" to "pause"))
                    }
                }
            }
        }
    }

    private fun registerNoisyAudioReceiver() {
        if (isNoisyReceiverRegistered) return
        // Android TV outputs audio over HDMI. ACTION_AUDIO_BECOMING_NOISY fires
        // spuriously during HDMI renegotiation (e.g. frame rate matching) and is
        // not meaningful for the TV form factor.
        if (context.packageManager.hasSystemFeature("android.software.leanback")) return

        noisyAudioReceiver = createNoisyAudioReceiver()
        val intentFilter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(
                noisyAudioReceiver,
                intentFilter,
                Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            context.registerReceiver(noisyAudioReceiver, intentFilter)
        }
        isNoisyReceiverRegistered = true
    }

    private fun unregisterNoisyAudioReceiver() {
        if (!isNoisyReceiverRegistered || noisyAudioReceiver == null) return

        try {
            context.unregisterReceiver(noisyAudioReceiver)
        } catch (e: IllegalArgumentException) {
            // Receiver not registered, ignore
        }
        isNoisyReceiverRegistered = false
        noisyAudioReceiver = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setMetadata" -> {
                setMetadata(call.arguments as? Map<String, Any>)
                result.success(null)
            }
            "setPlaybackState" -> {
                setPlaybackState(call.arguments as? Map<String, Any>)
                result.success(null)
            }
            "enableControls" -> {
                updateEnabledControls(call.arguments, true)
                result.success(null)
            }
            "disableControls" -> {
                updateEnabledControls(call.arguments, false)
                result.success(null)
            }
            "setSkipIntervals" -> {
                // Android doesn't support custom skip intervals directly
                // Fast forward/rewind callbacks are used instead
                result.success(null)
            }
            "setQueueInfo" -> {
                // Android doesn't display queue info in the same way as iOS/macOS
                // Could be added to metadata as custom fields if needed
                result.success(null)
            }
            "setBackgroundMode" -> {
                setBackgroundMode(call.arguments as? Map<String, Any>)
                result.success(null)
            }
            "clear" -> {
                clear()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun setMetadata(arguments: Map<String, Any>?) {
        arguments ?: return
        mediaSession.isActive = true

        val builder = MediaMetadataCompat.Builder()

        arguments["title"]?.let {
            builder.putString(MediaMetadataCompat.METADATA_KEY_TITLE, it as String)
        }
        arguments["artist"]?.let {
            builder.putString(MediaMetadataCompat.METADATA_KEY_ARTIST, it as String)
        }
        arguments["album"]?.let {
            builder.putString(MediaMetadataCompat.METADATA_KEY_ALBUM, it as String)
        }
        arguments["albumArtist"]?.let {
            builder.putString(MediaMetadataCompat.METADATA_KEY_ALBUM_ARTIST, it as String)
        }
        arguments["duration"]?.let {
            val durationSeconds = (it as Number).toDouble()
            builder.putLong(
                MediaMetadataCompat.METADATA_KEY_DURATION,
                (durationSeconds * 1000).toLong() // Convert to milliseconds
            )
        }
        var artworkApplied = false
        arguments["artwork"]?.let {
            try {
                val bytes = it as ByteArray
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                if (bitmap != null) {
                    // Downsample if too large to avoid memory issues
                    val scaledBitmap = if (bitmap.width > 1024 || bitmap.height > 1024) {
                        Bitmap.createScaledBitmap(bitmap, 1024, 1024, true)
                    } else {
                        bitmap
                    }
                    builder.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, scaledBitmap)
                    builder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, scaledBitmap)
                    artworkApplied = true
                }
            } catch (e: Exception) {
                // Ignore artwork errors
            }
        }

        // Fall back to the artwork URL: raw bytes take precedence, matching
        // the iOS/macOS implementations.
        val artworkUrl = if (artworkApplied) null else arguments["artworkUrl"] as? String
        latestArtworkUrl = artworkUrl
        if (artworkUrl != null) {
            val cached = cachedArtworkBitmap
            if (artworkUrl == cachedArtworkUrl && cached != null) {
                builder.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, cached)
                builder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, cached)
            } else {
                fetchArtwork(artworkUrl)
            }
        }

        mediaSession.setMetadata(builder.build())
    }

    /**
     * Downloads and downsamples artwork off the main thread, then merges it
     * into the session metadata — unless a newer setMetadata call changed
     * the wanted artwork in the meantime.
     */
    private fun fetchArtwork(url: String) {
        val executor = artworkExecutor ?: Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "OsMediaControlsArtwork").apply { isDaemon = true }
        }.also { artworkExecutor = it }

        executor.execute {
            val bitmap = downloadArtwork(url) ?: return@execute
            mainHandler.post {
                if (!::mediaSession.isInitialized || latestArtworkUrl != url) return@post
                cachedArtworkUrl = url
                cachedArtworkBitmap = bitmap
                val current = mediaSession.controller.metadata ?: MediaMetadataCompat.Builder().build()
                val updated = MediaMetadataCompat.Builder(current)
                    .putBitmap(MediaMetadataCompat.METADATA_KEY_ART, bitmap)
                    .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bitmap)
                    .build()
                mediaSession.setMetadata(updated)
            }
        }
    }

    private fun downloadArtwork(url: String): Bitmap? {
        return try {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            connection.instanceFollowRedirects = true
            try {
                val bytes = connection.inputStream.use { it.readBytes() }
                decodeDownsampled(bytes, MAX_ARTWORK_DIMENSION)
            } finally {
                connection.disconnect()
            }
        } catch (e: Exception) {
            null // Artwork is best-effort; the notification/session works without it.
        }
    }

    private fun decodeDownsampled(bytes: ByteArray, maxDimension: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sampleSize = 1
        while (bounds.outWidth / (sampleSize * 2) >= maxDimension &&
            bounds.outHeight / (sampleSize * 2) >= maxDimension
        ) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }

    private fun setPlaybackState(arguments: Map<String, Any>?) {
        arguments ?: return

        val stateString = arguments["state"] as? String ?: "none"
        val positionSeconds = (arguments["position"] as? Number)?.toDouble() ?: 0.0
        val speed = (arguments["speed"] as? Number)?.toFloat() ?: 1.0f

        val previousState = currentState

        currentState = when (stateString) {
            "playing" -> PlaybackStateCompat.STATE_PLAYING
            "paused" -> PlaybackStateCompat.STATE_PAUSED
            "stopped" -> PlaybackStateCompat.STATE_STOPPED
            "buffering" -> PlaybackStateCompat.STATE_BUFFERING
            else -> PlaybackStateCompat.STATE_NONE
        }

        mediaSession.isActive = currentState != PlaybackStateCompat.STATE_NONE

        // Manage noisy audio receiver based on playback state
        if (currentState == PlaybackStateCompat.STATE_PLAYING) {
            registerNoisyAudioReceiver()
        } else if (previousState == PlaybackStateCompat.STATE_PLAYING) {
            // Unregister when transitioning away from playing
            unregisterNoisyAudioReceiver()
        }

        currentPosition = (positionSeconds * 1000).toLong() // Convert to milliseconds
        currentSpeed = speed

        updatePlaybackState()
        applyForegroundPolicy()
    }

    /**
     * Opt in/out of Android background playback. While enabled, playback
     * state drives [MediaPlaybackService] via [ForegroundStatePolicy] so
     * audio keeps running when the app is backgrounded and the session gets
     * a MediaStyle notification. Sessions that never enable it (e.g. video)
     * behave exactly as before.
     */
    private fun setBackgroundMode(arguments: Map<String, Any>?) {
        val enabled = arguments?.get("enabled") as? Boolean ?: false
        MediaSessionHolder.backgroundModeEnabled = enabled
        applyForegroundPolicy()
    }

    private fun applyForegroundPolicy() {
        val decision = ForegroundStatePolicy.decide(
            backgroundModeEnabled = MediaSessionHolder.backgroundModeEnabled,
            playback = ForegroundStatePolicy.playbackOf(currentState),
            serviceStarted = MediaSessionHolder.service != null,
        )
        when (decision) {
            ForegroundStatePolicy.Decision.START_FOREGROUND_SERVICE -> {
                val intent = Intent(context, MediaPlaybackService::class.java)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                } catch (e: Exception) {
                    // Background-start restrictions: playback continues
                    // in-process; the next playing state update retries.
                }
            }
            ForegroundStatePolicy.Decision.PROMOTE_TO_FOREGROUND ->
                MediaSessionHolder.service?.promoteToForeground()
            ForegroundStatePolicy.Decision.DEMOTE_KEEP_NOTIFICATION ->
                MediaSessionHolder.service?.demoteKeepNotification()
            ForegroundStatePolicy.Decision.STOP_SERVICE_AND_CANCEL ->
                MediaSessionHolder.service?.stopAndCancel()
            ForegroundStatePolicy.Decision.NONE -> {}
        }
    }

    private fun updateEnabledControls(arguments: Any?, enabled: Boolean) {
        val controls = arguments as? List<*> ?: return

        controls.forEach { control ->
            val controlName = control as? String ?: return@forEach
            if (enabled) {
                enabledControls.add(controlName)
            } else {
                enabledControls.remove(controlName)
            }
        }

        if (::mediaSession.isInitialized) {
            updatePlaybackState()
        }
    }

    private fun updatePlaybackState() {
        val playbackState = PlaybackStateCompat.Builder()
            .setState(currentState, currentPosition, currentSpeed)
            .setActions(buildPlaybackActions())
            .build()

        mediaSession.setPlaybackState(playbackState)
    }

    private fun buildPlaybackActions(): Long {
        var actions = PlaybackStateCompat.ACTION_PLAY_FROM_MEDIA_ID or PlaybackStateCompat.ACTION_PLAY_FROM_SEARCH

        if (enabledControls.contains("play")) {
            actions = actions or PlaybackStateCompat.ACTION_PLAY
        }
        if (enabledControls.contains("pause")) {
            actions = actions or PlaybackStateCompat.ACTION_PAUSE
        }
        if (enabledControls.contains("play") && enabledControls.contains("pause")) {
            actions = actions or PlaybackStateCompat.ACTION_PLAY_PAUSE
        }
        if (enabledControls.contains("stop")) {
            actions = actions or PlaybackStateCompat.ACTION_STOP
        }
        if (enabledControls.contains("next")) {
            actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
        }
        if (enabledControls.contains("previous")) {
            actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
        }
        if (enabledControls.contains("seek")) {
            actions = actions or PlaybackStateCompat.ACTION_SEEK_TO
        }
        if (enabledControls.contains("changeSpeed")) {
            actions = actions or PlaybackStateCompat.ACTION_SET_PLAYBACK_SPEED
        }
        if (enabledControls.contains("skipForward")) {
            actions = actions or PlaybackStateCompat.ACTION_FAST_FORWARD
        }
        if (enabledControls.contains("skipBackward")) {
            actions = actions or PlaybackStateCompat.ACTION_REWIND
        }

        return actions
    }

    private fun clear() {
        unregisterNoisyAudioReceiver()
        currentState = PlaybackStateCompat.STATE_NONE
        latestArtworkUrl = null
        mediaSession.setMetadata(null)
        val playbackState = PlaybackStateCompat.Builder()
            .setState(PlaybackStateCompat.STATE_NONE, 0, 0.0f)
            .setActions(0)
            .build()
        mediaSession.setPlaybackState(playbackState)
        mediaSession.isActive = false
        applyForegroundPolicy()
    }

    private fun sendSessionEvent(event: Map<String, Any>) {
        if (!mediaSession.isActive) return
        sendEvent(event)
    }

    private fun sendEvent(event: Map<String, Any>) {
        eventSink?.success(event)
    }

    // EventChannel.StreamHandler

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Never leak a silent notification or a headless service past the
        // engine's lifetime.
        MusicCarApi.detach()
        MediaSessionHolder.backgroundModeEnabled = false
        MediaSessionHolder.service?.stopAndCancel()
        MediaSessionHolder.setMediaSession(null)
        artworkExecutor?.shutdownNow()
        artworkExecutor = null
        latestArtworkUrl = null
        unregisterNoisyAudioReceiver()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        mediaSession.release()
    }
}
