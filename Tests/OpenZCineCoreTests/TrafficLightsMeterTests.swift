import Testing

@testable import OpenZCineCore

@Suite("Traffic Lights meter")
struct TrafficLightsMeterTests {
    @Test("White frame clips all channels and fills meters near the top")
    func clippedWhite() {
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        red[255] = 100
        green[255] = 100
        blue[255] = 100
        let samples = ScopeSamples(
            histogramLuma: red, histogramRed: red, histogramGreen: green, histogramBlue: blue,
            points: [])
        let reading = TrafficLightsMeter.measure(
            samples: samples, noiseFloorCompensation: .zero, curve: .redLog3G10)
        #expect(reading.red.clip)
        #expect(reading.green.clip)
        #expect(reading.blue.clip)
        #expect(!reading.red.crush)
        #expect(reading.red.level > 0.95)
    }

    @Test("Crushed shadow channel lights the floor indicator")
    func crushedShadow() {
        let toeFloor = ScopeSampler.trafficCrushFloor(curve: .redLog3G10)
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        blue[toeFloor] = 100
        let samples = ScopeSamples(
            histogramLuma: blue, histogramRed: red, histogramGreen: green, histogramBlue: blue,
            points: [])
        let reading = TrafficLightsMeter.measure(
            samples: samples, noiseFloorCompensation: .zero, curve: .redLog3G10)
        #expect(reading.blue.crush)
        #expect(!reading.blue.clip)
        // Native axis: the log toe (~code 23) reads low on the balance bar without snapping to 0.
        #expect(reading.blue.level < 0.15)
    }

    @Test("Mid grey sits at centre of the meter scale")
    func midGreyLevel() {
        var hist = [Int](repeating: 0, count: 256)
        let midNative = Int(
            ExposureSignalMapping(curve: .redLog3G10).middleGrayNative.rounded())
        hist[midNative] = 200
        let samples = ScopeSamples(
            histogramLuma: hist, histogramRed: hist, histogramGreen: hist, histogramBlue: hist,
            points: [
                ScopePoint(
                    xRatio: 0.5, red: UInt8(midNative), green: UInt8(midNative),
                    blue: UInt8(midNative), luma: UInt8(midNative))
            ])
        let level = TrafficLightsMeter.channelLevel(
            samples: samples, channel: .red, curve: .redLog3G10)
        #expect(level > 0.48)
        #expect(level < 0.52)
    }

    @Test("Point path uses median waveform level, not peak outliers")
    func pointMedianLevel() {
        let clipNative = Int(
            ExposureScale.signalNative(referenceIRE: 100, curve: .redLog3G10).rounded())
        let shadowNative = 40
        let samples = ScopeSamples(
            histogramLuma: Array(repeating: 0, count: 256),
            histogramRed: Array(repeating: 0, count: 256),
            histogramGreen: Array(repeating: 0, count: 256),
            histogramBlue: Array(repeating: 0, count: 256),
            points: [
                ScopePoint(
                    xRatio: 0.2, red: UInt8(clipNative), green: 0, blue: 0, luma: 0),
                ScopePoint(
                    xRatio: 0.8, red: UInt8(shadowNative), green: 0, blue: 0, luma: 0),
            ])
        let level = TrafficLightsMeter.channelLevel(
            samples: samples, channel: .red, curve: .redLog3G10)
        let low = ScopeDisplayScale.waveformLevel(
            signalNative: Double(shadowNative), curve: .redLog3G10)
        let high = ScopeDisplayScale.waveformLevel(
            signalNative: Double(clipNative), curve: .redLog3G10)
        let scopeMedian = (low + high) / 2
        let middle = ScopeDisplayScale.middleGrayLevel(
            mapping: ExposureSignalMapping(curve: .redLog3G10))
        let expected =
            scopeMedian <= middle
            ? (scopeMedian / middle) * 0.5
            : 0.5 + ((scopeMedian - middle) / (1 - middle)) * 0.5
        #expect(abs(level - expected) < 0.0001)
        #expect(level < high - 0.1, "median must ignore a lone highlight outlier")
    }

