package com.opencapture.openzcine.pairing

/**
 * How the operator plans to reach the camera during first-time pairing — the
 * Android port of the iOS shell's `FirstPairTransportMethod`
 * (ios/Runner/NativeAppRoot.swift). USB-C has no Wi-Fi join or scan step:
 * Android discovers the physically attached PTP interface and requests its
 * per-device USB permission at the final discovery step.
 *
 * The two paths are HARD-separated (this cost real bugs on iOS):
 * - [CAMERA_ACCESS_POINT]: the phone joins the camera's own network via
 *   [CameraApJoiner] — the only class that requests or binds a Wi-Fi network.
 * - [PHONE_HOTSPOT]: the CAMERA joins the phone's hotspot; the phone hosts
 *   and must never scan or join anything — this path only ever watches NSD
 *   discovery for the camera to appear.
 */
public enum class PairingPath {
    CAMERA_ACCESS_POINT,
    PHONE_HOTSPOT,

    /**
     * Both devices already on someone else's network — a set router, a travel router, house
     * Wi-Fi. Shaped exactly like [PHONE_HOTSPOT]: the app joins nothing and hosts nothing, it
     * only watches discovery. It is excluded from the camera-AP mechanisms for the same reason.
     */
    WIFI_NETWORK,
    USB_C,

    /**
     * The camera's HDMI output through a UVC capture cable — picture only, no control link.
     * There is no network on this path at all: the wizard goes from preparing the cable
     * straight to finding the capture device.
     */
    HDMI_CAPTURE,
    ;

    /**
     * Whether the app itself joins the camera's own access point on this path.
     *
     * The single discriminator for every camera-AP mechanism. One question rather than a list of
     * exclusions, because the list is what went wrong before: each new path had to remember to
     * opt out, and the ones that forgot cost real bugs.
     */
    public val joinsCameraAccessPoint: Boolean
        get() = this == CAMERA_ACCESS_POINT
}

/**
 * The choose step's cards. Each groups several paths, so the operator picks a kind of connection
 * first and the specific one second — two questions that are much easier apart than one flat list.
 */
public enum class PairingCard(public val options: List<PairingPath>) {
    WIRELESS(
        listOf(PairingPath.CAMERA_ACCESS_POINT, PairingPath.PHONE_HOTSPOT, PairingPath.WIFI_NETWORK)
    ),
    CABLE_LINK(listOf(PairingPath.USB_C, PairingPath.HDMI_CAPTURE)),
    ;

    public companion object {
        public fun of(path: PairingPath): PairingCard = entries.first { path in it.options }
    }
}

/**
 * Guided wizard steps, mirroring iOS `FirstPairWizardStep`: permissions →
 * choose path → prepare the camera → set up the network → (hotspot and USB-C)
 * find and pair. Camera-AP pairing ends at [NETWORK] — joining the camera's
 * Wi-Fi is the last operator action; connect runs against the fixed AP host.
 */
public enum class PairingStep {
    PERMISSIONS,
    CHOOSE_PATH,
    PREPARE,
    NETWORK,
    DISCOVER,
}

/**
 * Immutable first-pair wizard position: the current [step] along the active
 * [path]'s step sequence. Pure state — all side effects (permission requests,
 * Wi-Fi joins, discovery, session connects) live with the UI layer.
 *
 * @property skipsPermissions Omits the permissions step (and adjusts the
 *   numbering) when the runtime permission is already granted, mirroring iOS
 *   `firstPairWizardSkipsPermissions`.
 */
public data class PairingFlowState(
    val step: PairingStep = PairingStep.PERMISSIONS,
    val path: PairingPath = PairingPath.CAMERA_ACCESS_POINT,
    val skipsPermissions: Boolean = false,
) {
    init {
        require(!(skipsPermissions && step == PairingStep.PERMISSIONS)) {
            "The permissions step cannot be current while skipped"
        }
        require(!(path == PairingPath.CAMERA_ACCESS_POINT && step == PairingStep.DISCOVER)) {
            "Camera-AP pairing ends at NETWORK; DISCOVER belongs to hotspot or USB-C pairing"
        }
        require(!(path == PairingPath.HDMI_CAPTURE && step == PairingStep.NETWORK)) {
            "HDMI capture has no network step; the cable is the whole link"
        }
    }

    private val sequence: List<PairingStep>
        get() = buildList {
            if (!skipsPermissions) add(PairingStep.PERMISSIONS)
            add(PairingStep.CHOOSE_PATH)
            add(PairingStep.PREPARE)
            // HDMI capture has no network at all — the cable is the whole link.
            if (path != PairingPath.HDMI_CAPTURE) {
                add(PairingStep.NETWORK)
            }
            // Camera-AP pairing ends at NETWORK — joining the camera's Wi-Fi is the last
            // operator action. Every other path finishes by finding the camera.
            if (path != PairingPath.CAMERA_ACCESS_POINT) {
                add(PairingStep.DISCOVER)
            }
        }

    /** Total visible steps for the active path (iOS `stepCount(transport:skipsPermissions:)`). */
    val stepCount: Int
        get() = sequence.size

    /** 1-based step index shown in the wizard chrome. */
    val displayStepNumber: Int
        get() = sequence.indexOf(step) + 1

    /** Whether this step is the last one for the chosen path. */
    val isFinalStep: Boolean
        get() = sequence.last() == step

    /** Whether a Back affordance makes sense (any step after the first). */
    val canRetreat: Boolean
        get() = sequence.indexOf(step) > 0

    /** The next step, or this state unchanged when already at the final step. */
    public fun advance(): PairingFlowState {
        val index = sequence.indexOf(step)
        if (index == sequence.lastIndex) return this
        return copy(step = sequence[index + 1])
    }

    /** The previous step, or this state unchanged when at the first step. */
    public fun retreat(): PairingFlowState {
        val index = sequence.indexOf(step)
        if (index <= 0) return this
        return copy(step = sequence[index - 1])
    }

    /** Selects a path from the choose step and advances (tap = select + advance, like iOS). */
    public fun choose(path: PairingPath): PairingFlowState =
        copy(path = path, step = PairingStep.PREPARE)

    public companion object {
        /** Initial wizard state, skipping straight past permissions when already granted. */
        public fun initial(permissionGranted: Boolean): PairingFlowState =
            if (permissionGranted) {
                PairingFlowState(step = PairingStep.CHOOSE_PATH, skipsPermissions = true)
            } else {
                PairingFlowState()
            }
    }
}
