package com.opencapture.openzcine.bridge

/**
 * The PTP-IP initiator identity OpenZCine presents to a Nikon body.
 *
 * Nikon keys a paired-computer profile to the 16-byte GUID sent in
 * `Init_Command_Request`. These bytes are therefore a wire contract, not an
 * implementation detail: they are byte-for-byte the iOS value
 * (`PTPIPInitiator.appGUID` in `Sources/OpenZCineCore/PTPIPHandshake.swift`),
 * so one camera-side profile serves every OpenZCine install on either
 * platform. Pair a body once from any device and the rest connect to that same
 * profile — which is the behavior operators already rely on across iOS
 * devices.
 *
 * Android previously minted a random per-install GUID. That made every install
 * — and every reinstall — a stranger to an already-paired body, which the
 * camera refuses with `rejectedInitiator`.
 *
 * Changing either value strands every profile already created in the field, so
 * both are pinned by test on both platforms.
 */
public object PtpIpInitiatorIdentity {
    /** ASCII "OpenZCine", a NUL, then six fixed bytes. Exactly 16, as PTP-IP requires. */
    public val guid: ByteArray
        get() =
            byteArrayOf(
                0x4F, 0x70, 0x65, 0x6E, 0x5A, 0x43, 0x69, 0x6E,
                0x65, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
            )
}
