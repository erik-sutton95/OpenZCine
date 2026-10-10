import MonitorPresentation
import Testing

@testable import Runner

@Suite("Media delivery common presentation")
struct MediaDeliveryPanelValueTests {
    @Test("Native defaults retain actual format, metadata and unsupported-option absence")
    func nativeDefaults() {
        let value = MediaDeliveryPanelValue.export(
            configuration: .init(), lutAvailable: true, lutLabel: "SIMULATED LUT",
            filename: "SIMULATED.MOV", destination: .nativeShare
        )
        #expect(value.filename == "SIMULATED.MOV")
        #expect(value.bakeLUT?.isOn == true && value.bakeLUT?.enabled == true)
        #expect(value.format?.selectedID == "mov")
        #expect(value.format?.options.map(\.id) == ["mov", "mp4"])
        #expect(value.includeMetadata?.isOn == true)
        #expect(value.reupload == nil)
        #expect(value.convertLog == nil && value.outputCurve == nil && value.bakeExposure == nil)
    }

    @Test("Unavailable LUT and Frame.io preserve distinct supplied options")
    func frameioOptions() {
        var configuration = MediaDeliveryConfiguration()
        configuration.bakeLUT = false
        let value = MediaDeliveryPanelValue.export(
            configuration: configuration, lutAvailable: false, lutLabel: "",
            filename: nil, destination: .frameio
        )
        #expect(value.bakeLUT?.isOn == false && value.bakeLUT?.enabled == false)
        #expect(value.filename == nil && value.format == nil)
        #expect(value.reupload?.isOn == false)
        #expect(MediaDeliveryPanelValue.postExport(.systemShare).selectedID == "systemShare")
        #expect(MediaDeliveryPanelValue.postExport(.saveToPhotos).selectedID == "saveToPhotos")
    }

    @Test("Photos phases preserve both spinner and determinate progress")
    func photosProgressProjection() {
        for phase in [MediaDeliveryOverlayState.Phase.awaitingPhotosAccess, .savingToPhotos] {
            let state = MediaDeliveryOverlayState(
                destination: .nativeShare, totalClips: 2, clipIndex: 2, clipFraction: 0.75,
                postExportAction: .saveToPhotos, phase: phase
            )
            let value = state.monitorProgressValue
            #expect(value.preparing && value.showsProgress)
            #expect(value.fraction == 0.875 && value.batch == "Clip 2 of 2")
            #expect(value.status == state.statusLine)
        }
    }

    @Test("Preparing and working progress retain the original independent facts")
    func progressProjection() {
        let preparing = MediaDeliveryOverlayState(
            destination: .frameio, totalClips: 1, clipIndex: 1, clipFraction: 0
        ).monitorProgressValue
        #expect(preparing.preparing && !preparing.showsProgress && preparing.batch == nil)
        let switching = MediaDeliveryOverlayState(
            destination: .frameio, totalClips: 1, clipIndex: 1, clipFraction: 0.4,
            isSwitchingNetworks: true
        ).monitorProgressValue
        #expect(switching.preparing && switching.showsProgress)
        #expect(switching.fraction == 0.4 && switching.status == "Switching networks…")
    }
}
