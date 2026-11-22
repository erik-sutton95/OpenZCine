package com.opencapture.openzcine

import com.opencapture.opencine.appkit.CameraSettingsPresetsModel
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.VoiceCommand
import com.opencapture.opencine.appkit.VoiceControlTarget
import com.opencapture.opencine.appkit.executeVoiceCommand
import com.opencapture.opencine.core.CommandDispatchAdmission
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.opencine.nikon.SwiftCoreCameraSession

internal suspend fun executeNikonVoiceCommand(
    command: VoiceCommand, native: SwiftCoreCameraSession, source: NikonOpenCineSession,
    control: MonitorControlModel, presets: CameraSettingsPresetsModel, armedTarget: VoiceControlTarget,
    isCurrent: () -> Boolean,
): String {
    val target = VoiceControlTarget.from(source.snapshots.value)
    val owner = native.connectionOwner
    if (target == null || target.session != armedTarget.session || target.epoch != armedTarget.epoch ||
        owner == null || control.state.value.session !== source || !isCurrent()
    ) {
        return "Camera control is unavailable."
    }
    val eligible = {
        isCurrent() && native.connectionOwner == owner &&
            VoiceControlTarget.from(source.snapshots.value) == target &&
            (!command.changesSettings || (!control.state.value.recordPending && native.reportedRecording.value == false))
    }
    val admission = CameraCommandAdmission(native, eligible)
    val common = CommandDispatchAdmission(target.session, target.epoch, eligible) {
        source.submit(it, admission)
    }
    return control.executeVoiceCommand(command, target, presets, common)
}
