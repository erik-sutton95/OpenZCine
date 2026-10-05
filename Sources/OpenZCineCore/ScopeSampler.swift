import Foundation
import OpenCineMedia

/// One sampled pixel feeding the waveform and parade scopes: its horizontal position (0–1 across the
/// frame) and its 8-bit channel values plus Rec.709 luma. Compact by design — a frame yields
/// thousands of these.
public struct ScopePoint: Equatable, Sendable {
    public let xRatio: Double
    /// Vertical position 0…1 across the sampled frame (0 when unknown / legacy points).
    public let yRatio: Double
    /// Sample-buffer column in pixels, or `-1` when unavailable.
    public let sampleX: Int
    /// Sample-buffer row in pixels, or `-1` when unavailable.
    public let sampleY: Int
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let luma: UInt8

    public init(
        xRatio: Double,
        yRatio: Double = 0,
        sampleX: Int = -1,
        sampleY: Int = -1,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        luma: UInt8
    ) {
        self.xRatio = xRatio
        self.yRatio = yRatio
        self.sampleX = sampleX
        self.sampleY = sampleY
        self.red = red
        self.green = green
        self.blue = blue
        self.luma = luma
    }
}

/// The product of sampling one frame for the scopes: per-channel 256-bin histograms (for the
/// histogram scope) and the sampled points (for the waveform and parade traces).
public struct ScopeSamples: Equatable, Sendable {
    public let histogramLuma: [Int]
    public let histogramRed: [Int]
    public let histogramGreen: [Int]
    public let histogramBlue: [Int]
    public let points: [ScopePoint]

    public init(
        histogramLuma: [Int], histogramRed: [Int], histogramGreen: [Int], histogramBlue: [Int],
        points: [ScopePoint]
    ) {
        self.histogramLuma = histogramLuma
        self.histogramRed = histogramRed
        self.histogramGreen = histogramGreen
        self.histogramBlue = histogramBlue
        self.points = points
    }

    public static let empty = ScopeSamples(
        histogramLuma: Array(repeating: 0, count: 256),
        histogramRed: Array(repeating: 0, count: 256),
        histogramGreen: Array(repeating: 0, count: 256),
        histogramBlue: Array(repeating: 0, count: 256),
        points: [])
}

/// Samples an RGBA pixel buffer into scope data, mirroring the prototype's stride-3 sweep: walk the
/// frame every `stride` pixels in both axes, accumulate per-channel histograms, and record each
/// sampled pixel as a `ScopePoint`. Pure and portable — the shell supplies a (downsampled) buffer
/// and renders the result; all the IRE placement is left to `ExposureScale` at draw time.
public enum ScopeSampler {
    /// - Parameters:
    ///   - rgba: tightly- or row-padded RGBA8 bytes (`bytesPerRow` describes the stride).
    ///   - bytesPerRow: bytes per row; pass `width * 4` for a tightly-packed buffer.
    ///   - stride: sampling step in pixels along both axes (the prototype uses 3).
    public static func sample(
        rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int, stride: Int = 3,
        includePoints: Bool = true
    ) -> ScopeSamples {
        let raw = OpenCineMedia.ScopeSampler.sampleRaw(bytes: rgba, width: width, height: height,
            bytesPerRow: bytesPerRow, transfer: .rec709, includePoints: includePoints,
            layout: .rgba, stride: stride, includeSampleCoordinates: true, requireCompleteRows: true)
        return sourceSamples(raw)
    }

    /// Exact legacy representation bridge. Only absent shared coordinates use the old -1 value.
    public static func sourceSamples(_ raw: OpenCineMedia.ScopeSamples) -> ScopeSamples {
        return ScopeSamples(histogramLuma: raw.histogramLuma, histogramRed: raw.histogramRed,
            histogramGreen: raw.histogramGreen, histogramBlue: raw.histogramBlue,
            points: raw.points.map { point in
                ScopePoint(xRatio: point.xRatio, yRatio: point.yRatio,
                    sampleX: point.sampleX ?? -1, sampleY: point.sampleY ?? -1,
                    red: point.red, green: point.green, blue: point.blue, luma: point.luma)
            })
    }

