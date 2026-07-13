import Foundation

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

    /// Down-weights pixels that sit on HEVC macroblock edges where blocking reads as spatial noise.
    public static func blockEdgeWeight(
        sampleX: Int, sampleY: Int, blockSize: Int = 8
    ) -> Double {
        guard sampleX >= 0, sampleY >= 0, blockSize > 1 else { return 1 }
        let onXEdge = sampleX % blockSize == 0 || sampleX % blockSize == blockSize - 1
        let onYEdge = sampleY % blockSize == 0 || sampleY % blockSize == blockSize - 1
        switch (onXEdge, onYEdge) {
        case (true, true): return 0.22
        case (true, false), (false, true): return 0.48
        default: return 1
        }
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
        guard width > 0, height > 0, stride > 0, bytesPerRow >= width * 4,
            rgba.count >= bytesPerRow * height
        else { return .empty }

        var histY = [Int](repeating: 0, count: 256)
        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)
        var points = [ScopePoint]()
        if includePoints {
            let columns = (width + stride - 1) / stride
            let rows = (height + stride - 1) / stride
            points.reserveCapacity(columns * rows)
        }
        let widthDivisor = Double(width)
        let heightDivisor = Double(height)

        rgba.withUnsafeBufferPointer { buffer in
            var y = 0
            while y < height {
                let rowStart = y * bytesPerRow
                var x = 0
                while x < width {
                    let i = rowStart + x * 4
                    let r = buffer[i]
                    let g = buffer[i + 1]
                    let b = buffer[i + 2]
                    // Rec.709 luma, rounded to a code value (the prototype floors with `|0`, but
                    // rounding bins more accurately — and keeps pure white off the 254 boundary).
                    let lumaValue = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                    let luma = UInt8(min(255, max(0, lumaValue.rounded())))
                    histY[Int(luma)] += 1
                    histR[Int(r)] += 1
                    histG[Int(g)] += 1
                    histB[Int(b)] += 1
                    if includePoints {
                        points.append(
                            ScopePoint(
                                xRatio: Double(x) / widthDivisor,
                                yRatio: Double(y) / heightDivisor,
                                sampleX: x,
                                sampleY: y,
                                red: r,
                                green: g,
                                blue: b,
                                luma: luma)
                        )
                    }
                    x += stride
                }
                y += stride
            }
        }

        return ScopeSamples(
            histogramLuma: histY, histogramRed: histR, histogramGreen: histG, histogramBlue: histB,
            points: points)
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

/// Normalized RGB accumulated for one vectorscope density bin.
public struct VectorscopeColor: Equatable, Sendable {
    // Normalized components.
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Empty-bin colour.
    public static let black = VectorscopeColor(red: 0, green: 0, blue: 0)

    /// Converts average signal colour into a bright trace tint while retaining saturation and hue.
    /// Neutral bins become white; dark saturated bins remain readable instead of disappearing.
    public var traceTint: VectorscopeColor {
        let low = min(red, green, blue)
        let high = max(red, green, blue)
        let span = high - low
        guard high > 0.000_001, span > 0.000_001 else {
            return VectorscopeColor(red: 1, green: 1, blue: 1)
        }
        let saturation = min(1, max(0, span / high))
        func tint(_ component: Double) -> Double {
            let pure = (component - low) / span
            return (1 - saturation) + pure * saturation
        }
        return VectorscopeColor(red: tint(red), green: tint(green), blue: tint(blue))
    }
}

/// Chroma-plane (Cb×Cr) density bins for the vectorscope, accumulated from the same sampled
/// `ScopePoint`s the waveform and parade read. Per-bin channel sums retain trace colour without
/// duplicating the sampled point array in the renderer.
public struct VectorscopeBins: Equatable, Sendable {
    /// Largest supported grid axis. The UI uses 128; this upper bound prevents accidental public
    /// inputs from requesting multi-gigabyte backing arrays.
    public static let maximumBinCount = 1_024

    /// Bins per axis; `counts.count == binCount * binCount`. Row-major with Cb along x and Cr along
    /// y (row 0 is the most negative Cr — the renderer flips so +Cr points up).
    public let binCount: Int
    public let counts: [UInt32]
    private let redSums: [UInt32]
    private let greenSums: [UInt32]
    private let blueSums: [UInt32]
    /// Highest single-bin count (0 when empty) — the renderer's density normaliser.
    public let peak: UInt32

    /// Creates a density-only bin grid. Trace colour defaults to white for occupied bins.
    ///
    /// This compatibility initializer preserves the original public API from before per-bin colour
    /// accumulation was added. Invalid dimensions normalize to ``empty``.
    public init(binCount: Int, counts: [UInt32]) {
        guard let expected = Self.validElementCount(binCount: binCount), counts.count == expected
        else {
            self.init()
            return
        }
        self.init(
            uncheckedBinCount: binCount, counts: counts,
            redSums: [UInt32](repeating: 0, count: expected),
            greenSums: [UInt32](repeating: 0, count: expected),
            blueSums: [UInt32](repeating: 0, count: expected))
    }

    /// Creates a bin grid with matching count and RGB-sum arrays. Invalid dimensions normalize to
    /// ``empty`` so renderers can safely trust the square-grid invariant.
    public init(
        binCount: Int, counts: [UInt32], redSums: [UInt32], greenSums: [UInt32],
        blueSums: [UInt32]
    ) {
        guard let expected = Self.validElementCount(binCount: binCount),
            counts.count == expected, redSums.count == expected,
            greenSums.count == expected, blueSums.count == expected
        else {
            self.init()
            return
        }
        self.init(
            uncheckedBinCount: binCount, counts: counts,
            redSums: redSums, greenSums: greenSums, blueSums: blueSums)
    }

