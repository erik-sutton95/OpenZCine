import Testing

@testable import OpenZCineCore

@Test func whiteBalanceKelvinPolicyMatchesNikonDocumentedRange() {
    #expect(WhiteBalanceKelvinPolicy.minimumKelvin == 2_500)
    #expect(WhiteBalanceKelvinPolicy.maximumKelvin == 10_000)
    #expect(WhiteBalanceKelvinPolicy.kelvinSteps.first == 2_500)
    #expect(WhiteBalanceKelvinPolicy.kelvinSteps.last == 10_000)
    // Dial step nearest daylight is 5560 — not the round 5600 of prose / fine-tune.
    #expect(WhiteBalanceKelvinPolicy.kelvinSteps.contains(5_560))
    #expect(!WhiteBalanceKelvinPolicy.kelvinSteps.contains(5_600))
    #expect(WhiteBalanceKelvinPolicy.defaultKelvin == 5_560)
    #expect(WhiteBalanceKelvinPolicy.defaultLabel == "5560K")
    #expect(WhiteBalanceKelvinPolicy.kelvinSteps.count == 31)
}

@Test func whiteBalanceKelvinPolicyRejectsSparseDemoLadderAsAuthoritative() {
    let demoSparse = [3_200, 4_300, 5_400, 5_500, 5_600, 5_700, 6_500]
    #expect(WhiteBalanceKelvinPolicy.kelvinSteps != demoSparse)
    #expect(WhiteBalanceKelvinPolicy.kelvinSteps.count > demoSparse.count)
}

@Test func whiteBalanceKelvinPolicyLabelsAndParsingRoundTrip() {
    #expect(WhiteBalanceKelvinPolicy.label(for: 5_560) == "5560K")
    #expect(WhiteBalanceKelvinPolicy.kelvin(from: "5560K") == 5_560)
    #expect(WhiteBalanceKelvinPolicy.kelvin(from: "2500K") == 2_500)
    #expect(WhiteBalanceKelvinPolicy.kelvin(from: "10000K") == 10_000)
    // Off-ladder but in range (fine-tune / digit entry) still parses.
    #expect(WhiteBalanceKelvinPolicy.kelvin(from: "5600K") == 5_600)
    #expect(WhiteBalanceKelvinPolicy.kelvin(from: "Sunny") == nil)
    #expect(WhiteBalanceKelvinPolicy.kelvin(from: "2000K") == nil)  // below range
    #expect(WhiteBalanceKelvinPolicy.kelvin(from: "11000K") == nil)  // above range
    #expect(WhiteBalanceKelvinPolicy.isKelvinLabel("5560K"))
    #expect(!WhiteBalanceKelvinPolicy.isKelvinLabel("Auto"))
}

@Test func whiteBalanceKelvinPolicyNearestStepSnapsOntoDialLadder() {
    #expect(WhiteBalanceKelvinPolicy.nearestStep(to: 5_560) == 5_560)
    #expect(WhiteBalanceKelvinPolicy.nearestStep(to: 5_600) == 5_560)
    #expect(WhiteBalanceKelvinPolicy.nearestStep(to: 5_500) == 5_560)
    #expect(WhiteBalanceKelvinPolicy.nearestStep(to: 2_400) == 2_500)
    #expect(WhiteBalanceKelvinPolicy.nearestStep(to: 12_000) == 10_000)
}

@Test func whiteBalanceKelvinPolicyInsertsLiveOffLadderFineTuneValue() {
    // 5600 is not a dial step; when the body is fine-tuned there it still appears.
    let options = WhiteBalanceKelvinPolicy.options(including: "5600K")
    #expect(options.contains("5600K"))
    #expect(options.contains("5560K"))
    #expect(options.first == "2500K")
    #expect(options.last == "10000K")
}

@Test func whiteBalanceKelvinPolicyIgnoresSparseCameraAdvertisement() {
    let sparse = ["3200K", "4300K", "5400K", "5500K", "5600K", "5700K", "6500K"]
    let options = WhiteBalanceKelvinPolicy.options(cameraAdvertised: sparse)
    #expect(options == WhiteBalanceKelvinPolicy.kelvinOptions)
    #expect(options.count == 31)
    #expect(!options.contains("5600K"))
}

@Test func whiteBalanceKelvinPolicyPrefersDenserCameraAdvertisement() {
    let dense = (2_500...10_000).filter { $0 % 10 == 0 }.map { "\($0)K" }
    let options = WhiteBalanceKelvinPolicy.options(cameraAdvertised: dense)
    #expect(options.count == dense.count)
    #expect(options.first == "2500K")
    #expect(options.last == "10000K")
}

@Test func whiteBalanceKelvinPolicyFineAdjustStepsByTen() {
    #expect(WhiteBalanceKelvinPolicy.fineStepKelvin == 10)
    #expect(WhiteBalanceKelvinPolicy.fineAdjust(from: "5560K", delta: 10) == "5570K")
    #expect(WhiteBalanceKelvinPolicy.fineAdjust(from: "5560K", delta: -10) == "5550K")
    #expect(WhiteBalanceKelvinPolicy.fineAdjust(from: "2500K", delta: -10) == "2500K")
    #expect(WhiteBalanceKelvinPolicy.fineAdjust(from: "10000K", delta: 10) == "10000K")
    #expect(WhiteBalanceKelvinPolicy.fineAdjust(from: "Sunny", delta: 10) == nil)
    #expect(WhiteBalanceKelvinPolicy.canFineAdjust(from: "5560K", delta: 10))
    #expect(!WhiteBalanceKelvinPolicy.canFineAdjust(from: "2500K", delta: -10))
    #expect(!WhiteBalanceKelvinPolicy.canFineAdjust(from: "10000K", delta: 10))
}
