import Foundation
import Testing

@testable import OpenZCineCore

@Suite("Exposure scale conversions")
struct ExposureScaleTests {
    // Anchors from the R3D NE zebra datasheet (raw Log3G10: mid grey at native ≈85 → IRE 33; highlight
    // clip at native ≈180 (base ISO 800) → clip IRE = 180/2.55).

    @Test("Black and the highlight clip pin to the ends of the reference scale")
    func referenceIREEndpoints() {
        #expect(ExposureScale.referenceIRE(signalNative: 0, curve: .redLog3G10) == 0)
        // The clip threshold (native ≈180 at base ISO 800) → reference 100; above it stays pinned.
        #expect(abs(ExposureScale.referenceIRE(signalNative: 180, curve: .redLog3G10) - 100) < 0.05)
        #expect(ExposureScale.referenceIRE(signalNative: 255, curve: .redLog3G10) == 100)
    }

    @Test("Mid grey follows the linear black-to-clip monitoring axis")
    func referenceIREMidGrey() {
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        // Nikon datasheet: 18% grey → native 85. The normalized display does not pretend this is
        // diffuse 18 IRE; it places the code linearly between log black and current clip.
        let ire = ExposureScale.referenceIRE(signalNative: 85, curve: .redLog3G10)
        #expect(abs(ire - mapping.middleGrayPercent) < 0.01)
        #expect(abs(ire - 39.35) < 0.1)
    }

    @Test("A value above mid grey scales linearly toward clip")
    func referenceIREAboveMidGrey() {
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        let ire = ExposureScale.referenceIRE(signalNative: 120.4875, curve: .redLog3G10)
        #expect(abs(ire - mapping.monitorPercent(signalNative: 120.4875)) < 0.001)
    }

    @Test("A highlight below the clip threshold is not pinned to clip")
    func midHighlightIsNotClip() {
        // native 150 sits below the ≈180 clip → a bright highlight, not blown.
        let ire = ExposureScale.referenceIRE(signalNative: 150, curve: .redLog3G10)
        #expect(ire > ExposureSignalMapping(curve: .redLog3G10).middleGrayPercent)
        #expect(ire < 100)
    }

