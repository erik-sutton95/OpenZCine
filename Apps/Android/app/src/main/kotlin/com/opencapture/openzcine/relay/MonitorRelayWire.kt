package com.opencapture.openzcine.relay

import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.opencine.relay.RelayControlWireCodec
import com.opencapture.opencine.relay.RelayFrameBlob
import com.opencapture.opencine.relay.RelayFramePayload
import com.opencapture.opencine.relay.RelayPeerHello
import com.opencapture.opencine.relay.RelayVideoDescription
import com.opencapture.opencine.relay.RelayWireProfile
import org.json.JSONObject

/** Schema facts and SDK JSON conversion only; shared owners handle framing and runtime policy. */
internal class DeployedMonitorRelayCodec : RelayControlWireCodec<
    MonitorRelayWire.State, MonitorRelayWire.FrameMetadata, MonitorRelayWire.Command,
    MonitorRelayWire.ControlToken, MonitorRelayWire.JoinDenied> {
    override val profile = RelayWireProfile(
        serviceType = MonitorRelayWire.SERVICE_TYPE, version = MonitorRelayWire.VERSION,
        maximumPayloadBytes = MonitorRelayWire.MAXIMUM_PAYLOAD_BYTES,
        servedCameraTXTKey = MonitorRelayWire.SERVED_CAMERA_TXT_KEY,
        watchableTXTKey = MonitorRelayWire.WATCHABLE_TXT_KEY,
        presenceTcpPort = MonitorRelayWire.PRESENCE_TCP_PORT,
        jpegCodec = MonitorRelayWire.FrameCodec.JPEG, hevcCodec = MonitorRelayWire.FrameCodec.HEVC,
        acceptsPeerCodecDeclaration = true)
    override fun videoDescription(metadata: MonitorRelayWire.FrameMetadata) = RelayVideoDescription(
        metadata.codec, metadata.isKeyframe, metadata.parameterSets)
    override fun encodeHello(hello: RelayPeerHello) = MonitorRelayWire.Hello(
        hello.version, hello.hostName, hello.cameraName, hello.passcode, hello.codecs, hello.watcherID).toJson().bytes()
    override fun decodeHello(payload: ByteArray): RelayPeerHello {
        val hello = MonitorRelayWire.Hello.fromJson(json(payload))
        return RelayPeerHello(hello.version, hello.hostName, hello.cameraName, hello.passcode, hello.codecs, hello.watcherId)
    }
    override fun encodeState(state: MonitorRelayWire.State) = state.toJson().bytes()
    override fun decodeState(payload: ByteArray) = MonitorRelayWire.State.fromJson(json(payload))
    override fun encodeCommand(command: MonitorRelayWire.Command) = command.toJson().bytes()
    override fun decodeCommand(payload: ByteArray) = requireNotNull(MonitorRelayWire.Command.fromJson(json(payload)))
    override fun encodeFrame(metadata: MonitorRelayWire.FrameMetadata, image: ByteArray) =
        RelayFrameBlob.encode(metadata.toJson().bytes(), image)
    override fun decodeFrame(payload: ByteArray): RelayFramePayload<MonitorRelayWire.FrameMetadata> {
        val frame = RelayFrameBlob.decode(payload)
        return RelayFramePayload(MonitorRelayWire.FrameMetadata.fromJson(json(frame.metadata)), frame.image)
    }
    override fun encodeControl(holderName: String, holderIsRecipient: Boolean) =
        MonitorRelayWire.ControlToken(holderName, holderIsRecipient).toJson().bytes()
    override fun decodeControl(payload: ByteArray) = MonitorRelayWire.ControlToken.fromJson(json(payload))
    override fun holderIsRecipient(control: MonitorRelayWire.ControlToken) = control.holderIsRecipient
    override fun encodeDenied(reason: String, passcodeRequired: Boolean) =
        MonitorRelayWire.JoinDenied(reason, passcodeRequired).toJson().bytes()
    override fun decodeDenied(payload: ByteArray) = MonitorRelayWire.JoinDenied.fromJson(json(payload))
    private fun json(bytes: ByteArray) = JSONObject(String(bytes, Charsets.UTF_8))
    private fun JSONObject.bytes() = toString().toByteArray(Charsets.UTF_8)
}
