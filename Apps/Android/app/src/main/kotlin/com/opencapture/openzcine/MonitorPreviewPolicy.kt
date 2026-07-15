package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.LiveFrameSource

/**
 * Returns the monitor-owned live source only while a preview-bearing monitor
 * mode is visible. Command mode deliberately has no frame consumers, allowing
 * the shared source to send `EndLiveView` after its last preview collector.
 */
internal fun monitorPreviewFrameSource(
    source: LiveFrameSource?,
    isCommandMode: Boolean,
): LiveFrameSource? = source?.takeIf { !isCommandMode }

/**
 * Recording inputs for preview policy use confirmed camera state. A start is
 * not confirmed until the facade reports [CameraRecordingState.RECORDING],
 * while a stop keeps the active-take preview constraints until it succeeds.
 */
internal fun previewPolicyRecordingActive(state: CameraRecordingState): Boolean =
    state == CameraRecordingState.RECORDING || state == CameraRecordingState.STOPPING
