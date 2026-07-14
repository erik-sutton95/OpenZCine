package com.opencapture.openzcine.pairing

/**
 * How the operator plans to reach the camera during first-time pairing — the
 * Android port of the iOS shell's `FirstPairTransportMethod`
 * (ios/Runner/NativeAppRoot.swift), minus USB-C which has no Android
 * transport yet.
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
}

/**
 * Guided wizard steps, mirroring iOS `FirstPairWizardStep`: permissions →
 * choose path → prepare the camera → set up the network → (hotspot only)
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
            "Camera-AP pairing ends at NETWORK; DISCOVER belongs to the hotspot path"
        }
    }

    private val sequence: List<PairingStep>
        get() = buildList {
            if (!skipsPermissions) add(PairingStep.PERMISSIONS)
            add(PairingStep.CHOOSE_PATH)
            add(PairingStep.PREPARE)
            add(PairingStep.NETWORK)
            if (path == PairingPath.PHONE_HOTSPOT) add(PairingStep.DISCOVER)
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
