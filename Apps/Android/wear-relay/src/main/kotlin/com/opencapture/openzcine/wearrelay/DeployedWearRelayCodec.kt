package com.opencapture.openzcine.wearrelay

import com.opencapture.opencine.watchruntime.WatchRelayAction
import com.opencapture.opencine.watchruntime.WatchRelayCodec
import com.opencapture.opencine.watchruntime.WatchRelayConnection
import com.opencapture.opencine.watchruntime.WatchRelayMessage
import com.opencapture.opencine.watchruntime.WatchRelayPaths
import com.opencapture.opencine.watchruntime.WatchRelaySourceFacts

/** Exact deployed v1 payload/path adapter shared by the actual phone and Wear consumers. */
public class DeployedWearRelayCodec : WatchRelayCodec<WatchRelayState, WatchRelayFrame, WatchRelayCommand, WatchCommandResult, WatchTimecode> {
    override val paths: WatchRelayPaths = WatchRelayPaths(WearRelayTransport.STATE_PATH,
        WearRelayTransport.FRAME_PATH, WearRelayTransport.FRAME_ACK_PATH,
        WearRelayTransport.COMMAND_PATH, WearRelayTransport.RESULT_PATH)
    override fun decode(data: ByteArray): WatchRelayMessage<WatchRelayState, WatchRelayFrame, WatchRelayCommand, WatchCommandResult>? =
        runCatching {
            when (val payload = WatchRelayEnvelope.decode(data)) {
                is WatchRelayState -> WatchRelayMessage.State(payload)
                is WatchRelayFrame -> WatchRelayMessage.Frame(payload)
                is WatchRelayCommand -> WatchRelayMessage.Command(payload)
                is WatchCommandResult -> WatchRelayMessage.Result(payload)
            }
        }.getOrNull()
    override fun encodeState(state: WatchRelayState): ByteArray = WatchRelayEnvelope.encode(state)
    override fun encodeFrame(frame: WatchRelayFrame): ByteArray = WatchRelayEnvelope.encode(frame)
    override fun encodeResult(result: WatchCommandResult): ByteArray = WatchRelayEnvelope.encode(result)
    override fun encodeCommand(action: WatchRelayAction): ByteArray {
        require(action == WatchRelayAction.TOGGLE_RECORD)
        return WatchRelayEnvelope.encode(WatchRelayCommand.TOGGLE_RECORD)
    }
    override fun action(command: WatchRelayCommand): WatchRelayAction = when (command) {
        WatchRelayCommand.TOGGLE_RECORD -> WatchRelayAction.TOGGLE_RECORD
    }
    override fun facts(state: WatchRelayState): WatchRelaySourceFacts = WatchRelaySourceFacts(
        when (state.connection) {
            WatchConnectionState.CONNECTED -> WatchRelayConnection.CONNECTED
            WatchConnectionState.DISCONNECTED -> WatchRelayConnection.DISCONNECTED
            WatchConnectionState.NO_CAMERA -> WatchRelayConnection.NO_CAMERA
        }, state.feedLive)
    override fun replacing(state: WatchRelayState, result: WatchCommandResult): WatchRelayState = state.copy(
        recordState = if (result.isRecording) WatchRecordState.RECORDING else WatchRecordState.STANDBY,
        isRecording = result.isRecording)
    override fun error(result: WatchCommandResult): String? = result.error
    override fun result(accepted: Boolean, isRecording: Boolean, error: String?): WatchCommandResult =
        WatchCommandResult(accepted, isRecording, error)
    override fun image(frame: WatchRelayFrame): ByteArray = frame.jpeg
    override fun timecode(frame: WatchRelayFrame): WatchTimecode = frame.timecode
    override fun stateMatches(first: WatchRelayState, second: WatchRelayState): Boolean = first == second
}
