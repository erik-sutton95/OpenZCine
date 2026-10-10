package com.opencapture.openzcine.core

/** Compatibility spelling over the actual shared parked control owner. */
public class RelayControlLease(public val windowMillis: Long = DEFAULT_WINDOW_MILLIS) {
    private val owner: com.opencapture.opencine.relay.RelayParkedControlLease =
        com.opencapture.opencine.relay.RelayParkedControlLease(windowMillis)
    public fun isParked(nowMillis: Long): Boolean = owner.isParked(nowMillis)
    public fun parkedWatcherId(nowMillis: Long): String? = owner.parkedWatcherID(nowMillis)
    public fun park(watcherId: String?, nowMillis: Long): Boolean = owner.park(watcherId, nowMillis)
    public fun claim(watcherId: String?, nowMillis: Long): Boolean = owner.claim(watcherId, nowMillis)
    public fun clear(): Unit = owner.clear()
    public companion object {
        public const val DEFAULT_WINDOW_MILLIS: Long = com.opencapture.opencine.relay.RelayParkedControlLease.DEFAULT_WINDOW_MILLIS
    }
}
