import Testing

@testable import OpenZCineCore

@Test func displayStateProvidesWireframeDefaults() {
    let state = CameraDisplayState.preview

    #expect(state.recordState == .standby)
    #expect(state.timecode.label == "00:00:00:00")
    #expect(state.resolutionFrameRate == "6K · 25p")
    #expect(state.codec == "R3D NE")
    #expect(state.media == "521 GB · 47 min")
    #expect(state.temperature == "OK")
    #expect(state.values.map(\.label) == ["ISO", "SHUTTER", "IRIS", "WB", "FOCUS"])
}

@Test func displayStateUsesPolledWarningInsteadOfFabricatedTemperature() {
    let state = CameraDisplayState.preview.applyingCameraProperties(
        PTPCameraPropertySnapshot(warningRaw: 0x01))
    #expect(state.temperature == "CHECK")
}

@Test func dispModeCyclesThroughConfiguredOrder() {
    let order: [DispMode] = [.live, .clean, .command]

    #expect(DispMode.live.next(in: order) == .clean)
    #expect(DispMode.clean.next(in: order) == .command)
    #expect(DispMode.command.next(in: order) == .live)
}

@Test func whiteBalanceReadoutShowsPresetNameNotStaleKelvin() {
    // A named preset shows its name even when a Kelvin value is still known from before.
    let sunny = PTPCameraPropertySnapshot(wbMode: "Sunny", wbKelvin: 5600)
    let sunnyState = CameraDisplayState.preview.applyingCameraProperties(sunny)
    #expect(sunnyState.values.first { $0.label == "WB" }?.value == "Sunny")

    // Colour-temperature mode shows the Kelvin reading.
    let kelvin = PTPCameraPropertySnapshot(wbMode: "Color temp", wbKelvin: 5600)
    let kelvinState = CameraDisplayState.preview.applyingCameraProperties(kelvin)
    #expect(kelvinState.values.first { $0.label == "WB" }?.value == "5600K")
}
