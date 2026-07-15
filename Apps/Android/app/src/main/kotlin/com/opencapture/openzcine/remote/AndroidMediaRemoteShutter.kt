package com.opencapture.openzcine.remote

import android.content.Context
import android.content.Intent
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.SystemClock
import android.view.KeyEvent
import androidx.core.content.IntentCompat

/**
 * A supported media-button command received while the operator has armed the
 * monitor-only remote shutter.
 */
public enum class MediaRemoteShutterCommand {
    /** Toggle recording from standby to recording or the reverse. */
    TOGGLE,

    /** Start recording when the camera is in standby. */
    START,

    /** Stop recording when the camera is already recording. */
    STOP,
}

/**
 * Platform adapter for a monitor-only Android media remote shutter.
 *
 * Android does not report a trustworthy Bluetooth-versus-local identity for
 * every hardware event, so this accepts an explicit key allowlist while armed.
 * Generic Bluetooth shutters commonly emit volume keys, and the phone's own
 * volume buttons intentionally become shutter triggers in this monitor-only
 * state to match iOS. The backing [MediaSession] is active only while the live
 * monitor is frontmost; callers must pair [arm] with [disarm] on every
 * lifecycle or surface transition and call [close] at activity teardown.
 */
public class AndroidMediaRemoteShutter(context: Context) {
    private val controller = MediaRemoteShutterController(SystemClock::elapsedRealtime)
    private var closed: Boolean = false
    private val mediaSession: MediaSession =
        MediaSession(context.applicationContext, SESSION_TAG).apply {
            setCallback(
                object : MediaSession.Callback() {
                    override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                        val keyEvent =
                            IntentCompat.getParcelableExtra(
                                mediaButtonIntent,
                                Intent.EXTRA_KEY_EVENT,
                                KeyEvent::class.java,
                            )
                        return keyEvent?.let(::dispatchKeyEvent) ?: false
                    }
                },
            )
        }

    /** Whether the session is currently allowed to consume supported media keys. */
    public val isArmed: Boolean
        get() = controller.isArmed

    /**
     * Activates the foreground media-button route and sends accepted commands
     * to [onCommand]. Re-arming updates the callback without resetting the
     * duplicate-event debounce window.
     */
    public fun arm(onCommand: (MediaRemoteShutterCommand) -> Unit) {
        if (closed) return
        controller.arm(onCommand)
        mediaSession.setPlaybackState(armedPlaybackState())
        mediaSession.isActive = true
    }

    /**
     * Stops consuming media buttons and releases the active-session claim.
     * Safe to call repeatedly from an overlay, lifecycle, or composition
     * teardown path.
     */
    public fun disarm() {
        controller.disarm()
        if (!closed) mediaSession.isActive = false
    }

    /**
     * Gives an activity-delivered key event the same policy as an event routed
     * through the active [MediaSession]. Returns true only when this armed
     * shutter owns a supported media event.
     */
    public fun dispatchKeyEvent(event: KeyEvent): Boolean =
        !closed &&
            controller.handleKeyEvent(
                keyCode = event.keyCode,
                action = event.action,
                repeatCount = event.repeatCount,
            )

    /** Permanently releases the platform media session during activity teardown. */
    public fun close() {
        if (closed) return
        disarm()
        mediaSession.release()
        closed = true
    }

    private fun armedPlaybackState(): PlaybackState =
        PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_STOP or
                    PlaybackState.ACTION_PLAY_PAUSE,
            ).setState(
                PlaybackState.STATE_PAUSED,
                PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                0f,
            ).build()

    private companion object {
        const val SESSION_TAG = "OpenZCineMediaRemoteShutter"
    }
}

/** Pure, JVM-testable event gate shared by activity and media-session delivery. */
internal class MediaRemoteShutterController(
    private val elapsedRealtimeMillis: () -> Long,
) {
    private var onCommand: ((MediaRemoteShutterCommand) -> Unit)? = null
    private var lastAcceptedAtMillis: Long? = null

    val isArmed: Boolean
        get() = onCommand != null

    fun arm(onCommand: (MediaRemoteShutterCommand) -> Unit) {
        if (!isArmed) lastAcceptedAtMillis = null
        this.onCommand = onCommand
    }

    fun disarm() {
        onCommand = null
        lastAcceptedAtMillis = null
    }

    /**
     * Consumes a supported media key only while armed. Key-up, repeat, and
     * duplicate delivery events are consumed without issuing another command,
     * keeping a single physical button press to one camera request.
     */
    fun handleKeyEvent(keyCode: Int, action: Int, repeatCount: Int): Boolean {
        val command = MediaRemoteShutterKeyMap.commandFor(keyCode) ?: return false
        val callback = onCommand ?: return false
        if (action == KeyEvent.ACTION_UP) return true
        if (action != KeyEvent.ACTION_DOWN) return false
        if (repeatCount != 0 || isDebounced()) return true

        lastAcceptedAtMillis = elapsedRealtimeMillis()
        callback(command)
        return true
    }

    private fun isDebounced(): Boolean {
        val previous = lastAcceptedAtMillis ?: return false
        return elapsedRealtimeMillis() - previous < DEBOUNCE_MILLIS
    }

    private companion object {
        const val DEBOUNCE_MILLIS = 600L
    }
}

/** Explicit Android shutter-key allowlist used only while the monitor has armed the controller. */
internal object MediaRemoteShutterKeyMap {
    fun commandFor(keyCode: Int): MediaRemoteShutterCommand? =
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_VOLUME_UP,
            KeyEvent.KEYCODE_VOLUME_DOWN,
            -> MediaRemoteShutterCommand.TOGGLE

            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_RECORD,
            -> MediaRemoteShutterCommand.START

            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_STOP,
            -> MediaRemoteShutterCommand.STOP

            else -> null
        }
}
