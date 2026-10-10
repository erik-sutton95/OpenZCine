import OpenZCineCore
import Testing

import enum OpenCineMedia.MonitorCrushClipCompensation

@testable import OpenZCineAndroidFacade

/// The scope wire must carry the core's camera axis and Traffic Lights math
/// value-for-value: the shared Compose scopes draw straight off these payloads.
struct ScopeFrameWireTests {
    @Test func levelAxisIsTheCameraMappingsSharedAxis() {
        for ordinal in 0...3 {
            let flat = ScopeFrameWire.levelAxis(curveOrdinal: ordinal)
            let axis = ExposureSignalMapping(curve: ScopeFrameWire.curve(ordinal: ordinal))
                .scopeLevelAxis
            #expect(flat.count == ScopeFrameWire.histogramBins + 1)
            #expect(Array(flat.prefix(ScopeFrameWire.histogramBins)) == axis.table)
            #expect(flat.last == Float(axis.middleGrayIRE))
        }
    }

    @Test func levelAxisUsesTheCameraClipAndKeepsMidGrey() {
        let shifted = ScopeFrameWire.levelAxis(curveOrdinal: 0, clipNative: 215)
        let axis = ExposureSignalMapping(curve: .redLog3G10, clipNative: 215).scopeLevelAxis
        #expect(Array(shifted.prefix(ScopeFrameWire.histogramBins)) == axis.table)
        // The ISO clip re-stretches the highlights only; mid grey never moves.
        #expect(shifted.last == ScopeFrameWire.levelAxis(curveOrdinal: 0).last)
        #expect(
            ScopeFrameWire.levelAxis(curveOrdinal: 0, clipNative: .nan)
                == ScopeFrameWire.levelAxis(curveOrdinal: 0))
    }

    /// 100 mid-grey samples plus one white one: the white clears the 0-stop
    /// edge threshold but stays below iOS's quarter-stop default.
    private func sparseClipHistograms() -> [Int] {
        let mid = Int(ExposureToneCurve.redLog3G10.middleGrayNativeCode.rounded())
        var channel = [Int](repeating: 0, count: ScopeFrameWire.histogramBins)
        channel[mid] = 100
        channel[255] = 1
        return Array([[Int]](repeating: channel, count: 4).joined())
    }

    private func flat(_ reading: TrafficLightsReading) -> [Float] {
        [reading.red, reading.green, reading.blue].flatMap { channel -> [Float] in
            [Float(channel.level), channel.clip ? 1 : 0, channel.crush ? 1 : 0]
        }
    }

    @Test func trafficLightsAreTheCoreMeterOnTheSharedHistograms() {
        let histograms = sparseClipHistograms()
        let bins = { (index: Int) in
            Array(histograms[(index * 256)..<((index + 1) * 256)])
        }
        let expected = TrafficLightsMeter.measure(
            samples: ScopeSamples(
                histogramLuma: bins(0), histogramRed: bins(1), histogramGreen: bins(2),
                histogramBlue: bins(3), points: []),
            noiseFloorCompensation: .quarter,
            mapping: ExposureSignalMapping(curve: .redLog3G10))
        #expect(
            ScopeFrameWire.trafficLights(histograms: histograms, curveOrdinal: 0)
                == flat(expected))
    }

    @Test func trafficLightsApplyTheSelectedCompensation() {
        let histograms = sparseClipHistograms()
        func reading(_ raw: Int? = nil) -> [Float] {
            if let raw {
                return ScopeFrameWire.trafficLights(
                    histograms: histograms, curveOrdinal: 0, crushClipCompensationRaw: raw)
            }
            return ScopeFrameWire.trafficLights(histograms: histograms, curveOrdinal: 0)
        }
        func clipFlags(_ flat: [Float]) -> [Float] {
            (0..<3).map { flat[$0 * ScopeFrameWire.trafficChannelStride + 1] }
        }
        let zero = reading(MonitorCrushClipCompensation.zero.rawValue)
        let quarter = reading(MonitorCrushClipCompensation.quarter.rawValue)
        let one = reading(MonitorCrushClipCompensation.one.rawValue)
        #expect(clipFlags(zero) == [1, 1, 1])
        #expect(clipFlags(quarter) == [0, 0, 0])
        #expect(reading() == quarter)
        #expect(reading(15) == one)
        #expect(reading(-1) == zero)
    }

    @Test func malformedHistogramsReadAsAnEmptyFrame() {
        let empty = TrafficLightsMeter.measure(
            samples: .empty, noiseFloorCompensation: .quarter,
            mapping: ExposureSignalMapping(curve: .redLog3G10))
        let expected = flat(empty)
        #expect(ScopeFrameWire.trafficLights(histograms: [1, 2, 3], curveOrdinal: 0) == expected)
        #expect(ScopeFrameWire.trafficLights(histograms: [], curveOrdinal: 0) == expected)
    }
}
