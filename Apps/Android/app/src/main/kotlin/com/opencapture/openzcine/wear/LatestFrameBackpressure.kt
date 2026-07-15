package com.opencapture.openzcine.wear

/**
 * A bounded in-flight latest-wins pump.
 *
 * It admits at most [maximumInFlight] dispatched items and one replacement
 * item. The caller must invoke [complete] exactly once after each dispatch
 * finishes; there is never an unbounded frame queue behind a slow Wear Data
 * Layer link.
 */
internal class LatestFrameBackpressure<Value : Any>(
    private val maximumInFlight: Int = 1,
    private val dispatch: (Dispatch<Value>) -> Unit,
    private val onDiscard: (Value) -> Unit = {},
) {
    init {
        require(maximumInFlight > 0) { "maximumInFlight must be positive." }
    }

    /** One generation-scoped frame admission. */
    internal data class Dispatch<Value : Any>(
        val value: Value,
        val token: Long,
    )

    private var nextToken = 0L
    private val activeTokens = mutableSetOf<Long>()
    private var latest: Value? = null

    /** Offers [value], replacing any waiting stale value. */
    fun offer(value: Value) {
        val toDispatch: Dispatch<Value>?
        val toDiscard: Value?
        synchronized(this) {
            if (activeTokens.size >= maximumInFlight) {
                toDiscard = latest
                latest = value
                toDispatch = null
            } else {
                toDiscard = null
                toDispatch = beginDispatch(value)
            }
        }
        toDiscard?.let(onDiscard)
        toDispatch?.let(dispatch)
    }

    /** Releases the active slot and dispatches only the freshest pending value. */
    fun complete(token: Long) {
        val toDispatch: Dispatch<Value>?
        synchronized(this) {
            if (!activeTokens.remove(token)) return
            val pending = latest
            latest = null
            toDispatch = pending?.let(::beginDispatch)
        }
        toDispatch?.let(dispatch)
    }

    /**
     * Drops every queued preview and releases the active slot during
     * backgrounding or teardown. A late completion carries the old [Dispatch]
     * token and is ignored, so it cannot advance a newer foreground send.
     */
    fun invalidate() {
        val toDiscard: Value?
        synchronized(this) {
            toDiscard = latest
            latest = null
            activeTokens.clear()
        }
        toDiscard?.let(onDiscard)
    }

    /** Whether an active or replacement preview currently occupies the bounded pump. */
    fun isBusy(): Boolean = synchronized(this) { activeTokens.isNotEmpty() || latest != null }

    /** True only while [token] still owns the current foreground dispatch slot. */
    fun isActive(token: Long): Boolean = synchronized(this) { token in activeTokens }

    private fun beginDispatch(value: Value): Dispatch<Value> {
        nextToken += 1
        activeTokens += nextToken
        return Dispatch(value, nextToken)
    }
}