    @Test("Crush/clip compensation adjusts traffic-light thresholds")
    func crushClipThreshold() {
        var red = [Int](repeating: 0, count: 256)
        red[255] = 8
        red[128] = 92
        let samples = ScopeSamples(
            histogramLuma: red, histogramRed: red, histogramGreen: red, histogramBlue: red,
            points: [])
        let strict = TrafficLightsMeter.measure(
            samples: samples, noiseFloorCompensation: .zero, curve: .redLog3G10)
        let forgiving = TrafficLightsMeter.measure(
            samples: samples, noiseFloorCompensation: .one, curve: .redLog3G10)
        #expect(strict.red.clip)
        #expect(!forgiving.red.clip)
    }

    @Test("Empty histogram yields zero levels and no flags")
    func emptySamples() {
        let reading = TrafficLightsMeter.measure(
            samples: .empty, noiseFloorCompensation: .one, curve: .redLog3G10)
        #expect(reading == .empty)
    }

    @Test("Mid grey renders a neutral single-sided display")
    func balancedDisplay() {
        let reading = TrafficLightsChannelReading(level: 0.5, clip: false, crush: false)
        let display = TrafficLightsMeter.channelDisplay(for: reading)
        #expect(display.side == .neutral)
        #expect(display.barFill == 0)
    }

    @Test("Highlight lean fills only the over side")
    func overExposureDisplay() {
        let reading = TrafficLightsChannelReading(level: 0.75, clip: false, crush: false)
        let display = TrafficLightsMeter.channelDisplay(for: reading)
        #expect(display.side == .over)
        #expect(abs(display.barFill - 0.5) < 0.0001)
    }

    @Test("Shadow lean fills only the under side")
    func underExposureDisplay() {
        let reading = TrafficLightsChannelReading(level: 0.25, clip: false, crush: false)
        let display = TrafficLightsMeter.channelDisplay(for: reading)
        #expect(display.side == .under)
        #expect(abs(display.barFill - 0.5) < 0.0001)
    }

    @Test("Clip and crush flags stay independent of bar side")
    func clipCrushPreserveSide() {
        let clipped = TrafficLightsChannelReading(level: 0.98, clip: true, crush: false)
        let crushed = TrafficLightsChannelReading(level: 0.02, clip: false, crush: true)
        #expect(TrafficLightsMeter.channelDisplay(for: clipped).side == .over)
        #expect(TrafficLightsMeter.channelDisplay(for: crushed).side == .under)
        #expect(clipped.clip)
        #expect(crushed.crush)
    }

    @Test("Dead zone suppresses directional fill near centre")
    func balanceDeadZone() {
        let nearCentre = TrafficLightsChannelReading(
            level: TrafficLightsMeter.balanceCenter + 0.02, clip: false, crush: false)
        #expect(TrafficLightsMeter.channelDisplay(for: nearCentre).side == .neutral)
    }

    @Test("Balanced mid grey yields neutral bars and quiet lights")
    func balancedGreyIntegration() {
        let midNative = Int(
            ExposureSignalMapping(curve: .redLog3G10).middleGrayNative.rounded())
        let points = (0..<100).map { index in
            ScopePoint(
                xRatio: Double(index) / 100, red: UInt8(midNative), green: UInt8(midNative),
                blue: UInt8(midNative), luma: UInt8(midNative))
        }
        var hist = [Int](repeating: 0, count: 256)
        hist[midNative] = 100
        let samples = ScopeSamples(
            histogramLuma: hist, histogramRed: hist, histogramGreen: hist, histogramBlue: hist,
            points: points)
        let reading = TrafficLightsMeter.measure(
            samples: samples, noiseFloorCompensation: .zero, curve: .redLog3G10)
        for channel in [reading.red, reading.green, reading.blue] {
            let display = TrafficLightsMeter.channelDisplay(for: channel)
            #expect(display.side == .neutral)
            #expect(display.barFill == 0)
            #expect(!channel.clip)
            #expect(!channel.crush)
        }
    }