    /// Traffic-light clip/crush flags from scope samples. Always computed from the per-channel
    /// histograms: they carry the identical integer counts as the sampled points (same pixels, same
    /// `sample()` loop, so `sum(histogram) == points.count`) but at a fixed 256-bin cost instead of
    /// six full linear scans + six transient arrays over the whole point buffer each tick. The GPU
    /// sampler also supplies empty `points`, so the histogram path is the only correct one there.
    public static func trafficLights(
        samples: ScopeSamples, curve: ExposureToneCurve, threshold: Double = 0.10
    ) -> HistogramTrafficLights {
        trafficLights(
            samples: samples, mapping: ExposureSignalMapping(curve: curve), threshold: threshold)
    }

    public static func trafficLights(
        samples: ScopeSamples, mapping: ExposureSignalMapping, threshold: Double = 0.10
    ) -> HistogramTrafficLights {
        trafficLights(
            red: samples.histogramRed, green: samples.histogramGreen,
            blue: samples.histogramBlue, mapping: mapping, threshold: threshold)
    }

    /// Median reference-IRE level for one channel on the waveform axis — matches parade placement.
    public static func medianWaveformLevel(
        points: [ScopePoint], curve: ExposureToneCurve, channel: (ScopePoint) -> UInt8
    ) -> Double {
        medianWaveformLevel(
            points: points, mapping: ExposureSignalMapping(curve: curve), channel: channel)
    }

    public static func medianWaveformLevel(
        points: [ScopePoint], mapping: ExposureSignalMapping, channel: (ScopePoint) -> UInt8
    ) -> Double {
        guard !points.isEmpty else { return 0 }
        var levels = ContiguousArray<Double>()
        levels.reserveCapacity(points.count)
        for point in points {
            levels.append(
                ScopeDisplayScale.waveformLevel(
                    signalNative: Double(channel(point)), mapping: mapping))
        }
        let mid = levels.count / 2
        if levels.count.isMultiple(of: 2) {
            let lower = orderStatistic(&levels, rank: mid - 1)
            let upper = orderStatistic(&levels, rank: mid)
            return (lower + upper) / 2
        }
        return orderStatistic(&levels, rank: mid)
    }

    /// Returns the element that would sit at `rank` in a sorted copy (`rank` is 0-based).
    private static func orderStatistic(_ values: inout ContiguousArray<Double>, rank: Int) -> Double
    {
        var low = 0
        var high = values.count - 1
        while low < high {
            let pivotIndex = partition(&values, low: low, high: high)
            if pivotIndex == rank { return values[pivotIndex] }
            if pivotIndex < rank {
                low = pivotIndex + 1
            } else {
                high = pivotIndex - 1
            }
        }
        return values[low]
    }

    private static func partition(
        _ values: inout ContiguousArray<Double>, low: Int, high: Int
    ) -> Int {
        let pivotValue = values[high]
        var storeIndex = low
        for index in low..<high where values[index] < pivotValue {
            values.swapAt(index, storeIndex)
            storeIndex += 1
        }
        values.swapAt(storeIndex, high)
        return storeIndex
    }

    /// Median reference-IRE level from a 256-bin native histogram (GPU histogram path).
    public static func medianWaveformLevel(histogram: [Int], curve: ExposureToneCurve) -> Double {
        medianWaveformLevel(histogram: histogram, mapping: ExposureSignalMapping(curve: curve))
    }

