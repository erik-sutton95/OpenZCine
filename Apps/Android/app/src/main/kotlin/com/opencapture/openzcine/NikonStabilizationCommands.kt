package com.opencapture.openzcine

import com.opencapture.opencine.appkit.MonitorNativeWrites
import com.opencapture.opencine.cameracontrols.MonitorOperatorLiveIdentity
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraSession
import kotlinx.coroutines.CoroutineScope
import java.util.concurrent.atomic.AtomicReference

/** The surviving target owns its optional receipt; legacy controls keep a nil receipt. */
internal data class NikonNativeControlSelection(
    val request: CommandControlRequest,
    val label: String,
    val admission: CameraCommandAdmission? = null,
) {
    suspend fun apply(session: CameraSession) {
        if (admission == null) session.applyControl(request.control, label)
        else session.applyControl(request.control, label, admission)
    }
}

/** App composition over the existing latest-per-control queue, including its original feedback. */
internal fun nikonNativeControlWrites(
    scope: CoroutineScope,
    session: CameraSession,
    commonWrite: suspend (CameraControl, String) -> Boolean,
    confirmed: (CameraControl, String) -> Boolean,
    refused: (NikonNativeControlSelection, Exception) -> Unit,
): MonitorNativeWrites<CameraControl, NikonNativeControlSelection> = MonitorNativeWrites(
    scope,
    write = { control, selection ->
        if (!commonWrite(control, selection.label)) selection.apply(session)
        session.refreshProperties()
    },
    confirmed = { control, selection -> confirmed(control, selection.label) },
    refused = { _, selection, error -> refused(selection, error) },
)

/** Only the grouped producer supplies authority; background checks read its immutable publication. */
internal class NikonStabilizationCommands {
    private class Publication(
        val session: CameraSession,
        val source: MonitorOperatorLiveIdentity,
        val isCurrent: () -> Boolean,
    )
    private val current = AtomicReference<Publication?>(null)

    /** Call on the producer thread. [isCurrent] must itself be thread-safe, never a UI-state read. */
    fun publish(session: CameraSession, source: MonitorOperatorLiveIdentity, enabled: Boolean, isCurrent: () -> Boolean) {
        val previous = current.get()
        if (!enabled) current.set(null)
        else if (previous == null || previous.session !== session || previous.source != source || !previous.isCurrent()) {
            current.set(Publication(session, source, isCurrent))
        }
    }

    fun selection(request: CommandControlRequest, label: String): NikonNativeControlSelection? {
        val captured = current.get() ?: return null
        val admission = CameraCommandAdmission(captured.session) {
            current.get() === captured && captured.isCurrent()
        }
        if (!admission.admits(captured.session)) return null
        return NikonNativeControlSelection(request, label, admission)
    }

    fun retire() { current.set(null) }
    fun close() { retire() }
}
