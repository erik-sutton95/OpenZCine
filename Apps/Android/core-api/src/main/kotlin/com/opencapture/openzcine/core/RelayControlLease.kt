package com.opencapture.openzcine.core

/**
 * Keeps a watcher's camera control alive across a brief disconnection.
 *
 * Twin of the shared Swift core's `RelayControlLease`, checked against the same table.
 *
 * A held control token used to die with the socket. On a congested set that is wrong: a watcher
 * whose link blinks loses the camera mid-take and has to ask for it back, and the operator has to
 * notice and grant it again — for an outage neither of them saw. The token belongs to a PERSON
 * holding a device, not to a TCP connection.
 *
 * It cannot be keyed on the connection, for the same reason it exists: the returning watcher
 * arrives on a new socket. The hello's stable per-install `watcherId` is what the lease
 * recognises. Anything weaker — a device name, an address — could hand camera control to the
 * wrong person, and this is a token that presses record.
 *
 * Not thread-safe by itself; the host owns it under its own mutex.
 */
public class RelayControlLease(
    /**
     * How long a dropped holder keeps its claim.
     *
     * Twenty seconds, and it has to outlast the watcher's OWN idea of having dropped or it could
     * never be used: a stalled viewer session is not declared dead for 8 s, and only then does a
     * 3 s rejoin tick fire and have to re-find the broadcast. Short enough that a watcher who has
     * genuinely walked away is not still holding the camera a minute later — and the operator
     * never waits it out regardless, because reclaiming is always immediate.
     */
    public val windowMillis: Long = DEFAULT_WINDOW_MILLIS,
) {
    private var parkedWatcherId: String? = null
    private var parkedUntilMillis: Long = 0

    /** Whether a dropped holder is still owed its claim as of [nowMillis]. */
    public fun isParked(nowMillis: Long): Boolean =
        parkedWatcherId != null && nowMillis < parkedUntilMillis

    /** The watcher a resumed claim would belong to, while one is owed. */
    public fun parkedWatcherId(nowMillis: Long): String? =
        if (isParked(nowMillis)) parkedWatcherId else null

    /**
     * The holder dropped. A claim is only parked for a watcher we can RECOGNISE on return — an
     * anonymous watcher (one from before the field existed) releases immediately, exactly as it
     * always did, rather than freezing the camera for a device that can never be matched.
     */
    public fun park(watcherId: String?, nowMillis: Long): Boolean {
        if (watcherId.isNullOrEmpty()) {
            clear()
            return false
        }
        parkedWatcherId = watcherId
        parkedUntilMillis = nowMillis + windowMillis
        return true
    }

    /** Whether this hello is the parked watcher coming back, in which case the claim resumes. */
    public fun claim(watcherId: String?, nowMillis: Long): Boolean {
        if (watcherId.isNullOrEmpty()) return false
        if (!isParked(nowMillis) || parkedWatcherId != watcherId) return false
        clear()
        return true
    }

    /**
     * Drops the claim outright — the operator reclaiming, the watcher releasing deliberately, or
     * the window running out. Deliberate release is not a disconnection and gets no grace.
     */
    public fun clear() {
        parkedWatcherId = null
        parkedUntilMillis = 0
    }

    public companion object {
        public const val DEFAULT_WINDOW_MILLIS: Long = 20_000
    }
}
