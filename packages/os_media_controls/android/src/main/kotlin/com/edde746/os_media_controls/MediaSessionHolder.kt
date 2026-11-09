package com.edde746.os_media_controls

import android.support.v4.media.session.MediaSessionCompat

/**
 * Process-local bridge between the plugin (which owns the MediaSession) and
 * [MediaPlaybackService] (which renders it as a foreground notification).
 *
 * Both sides live on the main thread of the same process; `@Volatile` only
 * guards against torn reads from binder/system threads.
 */
object MediaSessionHolder {
    /** Token of the plugin's MediaSession, or null when no engine is attached. */
    @Volatile
    var sessionToken: MediaSessionCompat.Token? = null
        private set

    /** Whether the Dart side opted into background playback (audio sessions). */
    @Volatile
    var backgroundModeEnabled: Boolean = false

    /**
     * The running service instance, registered in `onCreate` and cleared in
     * `onDestroy`. Non-null is the policy's `serviceStarted` input, and it is
     * how the plugin issues promote/demote/stop transitions (direct calls —
     * no background `startService`, which API 26+ restricts).
     */
    @Volatile
    var service: MediaPlaybackService? = null

    fun setMediaSession(token: MediaSessionCompat.Token?) {
        sessionToken = token
    }
}