    public static func medianWaveformLevel(
        histogram: [Int], mapping: ExposureSignalMapping
    ) -> Double {
        guard histogram.count == 256 else { return 0 }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0 }
        let target = total / 2
        var cumulative = 0
        for native in 0..<256 {
            cumulative += histogram[native]
            if cumulative > target || (cumulative == target && total.isMultiple(of: 2)) {
                return ScopeDisplayScale.waveformLevel(
                    signalNative: Double(native), mapping: mapping)
            }
        }
        return ScopeDisplayScale.waveformLevel(signalNative: 255, mapping: mapping)
    }

    /// Whether each channel piles up enough energy at the crush (black) or clip (white) edge to
    /// warrant a histogram "traffic light". `threshold` is the fraction of a channel's pixels in
    /// the narrow crush/clip band (e.g. `0.10` = 10%).
    public static func trafficLights(
        red: [Int], green: [Int], blue: [Int], curve: ExposureToneCurve, threshold: Double = 0.10
    ) -> HistogramTrafficLights {
        trafficLights(
            red: red, green: green, blue: blue,
            mapping: ExposureSignalMapping(curve: curve), threshold: threshold)
    }

    public static func trafficLights(
        red: [Int], green: [Int], blue: [Int], mapping: ExposureSignalMapping,
        threshold: Double = 0.10
    ) -> HistogramTrafficLights {
        let clipEdge = trafficClipEdge(mapping: mapping)
        let crushFloor = trafficCrushFloor(mapping: mapping)
        let crushEdge = trafficCrushEdge(mapping: mapping)
        func clips(_ histogram: [Int]) -> Bool {
            edgeEnergy(histogram, from: clipEdge, to: 255) > threshold
        }
        func crushes(_ histogram: [Int]) -> Bool {
            // Only the narrow band at the log toe floor counts — not legal black (native 16) or other
            // sub-floor codes that sit below the calibrated shadow anchor.
            edgeEnergy(histogram, from: crushFloor, to: crushEdge) > threshold
        }
        return HistogramTrafficLights(
            crushRed: crushes(red), crushGreen: crushes(green), crushBlue: crushes(blue),
            clipRed: clips(red), clipGreen: clips(green), clipBlue: clips(blue))
    }

    /// Native code at reference 100 (clip) — upper traffic-light edge.
    public static func trafficClipEdge(curve: ExposureToneCurve) -> Int {
        trafficClipEdge(mapping: ExposureSignalMapping(curve: curve))
    }

    public static func trafficClipEdge(mapping: ExposureSignalMapping) -> Int {
        min(
            255,
            max(0, Int(mapping.clipNative.rounded(.up))))
    }

    /// Native code at reference 0 (log toe floor) — lower traffic-light band start.
    public static func trafficCrushFloor(curve: ExposureToneCurve) -> Int {
        trafficCrushFloor(mapping: ExposureSignalMapping(curve: curve))
    }

    public static func trafficCrushFloor(mapping: ExposureSignalMapping) -> Int {
        min(
            255,
            max(0, Int(mapping.blackNative.rounded(.down))))
    }

    /// Native code at reference ~2 IRE — upper bound of the crush band (JPEG / calibration tolerance).
    public static func trafficCrushEdge(curve: ExposureToneCurve) -> Int {
        trafficCrushEdge(mapping: ExposureSignalMapping(curve: curve))
    }

    public static func trafficCrushEdge(mapping: ExposureSignalMapping) -> Int {
        min(
            255,
            max(0, Int(mapping.signalNative(monitorPercent: 2).rounded(.up))))
    }

    /// Fraction of a 256-bin histogram's energy in the inclusive bin range `from...to`.
    private static func edgeEnergy(_ histogram: [Int], from: Int, to: Int) -> Double {
        guard histogram.count == 256, from <= to, from >= 0, to <= 255 else { return 0 }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(histogram[from...to].reduce(0, +)) / Double(total)
    }
}

/// Which histogram traffic lights are lit: a crush (black-edge) and clip (white-edge) flag per RGB
/// channel.
public struct HistogramTrafficLights: Equatable, Sendable {
    public var crushRed: Bool
    public var crushGreen: Bool
    public var crushBlue: Bool
    public var clipRed: Bool
    public var clipGreen: Bool
    public var clipBlue: Bool

    public init(
        crushRed: Bool, crushGreen: Bool, crushBlue: Bool,
        clipRed: Bool, clipGreen: Bool, clipBlue: Bool
    ) {
        self.crushRed = crushRed
        self.crushGreen = crushGreen
        self.crushBlue = crushBlue
        self.clipRed = clipRed
        self.clipGreen = clipGreen
        self.clipBlue = clipBlue
    }

    public static let none = HistogramTrafficLights(
        crushRed: false, crushGreen: false, crushBlue: false,
        clipRed: false, clipGreen: false, clipBlue: false)
}
