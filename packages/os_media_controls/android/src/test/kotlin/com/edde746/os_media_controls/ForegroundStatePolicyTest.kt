package com.edde746.os_media_controls

import android.support.v4.media.session.PlaybackStateCompat
import com.edde746.os_media_controls.ForegroundStatePolicy.Decision
import com.edde746.os_media_controls.ForegroundStatePolicy.Playback
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test

class ForegroundStatePolicyTest {

    private fun decide(enabled: Boolean, playback: Playback, started: Boolean): Decision =
        ForegroundStatePolicy.decide(
            backgroundModeEnabled = enabled,
            playback = playback,
            serviceStarted = started,
        )

    @Nested
    inner class BackgroundModeDisabled {
        @Test
        fun `stops a running service regardless of playback state`() {
            for (playback in Playback.values()) {
                assertEquals(
                    Decision.STOP_SERVICE_AND_CANCEL,
                    decide(enabled = false, playback = playback, started = true),
                    "disabled + $playback + started",
                )
            }
        }

        @Test
        fun `does nothing when no service is running`() {
            for (playback in Playback.values()) {
                assertEquals(
                    Decision.NONE,
                    decide(enabled = false, playback = playback, started = false),
                    "disabled + $playback + stopped",
                )
            }
        }
    }

    @Nested
    inner class BackgroundModeEnabled {
        @Test
        fun `playing starts the service when not started`() {
            assertEquals(
                Decision.START_FOREGROUND_SERVICE,
                decide(enabled = true, playback = Playback.PLAYING, started = false),
            )
        }

        @Test
        fun `playing promotes a started service to the foreground`() {
            assertEquals(
                Decision.PROMOTE_TO_FOREGROUND,
                decide(enabled = true, playback = Playback.PLAYING, started = true),
            )
        }

        @Test
        fun `paused demotes but keeps the started service and its notification`() {
            assertEquals(
                Decision.DEMOTE_KEEP_NOTIFICATION,
                decide(enabled = true, playback = Playback.PAUSED, started = true),
            )
        }

        @Test
        fun `paused never starts a service`() {
            assertEquals(
                Decision.NONE,
                decide(enabled = true, playback = Playback.PAUSED, started = false),
            )
        }

        @Test
        fun `stopped or cleared stops the service and cancels the notification`() {
            for (playback in listOf(Playback.STOPPED, Playback.NONE)) {
                assertEquals(
                    Decision.STOP_SERVICE_AND_CANCEL,
                    decide(enabled = true, playback = playback, started = true),
                    "enabled + $playback + started",
                )
                assertEquals(
                    Decision.NONE,
                    decide(enabled = true, playback = playback, started = false),
                    "enabled + $playback + stopped",
                )
            }
        }
    }

    @Nested
    inner class Idempotency {
        @Test
        fun `re-deciding after a start converges on the idempotent promote`() {
            // START flips serviceStarted to true; the follow-up decision must
            // be PROMOTE (safe to repeat), never a second START.
            assertEquals(
                Decision.START_FOREGROUND_SERVICE,
                decide(enabled = true, playback = Playback.PLAYING, started = false),
            )
            assertEquals(
                Decision.PROMOTE_TO_FOREGROUND,
                decide(enabled = true, playback = Playback.PLAYING, started = true),
            )
        }

        @Test
        fun `re-deciding after a stop is a no-op`() {
            // STOP flips serviceStarted to false; re-deciding must not issue
            // redundant stops.
            assertEquals(
                Decision.STOP_SERVICE_AND_CANCEL,
                decide(enabled = true, playback = Playback.STOPPED, started = true),
            )
            assertEquals(
                Decision.NONE,
                decide(enabled = true, playback = Playback.STOPPED, started = false),
            )
        }

        @Test
        fun `repeated pause updates keep yielding the safe demote`() {
            // DEMOTE does not change serviceStarted, so throttled repeated
            // paused states re-yield DEMOTE — which is safe to re-apply.
            repeat(3) {
                assertEquals(
                    Decision.DEMOTE_KEEP_NOTIFICATION,
                    decide(enabled = true, playback = Playback.PAUSED, started = true),
                )
            }
        }
    }

    /**
     * Task-removal teardown: `onTaskRemoved` flips backgroundModeEnabled to
     * false *before* stopping the service, because playback-state updates
     * from the Dart side keep arriving until the engine detaches. Without
     * the flip, a throttled "playing" update would see serviceStarted=false
     * and restart the service - and a revived instance can be denied
     * startForeground (background FGS-start restrictions), stranding
     * whatever it posts past the hard process kill (which skips onDestroy).
     */
    @Nested
    inner class TaskRemovalTeardown {
        @Test
        fun `after task removal racing playback updates never restart the service`() {
            for (playback in Playback.values()) {
                assertEquals(
                    Decision.NONE,
                    decide(enabled = false, playback = playback, started = false),
                    "post-task-removal + $playback",
                )
            }
        }

        @Test
        fun `an instance revived by a stale start intent is stopped and cancelled`() {
            for (playback in Playback.values()) {
                assertEquals(
                    Decision.STOP_SERVICE_AND_CANCEL,
                    decide(enabled = false, playback = playback, started = true),
                    "post-task-removal revived + $playback",
                )
            }
        }
    }

    @Nested
    inner class PlaybackMapping {
        @Test
        fun `maps PlaybackStateCompat states to coarse playback states`() {
            assertEquals(Playback.PLAYING, ForegroundStatePolicy.playbackOf(PlaybackStateCompat.STATE_PLAYING))
            assertEquals(Playback.PLAYING, ForegroundStatePolicy.playbackOf(PlaybackStateCompat.STATE_BUFFERING))
            assertEquals(Playback.PAUSED, ForegroundStatePolicy.playbackOf(PlaybackStateCompat.STATE_PAUSED))
            assertEquals(Playback.STOPPED, ForegroundStatePolicy.playbackOf(PlaybackStateCompat.STATE_STOPPED))
            assertEquals(Playback.NONE, ForegroundStatePolicy.playbackOf(PlaybackStateCompat.STATE_NONE))
            assertEquals(Playback.NONE, ForegroundStatePolicy.playbackOf(PlaybackStateCompat.STATE_ERROR))
        }
    }
}
