package com.opencapture.openzcine.core

/**
 * What the monitor can truthfully display — the Kotlin twin of core `MonitorDataAvailability`
 * (`Sources/OpenZCineCore/VideoSource.swift`), property for property. One definition both the
 * chrome and its tests read, so "the record button hides on a watcher without control" is stated
 * once rather than re-derived at each mount site.
 *
 * A relay watcher has every reading — the host forwards them — and no ability to write, so
 * receiving metadata is deliberately separate from owning the session. Collapsing the two would
 * either blank a watcher's readouts or offer it controls the camera will never hear.
 */
public data class MonitorDataAvailability(
    /** Whether a camera control session is live — the camera can be read and written. */
    val ownsCameraSession: Boolean,
    /** Whether the camera's readings are arriving, from our own session or a relay host's. */
    val receivesCameraMetadata: Boolean,
    /**
     * Whether this device currently holds the relay's control token — it drives the camera
     * through the host rather than over a link of its own.
     */
    val holdsRelayControl: Boolean = false,
) {
    /** May this device issue camera commands at all — over its own session, or proxied. */
    public val canDriveCamera: Boolean
        get() = ownsCameraSession || holdsRelayControl

    /** Exposure/focus readouts, their pickers, the camera top-bar pills, battery indicators. */
    public val cameraControls: Boolean
        get() = canDriveCamera

    /** The record button and its state readout. */
    public val recordControl: Boolean
        get() = canDriveCamera

    /** Browsing and downloading what is on the card — a control-link operation. */
    public val mediaBrowser: Boolean
        get() = ownsCameraSession

    /** The AF box overlay, and the body's focus confirmation behind it. */
    public val focusBoxes: Boolean
        get() = receivesCameraMetadata

    /** Timecode struck by the body. */
    public val cameraTimecode: Boolean
        get() = receivesCameraMetadata

    /** The camera's own audio meter. */
    public val audioMeters: Boolean
        get() = receivesCameraMetadata

    public companion object {
        /** The owning session's chrome — everything mounts; the shape every screen had before. */
        public val OWNING: MonitorDataAvailability = MonitorDataAvailability(
            ownsCameraSession = true,
            receivesCameraMetadata = true,
        )

        /** A relay watcher: readings arrive, writes only while holding the control token. */
        public fun watcher(holdsControl: Boolean): MonitorDataAvailability =
            MonitorDataAvailability(
                ownsCameraSession = false,
                receivesCameraMetadata = true,
                holdsRelayControl = holdsControl,
            )
    }
}
