package com.edde746.os_media_controls

import android.support.v4.media.session.PlaybackStateCompat

/**
 * Pure decision table for the Android background-playback foreground service.
 *
 * Given the Dart-side opt-in ([decide]'s `backgroundModeEnabled`), the coarse
 * playback state, and whether [MediaPlaybackService] is currently running,
 * this yields the single lifecycle transition to apply. Keeping it free of
 * Android dependencies (constants only) makes the whole service lifecycle
 * unit-testable on the JVM.
 *
 * Semantics:
 * - enabled + playing  -> service started and in the foreground
 * - enabled + paused   -> service stays started but leaves the foreground,
 *                         keeping its (still updatable) notification
 * - stopped / cleared / disabled -> service stopped, notification removed
 */
object ForegroundStatePolicy {

    /** Coarse playback state, as far as service lifecycle is concerned. */
    enum class Playback { PLAYING, PAUSED, STOPPED, NONE }

    enum class Decision {
        /** Start the service; it enters the foreground in `onStartCommand`. */
        START_FOREGROUND_SERVICE,

        /**
         * (Re-)assert foreground on the already-running service. Idempotent:
         * repeating it just re-posts the current notification.
         */
        PROMOTE_TO_FOREGROUND,

        /**
         * Leave the started service running but detach from the foreground
         * (`stopForeground(STOP_FOREGROUND_DETACH)`), keeping the
         * notification alive and updatable. Idempotent.
         */
        DEMOTE_KEEP_NOTIFICATION,

        /** Stop the service and cancel its notification. */
        STOP_SERVICE_AND_CANCEL,

        /** Nothing to do. */
        NONE,
    }

    fun decide(
        backgroundModeEnabled: Boolean,
        playback: Playback,
        serviceStarted: Boolean,
    ): Decision {
        if (!backgroundModeEnabled) {
            return if (serviceStarted) Decision.STOP_SERVICE_AND_CANCEL else Decision.NONE
        }
        return when (playback) {
            Playback.PLAYING ->
                if (serviceStarted) Decision.PROMOTE_TO_FOREGROUND
                else Decision.START_FOREGROUND_SERVICE
            Playback.PAUSED ->
                // Never *start* the service for a paused session; once
                // started it keeps its notification so play can resume it.
                if (serviceStarted) Decision.DEMOTE_KEEP_NOTIFICATION
                else Decision.NONE
            Playback.STOPPED, Playback.NONE ->
                if (serviceStarted) Decision.STOP_SERVICE_AND_CANCEL
                else Decision.NONE
        }
    }

    /**
     * Maps a [PlaybackStateCompat] state constant to the policy's coarse
     * playback state. Buffering keeps audio pipelines alive, so it counts
     * as playing.
     */
    fun playbackOf(playbackStateCompatState: Int): Playback = when (playbackStateCompatState) {
        PlaybackStateCompat.STATE_PLAYING,
        PlaybackStateCompat.STATE_BUFFERING -> Playback.PLAYING
        PlaybackStateCompat.STATE_PAUSED -> Playback.PAUSED
        PlaybackStateCompat.STATE_STOPPED -> Playback.STOPPED
        else -> Playback.NONE
    }
}