    @Test("signalNative inverts referenceIRE")
    func signalNativeRoundTrip() {
        #expect(
            abs(ExposureScale.signalNative(referenceIRE: 100, curve: .redLog3G10) - 180) < 0.05)
        // Full round-trip through both directions.
        let native = 150.0
        let ire = ExposureScale.referenceIRE(signalNative: native, curve: .redLog3G10)
        let back = ExposureScale.signalNative(referenceIRE: ire, curve: .redLog3G10)
        #expect(abs(back - native) < 0.01)
    }

    @Test("N-Log curve uses its own mid grey and clip anchors")
    func nikonNLogAnchors() {
        // Nikon specification: 18% grey → canonical 10-bit code ≈372.03 (legal IRE ≈35.16).
        let middleGrayNative = ExposureToneCurve.nikonNLog.encode(linearLight: 0.18) * 255
        let ire = ExposureScale.referenceIRE(
            signalNative: middleGrayNative, curve: .nikonNLog)
        let mapping = ExposureSignalMapping(curve: .nikonNLog)
        #expect(abs(ire - mapping.middleGrayPercent) < 0.01)
        #expect(abs(ire - 30.12) < 0.1)
        #expect(abs(middleGrayNative - (372.032 / 1023 * 255)) < 0.01)
    }

    @Test("Waveform level is the normalized signal percentage")
    func waveformLevelAnchors() {
        #expect(ExposureScale.waveformLevel(referenceIRE: 0) == 0)
        #expect(abs(ExposureScale.waveformLevel(referenceIRE: 18) - 0.18) < 0.0001)
        #expect(ExposureScale.waveformLevel(referenceIRE: 100) == 1)
        #expect(abs(ExposureScale.waveformLevel(referenceIRE: 59) - 0.59) < 0.0001)
    }

    @Test("Out-of-range inputs clamp")
    func clamping() {
        #expect(ExposureScale.referenceIRE(signalNative: -20, curve: .redLog3G10) == 0)
        #expect(ExposureScale.referenceIRE(signalNative: 999, curve: .redLog3G10) == 100)
        #expect(ExposureScale.waveformLevel(referenceIRE: -5) == 0)
        #expect(ExposureScale.waveformLevel(referenceIRE: 250) == 1)
    }

    @Test("Legal black sits below the Log3G10 toe floor and reads as crush (reference 0)")
    func legalBlackCrushesOnLogFeed() {
        // Studio-swing legal black (native 16) is *below* Log3G10 true black (native ≈23), so on the
        // log feed it pins to reference 0. The old sub-floor tier used to lift it to ~5 IRE.
        let ire = ExposureScale.referenceIRE(
            signalNative: StudioSwing.legalBlackNative, curve: .redLog3G10)
        #expect(ire == 0)
    }

    @Test("referenceIRE is monotonic non-decreasing across the whole native range")
    func referenceIREMonotonic() {
        // A brighter pixel must never read lower on the scope than a darker one — the old non-monotonic
        // legal-black bump crushed a darkened log feed into a flat line lifted off zero.
        for curve in [ExposureToneCurve.redLog3G10, .nikonNLog] {
            var previous = -1.0
            for native in 0...255 {
                let ire = ExposureScale.referenceIRE(signalNative: Double(native), curve: curve)
                #expect(
                    ire >= previous - 1e-9, "native \(native) read lower than native \(native - 1)")
                previous = ire
            }
        }
    }

    @Test("The feed's blackest pixel (Log3G10 true black) reaches the very bottom")
    func trueBlackReachesFloor() {
        // Log3G10 encode(0.0) ≈ native 23.3; the toe floor must map to reference 0 so a darkened /
        // ND'd scene crushes at the very bottom instead of a lifted flat line ~9.5% up the scope.
        let trueBlackNative = ExposureToneCurve.redLog3G10.encode(linearLight: 0) * 255
        #expect(abs(trueBlackNative - 23.3) < 0.5)
        #expect(ExposureScale.referenceIRE(signalNative: 23, curve: .redLog3G10) == 0)
        #expect(
            ExposureScale.referenceIRE(signalNative: trueBlackNative, curve: .redLog3G10) < 0.01)
        // Just above the toe, values rise off the floor (monotonic ramp toward mid grey).
        #expect(ExposureScale.referenceIRE(signalNative: 40, curve: .redLog3G10) > 0)
    }

    @Test("Z-stop placement round-trips through normalized signal percentage")
    func zStopReferenceIRE() {
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        #expect(
            abs(
                ExposureScale.referenceIRE(zStop: 0, curve: .redLog3G10)
                    - mapping.middleGrayPercent) < 0.05)
        #expect(abs(ExposureScale.signalNative(zStop: 0, curve: .redLog3G10) - 85) < 0.5)
        let plusOne = ExposureScale.referenceIRE(zStop: 1, curve: .redLog3G10)
        let minusTwo = ExposureScale.referenceIRE(zStop: -2, curve: .redLog3G10)
        #expect(plusOne > mapping.middleGrayPercent)
        #expect(minusTwo < mapping.middleGrayPercent)
        #expect(plusOne > minusTwo)
        // Round-trip: native from z-stop → reference IRE lands on the same z-stop band centre.
        for z in [-2.0, -1.0, 0.0, 1.0, 2.0] {
            let native = ExposureScale.signalNative(zStop: z, curve: .redLog3G10)
            let ire = ExposureScale.referenceIRE(signalNative: native, curve: .redLog3G10)
            let back = ExposureScale.signalNative(
                referenceIRE: ire, curve: .redLog3G10)
            #expect(abs(back - native) < 1.0)
        }
    }

    @Test("Published transfer-function anchors stay exact for both log curves")
    func publishedCurveAnchors() {
        let red = ExposureToneCurve.redLog3G10
        #expect(abs(red.encode(linearLight: 0) - 0.091551) < 0.000001)
        #expect(abs(red.encode(linearLight: 0.18) - (1.0 / 3.0)) < 0.000001)
        #expect(abs(red.decode(encodedValue: 1.0 / 3.0) - 0.18) < 0.00001)
        #expect(abs(red.signalIRE(encodedValue: 1.0 / 3.0) - 33.3333) < 0.001)

        let nLog = ExposureToneCurve.nikonNLog
        let middleGray = nLog.encode(linearLight: 0.18)
        #expect(abs(middleGray * 1023 - 372.032) < 0.01)
        #expect(abs(nLog.decode(encodedValue: middleGray) - 0.18) < 0.00001)
        #expect(abs(nLog.middleGrayIRE - 35.163) < 0.01)
        #expect(abs(nLog.blackIRE - 7.218) < 0.01)
    }

    @Test("The full RED 915-0187 Rev C Log3G10 mapping table reproduces exactly")
    func redWhitePaperMappingTable() {
        // "LOG3G10 MAPPING VALUES", page 5: input linear light → encoded value.
        let table: [(linear: Double, encoded: Double)] = [
            (-0.010000, 0.000000),
            (0.000000, 0.091551),
            (0.180000, 0.333333),
            (1.000000, 0.493449),
            (184.322, 1.000000),
        ]
        for row in table {
            #expect(
                abs(ExposureToneCurve.redLog3G10.encode(linearLight: row.linear) - row.encoded)
                    < 0.000005)
        }
    }

    @Test("N-Log spec v1.0.0 segments meet continuously at the published branch point")
    func nLogSpecBranchContinuity() {
        // Nikon N-Log Specification 1.0.0 §2: encode switches segments at reflectance 0.328
        // (decode at 10-bit code 452). Both sides must agree at the boundary and zero light
        // must land at the documented ≈127 code toe.
        let nLog = ExposureToneCurve.nikonNLog
        let cubeSide = 650.0 * pow(0.328 + 0.0075, 1.0 / 3.0)
        let logSide = 150.0 * log(0.328) + 619.0
        #expect(abs(cubeSide - logSide) < 0.15)
        #expect(abs(nLog.encode(linearLight: 0) * 1023 - 127.2) < 0.1)
        // Decode branch point: code 452 through the log segment ≈ the cube segment's value.
        let below = nLog.decode(encodedValue: 451.9 / 1023)
        let above = nLog.decode(encodedValue: 452.1 / 1023)
        #expect(abs(below - above) < 0.001)
    }

    @Test("Minus five through plus five stops round-trip through each published curve")
    func zStopRoundTripsBothCurves() {
        for curve in ExposureToneCurve.allCases {
            for stop in -5...5 {
                let native = ExposureScale.signalNative(zStop: Double(stop), curve: curve)
                let decoded = ExposureScale.zStop(signalNative: native, curve: curve)
                #expect(abs(decoded - Double(stop)) < 0.0001)
            }
        }
    }

    @Test("Broadcast IRE conversion remains available as a diagnostic utility")
    func zebraSignalNativeMatchesBroadcastCode() {
        #expect(abs(ExposureScale.zebraSignalNative(signalIRE: 55) - 140.25) < 0.01)
        #expect(abs(ExposureScale.zebraSignalNative(signalIRE: 95) - 242.25) < 0.01)
        let monitoringNative = ExposureScale.signalNative(
            monitorPercent: 55, mapping: ExposureSignalMapping(curve: .redLog3G10))
        #expect(monitoringNative != ExposureScale.zebraSignalNative(signalIRE: 55))
    }

    @Test("The log black floor anchors the bottom of the scale, not native 0")
    func blackFloorAnchorsBottom() {
        for curve in [ExposureToneCurve.redLog3G10, .nikonNLog] {
            let floorCode = curve.encode(linearLight: 0) * 255
            // The camera's blackest pixel (the log toe floor) now lands on reference 0 — it used to
            // sit ~5–10% up the scale, so the scopes never reached true black.
            #expect(abs(ExposureScale.referenceIRE(signalNative: floorCode, curve: curve)) < 0.01)
            // The inverse puts reference 0 back at the floor code, well above native 0.
            #expect(
                abs(ExposureScale.signalNative(referenceIRE: 0, curve: curve) - floorCode) < 0.01)
            #expect(ExposureScale.signalNative(referenceIRE: 0, curve: curve) > 10)
            // Anything below the floor still pins to 0; mid grey follows the linear signal axis.
            #expect(ExposureScale.referenceIRE(signalNative: 0, curve: curve) == 0)
            let mapping = ExposureSignalMapping(curve: curve)
            #expect(
                abs(
                    ExposureScale.referenceIRE(
                        signalNative: curve.encode(linearLight: 0.18) * 255, curve: curve)
                        - mapping.middleGrayPercent)
                    < 0.01)
        }
    }

    @Test("R3D NE warning endpoint follows Nikon's low and high base ISO tables")
    func r3DWarningTable() {
        #expect(R3DNEHighlightWarning.nativeCode(iso: 200, baseISO: "Low") == 145)
        #expect(R3DNEHighlightWarning.nativeCode(iso: 800, baseISO: "Low") == 180)
        #expect(R3DNEHighlightWarning.nativeCode(iso: 3_200, baseISO: "Low") == 215)
        #expect(R3DNEHighlightWarning.nativeCode(iso: 1_600, baseISO: "High") == 145)
        #expect(R3DNEHighlightWarning.nativeCode(iso: 6_400, baseISO: "High") == 180)
        #expect(R3DNEHighlightWarning.nativeCode(iso: 25_600, baseISO: "High") == 215)
    }

    @Test("Camera mapping expands every R3D clip warning to 100 percent")
    func r3DMonitoringExpansion() {
        for (iso, expectedClip) in [(200 as UInt32, 145.0), (800, 180.0), (3_200, 215.0)] {
            let mapping = ExposureSignalMapping.camera(
                codec: "R3D NE", iso: iso, baseISO: "Low")
            #expect(mapping.clipNative == expectedClip)
            #expect(mapping.monitorPercent(signalNative: expectedClip) == 100)
            #expect(mapping.monitorPercent(signalNative: mapping.blackNative) == 0)
        }
    }

    @Test("N-Log low ISO clip reductions use Nikon's published native codes")
    func nLogLowISOClips() {
        #expect(
            ExposureSignalMapping.camera(codec: "N-Log", iso: 200, baseISO: nil).clipNative == 200)
        for iso: UInt32 in [400, 500, 640] {
            #expect(
                ExposureSignalMapping.camera(codec: "N-Log", iso: iso, baseISO: nil).clipNative
                    == 230)
        }
        #expect(
            abs(
                ExposureSignalMapping.camera(codec: "N-Log", iso: 800, baseISO: nil).clipNative
                    - 940.0 / 1023.0 * 255) < 0.001)
    }
}
