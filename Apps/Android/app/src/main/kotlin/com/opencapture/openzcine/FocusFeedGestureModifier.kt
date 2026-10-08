package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.opencapture.monitorui.monitorFocusGestures

/** Native focus/geometry projection only; common monitor-ui owns pointer arbitration and lifetime. */
@Composable
internal fun Modifier.focusFeedGestures(
    geometry: FocusFeedGeometry?, context: FocusFeedGestureContext, isPortrait: Boolean, isZoomed: Boolean,
    onHoldingChanged: (Boolean) -> Unit, onAction: (FocusFeedGestureAction) -> Unit, sourceIdentity: Any? = null,
): Modifier = monitorFocusGestures(geometry?.common, sourceIdentity, context.common, isPortrait, isZoomed,
    onHoldingChanged = onHoldingChanged, onAction = { onAction(it.sourceRequest()) })
