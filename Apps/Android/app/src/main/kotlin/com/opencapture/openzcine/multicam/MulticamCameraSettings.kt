package com.opencapture.openzcine.multicam

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.multicam.EditorLease
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.NikonOpenCineSession
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.StateFlow

/** The iOS `SettingKey.rawValue` spelling, so both platforms share accessibility identifiers. */
val SettingKey.identifier: String
    get() = name.lowercase().split('_').let { parts ->
        parts.first() + parts.drop(1).joinToString("") { it.replaceFirstChar(Char::uppercase) }
    }

/**
 * A borrowed control surface over the member's existing session. Closing it retires only this
 * editor: accepted commands and the member's picture and connection keep their owner. Every
 * forwarded command carries a native admission bound to the member's own link session and this
 * editor's receipt, so a write queued before retirement never reaches a replacement member.
 */
class MulticamEditorSession(
    private val source: NikonOpenCineSession,
    private val owner: com.opencapture.opencine.nikon.CameraSession,
    private val isCurrent: () -> Boolean,
) : CameraSession {
    private val active = AtomicBoolean(true)
    private val rejected = ConcurrentHashMap<OperationID, CommandReceipt>()

    override val id: CameraSessionID get() = source.id
    override val snapshots: StateFlow<CameraSnapshot> get() = source.snapshots
    val isActive: Boolean get() = active.get()

    override suspend fun submit(command: CameraCommand): CommandReceipt {
        rejected[command.operation]?.let { return it }
        if (!active.get() || !isCurrent()) {
            return CommandReceipt(command.operation, id, command.intent, CommandStage.Rejected(CommandRejection.AuthorityExpired))
                .also { rejected[command.operation] = it }
        }
        // The predicate reads only this thread-safe receipt; it runs at the native queue's gate.
        return source.submit(command, CameraCommandAdmission(owner) { active.get() })
    }

    override suspend fun outcome(operation: OperationID): CommandReceipt? = rejected[operation] ?: source.outcome(operation)

    override fun receipt(operation: OperationID): CommandReceipt? = rejected[operation] ?: source.receipt(operation)

    /** Retires the editor only; the member session stays open and recording is untouched. */
    override suspend fun close(reason: SessionCloseReason) = closeNow(reason)

    override fun closeNow(reason: SessionCloseReason) {
        active.set(false)
    }
}

/** One open Multiview camera editor: the member, its engine lease and the borrowed facade. */
class MulticamCameraEditor(
    val member: MonitorEntryID,
    val lease: EditorLease,
    val session: MulticamEditorSession,
) {
    fun retire() = session.closeNow(SessionCloseReason.REQUESTED)
}