    @Test("High key scene leans over and may clip without crushing")
    func highKeyScene() {
        let clipNative = Int(
            ExposureScale.signalNative(referenceIRE: 100, curve: .redLog3G10).rounded())
        let points = (0..<100).map { index in
            ScopePoint(
                xRatio: Double(index) / 100, red: UInt8(clipNative), green: UInt8(clipNative),
                blue: UInt8(clipNative), luma: UInt8(clipNative))
        }
        var hist = [Int](repeating: 0, count: 256)
        hist[clipNative] = 100
        let samples = ScopeSamples(
            histogramLuma: hist, histogramRed: hist, histogramGreen: hist, histogramBlue: hist,
            points: points)
        let reading = TrafficLightsMeter.measure(
            samples: samples, noiseFloorCompensation: .zero, curve: .redLog3G10)
        #expect(TrafficLightsMeter.channelDisplay(for: reading.red).side == .over)
        #expect(reading.red.clip)
        #expect(!reading.red.crush)
    }

    @Test("Crushed blacks lean under and light the crush indicator")
    func crushedBlacksIntegration() {
        let toeFloor = ScopeSampler.trafficCrushFloor(curve: .redLog3G10)
        let points = (0..<100).map { index in
            ScopePoint(
                xRatio: Double(index) / 100, red: 0, green: 0, blue: UInt8(toeFloor), luma: 0)
        }
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        blue[toeFloor] = 100
        let samples = ScopeSamples(
            histogramLuma: blue, histogramRed: red, histogramGreen: green, histogramBlue: blue,
            points: points)
        let reading = TrafficLightsMeter.measure(
            samples: samples, noiseFloorCompensation: .zero, curve: .redLog3G10)
        let display = TrafficLightsMeter.channelDisplay(for: reading.blue)
        #expect(display.side == .under)
        #expect(display.barFill > 0)
        #expect(reading.blue.crush)
        #expect(!reading.blue.clip)
    }

    @Test("Traffic lights prefer histogram median when bins are populated")
    func histogramPreferredOverPoints() {
        let clipNative = Int(
            ExposureScale.signalNative(referenceIRE: 100, curve: .redLog3G10).rounded())
        let shadowNative = 40
        var red = [Int](repeating: 0, count: 256)
        red[shadowNative] = 1
        red[clipNative] = 1
        let samples = ScopeSamples(
            histogramLuma: red, histogramRed: red, histogramGreen: red, histogramBlue: red,
            points: [
                ScopePoint(
                    xRatio: 0.2, red: UInt8(clipNative), green: 0, blue: 0, luma: 0),
                ScopePoint(
                    xRatio: 0.8, red: UInt8(shadowNative), green: 0, blue: 0, luma: 0),
            ])
        let level = TrafficLightsMeter.channelLevel(
            samples: samples, channel: .red, curve: .redLog3G10)
        let histogramMedian = TrafficLightsMeter.channelLevel(
            histogram: red, curve: .redLog3G10)
        #expect(abs(level - histogramMedian) < 0.0001)
    }

    @Test("Mid underexposure leans under without lighting crush")
    func midUnderexposedNoCrush() {
        let shadowNative = 55
        let points = (0..<100).map { index in
            ScopePoint(
                xRatio: Double(index) / 100, red: UInt8(shadowNative), green: UInt8(shadowNative),
                blue: UInt8(shadowNative), luma: UInt8(shadowNative))
        }
        var hist = [Int](repeating: 0, count: 256)
        hist[shadowNative] = 100
        let samples = ScopeSamples(
            histogramLuma: hist, histogramRed: hist, histogramGreen: hist, histogramBlue: hist,
            points: points)
        let reading = TrafficLightsMeter.measure(
            samples: samples, noiseFloorCompensation: .zero, curve: .redLog3G10)
        for channel in [reading.red, reading.green, reading.blue] {
            let display = TrafficLightsMeter.channelDisplay(for: channel)
            #expect(display.side == .under)
            #expect(!channel.crush)
            #expect(!channel.clip)
        }
    }
}
