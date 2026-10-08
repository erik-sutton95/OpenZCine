package com.opencapture.openzcine.wear

import com.opencapture.opencine.relay.RelayLatestPreviewPump

/** Original consumer/test facade; no copied reservation or latest-pending policy. */
internal class LatestFrameBackpressure<Value : Any>(maximumInFlight: Int = 1,
    dispatch: (Dispatch<Value>) -> Unit, onDiscard: (Value) -> Unit = {}) {
    internal data class Dispatch<Value : Any>(val value: Value, val token: Long)
    private val owner = RelayLatestPreviewPump(maximumInFlight = maximumInFlight,
        dispatch = { item: RelayLatestPreviewPump.Dispatch<Value> -> dispatch(Dispatch(item.value, item.token)) }, onDiscard = onDiscard)
    fun offer(value: Value) = owner.offer(value)
    fun complete(token: Long) = owner.complete(token)
    fun invalidate() = owner.invalidate()
    fun isBusy() = owner.isBusy()
    fun isActive(token: Long) = owner.isActive(token)
}