    private static func validElementCount(binCount: Int) -> Int? {
        guard binCount >= 0, binCount <= maximumBinCount else { return nil }
        let (count, overflow) = binCount.multipliedReportingOverflow(by: binCount)
        return overflow ? nil : count
    }

    private init() {
        self.init(
            uncheckedBinCount: 0, counts: [], redSums: [], greenSums: [], blueSums: [])
    }

    private init(
        uncheckedBinCount: Int, counts: [UInt32], redSums: [UInt32], greenSums: [UInt32],
        blueSums: [UInt32]
    ) {
        binCount = uncheckedBinCount
        self.counts = counts
        self.redSums = redSums
        self.greenSums = greenSums
        self.blueSums = blueSums
        peak = counts.max() ?? 0
    }

    /// Average normalized RGB for an occupied bin, or black for an empty/invalid bin.
    public func averageColor(at index: Int) -> VectorscopeColor {
        guard counts.indices.contains(index), counts[index] > 0,
            redSums.indices.contains(index), greenSums.indices.contains(index),
            blueSums.indices.contains(index)
        else { return .black }
        let divisor = Double(counts[index]) * 255
        return VectorscopeColor(
            red: Double(redSums[index]) / divisor,
            green: Double(greenSums[index]) / divisor,
            blue: Double(blueSums[index]) / divisor)
    }

    public static let empty = VectorscopeBins()
}

/// BT.709 RGB→CbCr conversion and 2D chroma-bin accumulation.
///
/// The vectorscope reads the MONITOR image: sampled clean points transformed through the
/// operator's active look (their LUT, or the built-in display tone map when none is on) via
/// ``monitorPoints(_:through:)``. Log-encoded camera codes carry almost no chroma spread, so a
/// source-referred vectorscope collapses into an unreadable centre dot — the monitor domain is
/// where chroma reading is meaningful. Waveform, parade, histogram, and traffic lights keep
/// reading the untouched source/log codes.
public enum VectorscopeSampler {
    /// BT.709 chroma for 8-bit R'G'B' code values; each component spans −0.5…+0.5.
    public static func chroma(red: UInt8, green: UInt8, blue: UInt8) -> (cb: Double, cr: Double) {
        chroma(
            red: Double(red) / 255, green: Double(green) / 255,
            blue: Double(blue) / 255)
    }

    /// Transforms clean sampled points into the monitor domain through `cube` (the operator's
    /// active LUT or the built-in display tone map). Spatial metadata is preserved.
    public static func monitorPoints(_ points: [ScopePoint], through cube: CubeLUT) -> [ScopePoint]
    {
        guard !points.isEmpty else { return [] }
        return points.map { point in
            let mapped = cube.map(
                red: Float(point.red) / 255, green: Float(point.green) / 255,
                blue: Float(point.blue) / 255)
            let red = byte(mapped.red)
            let green = byte(mapped.green)
            let blue = byte(mapped.blue)
            let luma = byte(
                0.2126 * mapped.red + 0.7152 * mapped.green + 0.0722 * mapped.blue)
            return ScopePoint(
                xRatio: point.xRatio, yRatio: point.yRatio,
                sampleX: point.sampleX, sampleY: point.sampleY,
                red: red, green: green, blue: blue, luma: luma)
        }
    }

    private static func byte(_ normalized: Float) -> UInt8 {
        UInt8(min(255, max(0, (Double(normalized) * 255).rounded())))
    }

    private static func chroma(
        red r: Double, green g: Double, blue b: Double
    ) -> (cb: Double, cr: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (cb: (b - y) / 1.8556, cr: (r - y) / 1.5748)
    }

    /// Accumulates sampled points into a `binCount`×`binCount` CbCr histogram. `gain` magnifies the
    /// trace around the centre (the operator's 1x/2x zoom); samples pushed outside the plot are
    /// dropped, matching a scope-tube edge clip.
    public static func accumulate(
        points: [ScopePoint], binCount: Int = 128, gain: Double = 1
    ) -> VectorscopeBins {
        guard binCount > 0, binCount <= VectorscopeBins.maximumBinCount, !points.isEmpty else {
            return .empty
        }
        let (elementCount, overflow) = binCount.multipliedReportingOverflow(by: binCount)
        guard !overflow else { return .empty }
        var counts = [UInt32](repeating: 0, count: elementCount)
        var redSums = [UInt32](repeating: 0, count: counts.count)
        var greenSums = [UInt32](repeating: 0, count: counts.count)
        var blueSums = [UInt32](repeating: 0, count: counts.count)
        let scale = Double(binCount - 1)
        for point in points {
            let (cb, cr) = chroma(red: point.red, green: point.green, blue: point.blue)
            let x = cb * gain + 0.5
            let y = cr * gain + 0.5
            guard x >= 0, x <= 1, y >= 0, y <= 1 else { continue }
            let column = Int((x * scale).rounded())
            let row = Int((y * scale).rounded())
            let index = row * binCount + column
            counts[index] &+= 1
            redSums[index] &+= UInt32(point.red)
            greenSums[index] &+= UInt32(point.green)
            blueSums[index] &+= UInt32(point.blue)
        }
        return VectorscopeBins(
            binCount: binCount, counts: counts,
            redSums: redSums, greenSums: greenSums, blueSums: blueSums)
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
