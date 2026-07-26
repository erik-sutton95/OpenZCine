import Foundation
import Testing

@testable import OpenZCineCore

#if canImport(ImageIO)
    import CoreGraphics
    import ImageIO

    /// Focus peaking scored against frames the ZR actually sent.
    ///
    /// Everything before this was scored on synthetic blur and synthetic JPEG, and that rig said
    /// peaking had improved on the day it regressed on hardware — because it counted how much ink
    /// was on screen, and what had gone wrong was continuity. A line broken into dashes reads as
    /// more noise than a solid line while putting LESS ink on screen, so ink alone can move the
    /// wrong way and look right. Hence ``fragmentation``, and hence real frames.
    ///
    /// The corpus is one focus sweep captured through `DemoHarness.captureLiveViewObject` at the
    /// configuration users actually run — Stream Preset Quality, Quality Bias Size, the most
    /// compressed grade — with the camera static and only focus moving. That makes the labels
    /// objective rather than my opinion: frame 00 is fully defocused, so every painted pixel in it
    /// is a false positive by construction, and frame 19 is best focus. The sweep even carries its
    /// own ordering, since sharper frames hold more high-frequency detail and compress worse
    /// (15.5 KB at 00 rising to 30.3 KB at 19).
    @Suite("Focus peaking on real ZR frames")
    struct PeakingCorpusTests {

        // MARK: Corpus

        /// A captured LiveViewObject, decoded to a normalised grey plane the detector can read.
        private struct Frame {
            let name: String
            let width: Int
            let height: Int
            let grey: [Double]
        }

        private static func load(_ name: String) throws -> Frame {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/peaking/\(name).bin")
            let object = try Data(contentsOf: url)
            // Parsed by the shipped parser, so the corpus doubles as the first real-hardware
            // exercise of PTPLiveViewObject — every other test builds its bytes by hand.
            let jpeg = try PTPLiveViewObject.jpeg(from: object)
            let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try #require(
                CGContext(
                    data: &pixels, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let grey = (0..<(width * height)).map { i in
                (Double(pixels[i * 4]) + Double(pixels[i * 4 + 1]) + Double(pixels[i * 4 + 2]))
                    / 3.0 / 255.0
            }
            return Frame(name: name, width: width, height: height, grey: grey)
        }

        // MARK: Detector under test

        /// The overlay the GPU shells produce, evaluated on the CPU.
        ///
        /// Deliberately a transcription of the shipped GLES2/Vulkan/AGSL kernel rather than a
        /// tidied-up version: a harness that scores something other than what ships is how the
        /// last round went wrong. Phase 2 moves this into `Peaking` as the single reference the
        /// shells mirror, and this becomes a call rather than a copy.
        private static func overlay(
            _ frame: Frame, sensitivity: Peaking.Sensitivity = .medium
        ) -> [Double] {
            let w = frame.width
            let h = frame.height
            let p = frame.grey
            let gate = sensitivity.noiseGate
            let threshold = sensitivity.wideTapRatioThreshold
            let scale = max(1, Int((Double(max(w, h)) / Peaking.referenceLongSide).rounded()))
            let inset = Int(Peaking.edgeInset) + 2 * scale
            var mask = [Double](repeating: 0, count: w * h)

            func grad(_ x: Int, _ y: Int, _ s: Int) -> Double {
                Peaking.gradientMagnitude(
                    left: p[y * w + x - s], right: p[y * w + x + s],
                    up: p[(y - s) * w + x], down: p[(y + s) * w + x], spacing: Double(s))
            }
            func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
                let t = min(max((x - e0) / (e1 - e0), 0), 1)
                return t * t * (3 - 2 * t)
            }

            // Transcribed from the shipped kernel down to the antialiasing width: a plain
            // smoothstep gate on the coarse gradient, and the ratio ramped over `aa`.
            let aa = 0.06
            for y in inset..<(h - inset) {
                for x in inset..<(w - inset) {
                    let fine = grad(x, y, scale)
                    let coarse = grad(x, y, scale * 2)
                    let ratio = Peaking.sharpnessRatio(fine: fine, coarse: coarse)
                    let confidence = smoothstep(gate * 0.7, gate, coarse)
                    mask[y * w + x] = smoothstep(threshold, threshold + aa, ratio) * confidence
                }
            }
            return mask
        }

        /// The overlay the **Core Image** chain produces — the iOS path, and the one being judged
        /// on hardware. Scored separately because it is a genuinely different detector: `CIEdges`
        /// is a 2×2 forward difference and is quadratic in the gradient, which is why its
        /// thresholds are roughly the square of the wide-tap ones and why the two paths cannot
        /// share a gate. Approximated on the CPU rather than run through Core Image so the whole
        /// harness stays one comparable measurement.
        private static func reblurOverlay(
            _ frame: Frame, sensitivity: Peaking.Sensitivity = .medium, gateScale: Double = 1
        ) -> [Double] {
            let w = frame.width
            let h = frame.height
            let p = frame.grey
            let gate = sensitivity.reblurNoiseGate * gateScale
            let threshold = sensitivity.reblurRatioThreshold
            let inset = Int(Peaking.edgeInset) + 3
            var mask = [Double](repeating: 0, count: w * h)

            // The coarse scale is a re-blur by `reblurRadius`, approximated with a 3-tap binomial.
            var blurred = [Double](repeating: 0, count: w * h)
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    blurred[y * w + x] =
                        (p[y * w + x] * 4 + p[y * w + x - 1] + p[y * w + x + 1]
                            + p[(y - 1) * w + x] + p[(y + 1) * w + x]) / 8
                }
            }
            /// `CIEdges` is a 2×2 forward difference, and its output is the SQUARED gradient.
            func edges(_ s: [Double], _ x: Int, _ y: Int) -> Double {
                let dx = s[y * w + x + 1] - s[y * w + x]
                let dy = s[(y + 1) * w + x] - s[y * w + x]
                return dx * dx + dy * dy
            }
            func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
                let t = min(max((x - e0) / (e1 - e0), 0), 1)
                return t * t * (3 - 2 * t)
            }
            let aa = 0.12
            for y in inset..<(h - inset) {
                for x in inset..<(w - inset) {
                    let fine = edges(p, x, y)
                    let coarse = edges(blurred, x, y)
                    // Squared domain on both terms, so the threshold is compared squared too.
                    let ratio = fine / max(coarse, 1e-12)
                    let confidence = smoothstep(gate * 0.7, gate, coarse.squareRoot())
                    mask[y * w + x] =
                        smoothstep(
                            threshold * threshold, (threshold + aa) * (threshold + aa), ratio)
                        * confidence
                }
            }
            return mask
        }

        // MARK: Metrics

        /// Mean overlay opacity, as a percentage of the frame — "how much red is on screen".
        private static func ink(_ mask: [Double]) -> Double {
            100 * mask.reduce(0, +) / Double(mask.count)
        }

        /// Share of painted pixels that stand alone — the metric whose absence let a regression
        /// ship. Peaking should read as lines; isolated specks read as noise however few of them
        /// there are, and a stricter setting produces MORE of them, not fewer.
        private static func fragmentation(_ mask: [Double], width w: Int, height h: Int) -> Double {
            var painted = 0
            var isolated = 0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) where mask[y * w + x] > 0.35 {
                    painted += 1
                    var neighbours = 0
                    for oy in -1...1 {
                        for ox in -1...1 where !(ox == 0 && oy == 0) {
                            if mask[(y + oy) * w + (x + ox)] > 0.35 { neighbours += 1 }
                        }
                    }
                    if neighbours <= 2 { isolated += 1 }
                }
            }
            return painted > 0 ? 100 * Double(isolated) / Double(painted) : 0
        }

        /// The same frame as a DISPLAY-REFERRED preview — the log frame through the app's own
        /// Log3G10→709 tone map, standing in for the photography feed's SDR rendering.
        private static func displayReferred(_ frame: Frame) -> Frame {
            let cube = MonitorLUT.log3G10Rec709.cube()
            let grey = frame.grey.map { value -> Double in
                let v = Float(value)
                let (r, g, b) = cube.map(red: v, green: v, blue: v)
                return (Double(r) + Double(g) + Double(b)) / 3
            }
            return Frame(name: frame.name, width: frame.width, height: frame.height, grey: grey)
        }

        /// Mean coarse gradient magnitude at the 90th percentile — the quantity the noise gate is
        /// compared against, and therefore the one whose shift between curves is the bug.
        private static func coarseP90(_ frame: Frame) -> Double {
            let w = frame.width
            let h = frame.height
            let p = frame.grey
            var blurred = [Double](repeating: 0, count: w * h)
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    blurred[y * w + x] =
                        (p[y * w + x] * 4 + p[y * w + x - 1] + p[y * w + x + 1]
                            + p[(y - 1) * w + x] + p[(y + 1) * w + x]) / 8
                }
            }
            var values: [Double] = []
            let inset = Int(Peaking.edgeInset) + 3
            for y in inset..<(h - inset) {
                for x in inset..<(w - inset) {
                    let dx = blurred[y * w + x + 1] - blurred[y * w + x]
                    let dy = blurred[(y + 1) * w + x] - blurred[y * w + x]
                    values.append((dx * dx + dy * dy).squareRoot())
                }
            }
            values.sort()
            return values[values.count * 9 / 10]
        }

        /// Photography mode's feed is display-referred, so the same scene hands the detector larger
        /// numbers than the log video feed the gates were calibrated on — which is why peaking
        /// behaved differently between the two modes. Guards both halves of the fix: that the shift
        /// is real and matches `displayReferredGradientScale`, and that applying the scale brings the
        /// two modes' ink back together.
        @Test("A sensitivity step means the same thing on log and display-referred feeds")
        func displayReferredGateScaleEqualisesModes() throws {
            let log = try Self.load("zr-sweep-19")
            let sdr = Self.displayReferred(log)

            let measured = Self.coarseP90(sdr) / Self.coarseP90(log)
            #expect(abs(measured - Peaking.displayReferredGradientScale) < 0.15)

            // `reblurOverlay` gates on the magnitude, so it takes the scale unsquared; the Core
            // Image detector works in `CIEdges`' squared domain and squares it (see
            // `PeakingSettings.gateScale`).
            let logInk = Self.ink(Self.reblurOverlay(log))
            let sdrInk = Self.ink(Self.reblurOverlay(sdr))
            let correctedInk = Self.ink(
                Self.reblurOverlay(sdr, gateScale: Peaking.displayReferredGradientScale))
            // Uncorrected, the SDR feed paints materially more; corrected, it lands within a tenth
            // of the log feed it should match.
            #expect(sdrInk > logInk * 1.05)
            #expect(abs(correctedInk - logInk) < logInk * 0.1)
        }

        // MARK: Characterisation

        /// Records where the detector stands on real frames. The numbers are deliberately loose
        /// bounds around today's behaviour, not targets — their job is to make the next change
        /// state what it moved and in which direction.
        @Test("The sweep is scored end to end, and the numbers are recorded")
        func corpusBaseline() throws {
            var report: [String] = ["            wide-tap (Android)     Core Image (iOS)"]
            for name in ["zr-sweep-00", "zr-sweep-12", "zr-sweep-19", "zr-sweep-24"] {
                let frame = try Self.load(name)
                let wide = Self.overlay(frame)
                let ci = Self.reblurOverlay(frame)
                report.append(
                    String(
                        format: "%@   ink %6.3f%% frag %4.1f%%    ink %6.3f%% frag %4.1f%%",
                        name, Self.ink(wide),
                        Self.fragmentation(wide, width: frame.width, height: frame.height),
                        Self.ink(ci),
                        Self.fragmentation(ci, width: frame.width, height: frame.height)))
            }
            for step in Peaking.Sensitivity.allCases {
                let frame = try Self.load("zr-sweep-19")
                let quiet = try Self.load("zr-sweep-00")
                report.append(
                    String(
                        format: "iOS %-4@ gate %.5f  focused ink %6.3f%%  defocused ink %6.3f%%",
                        step.rawValue as NSString, step.reblurNoiseGate,
                        Self.ink(Self.reblurOverlay(frame, sensitivity: step)),
                        Self.ink(Self.reblurOverlay(quiet, sensitivity: step))))
            }
            // Surfaces in the test log; `swift test` prints it on failure and with --verbose.
            print(report.joined(separator: "\n"))
            #expect(report.count == 8)
        }

        /// The reported failure, as an assertion against the frame that shows it.
        ///
        /// Frame 00 is fully defocused — nothing in it is in the focus plane — so the correct
        /// amount of peaking is none. Whatever it paints is the floor the rebuild has to drive
        /// down, and it must never be allowed to rise.
        @Test("A fully defocused frame paints far less than a focused one")
        func defocusedFrameStaysQuiet() throws {
            let defocused = try Self.load("zr-sweep-00")
            let focused = try Self.load("zr-sweep-19")
            let quiet = Self.ink(Self.overlay(defocused))
            let sharp = Self.ink(Self.overlay(focused))
            // On real frames this separation is far better than synthetic JPEG predicted —
            // 0.042% against 5.95%, about 140:1, where the synthetic rig suggested nearer 10:1.
            // Which means the complaint is NOT that the detector cannot tell focus from defocus.
            #expect(sharp > quiet * 50, "best focus must clearly outrank full defocus")
            // Ratchet on today's floor, so a change that makes defocused frames noisier fails
            // here rather than on Erik's phone.
            #expect(quiet < 0.10)
        }

        /// The actual shape of the complaint, and the lever the rebuild should pull.
        ///
        /// A defocused frame paints very little in total, yet reads as noisy — because what it
        /// paints is almost entirely ISOLATED. Four fifths of the paint on a fully defocused
        /// frame stands alone, against a quarter on the focused one. So the false positives are
        /// not merely fewer than the true ones, they are structurally different, and removing
        /// isolated paint is selective roughly 3:1 in the right direction on top of a detector
        /// that is already separating focus from defocus 140:1.
        ///
        /// Caveat worth keeping in view when this gets used: a one-pixel-wide LINE has exactly
        /// two painted neighbours, so the ≤2 rule counts it as isolated too. That is most of the
        /// residual 27% on the focused frame, and it means the neighbour threshold is the knob,
        /// not the idea.
        @Test("Defocused frames paint specks; focused frames paint lines")
        func falsePositivesAreIsolatedAndTrueOnesAreNot() throws {
            let defocused = try Self.load("zr-sweep-00")
            let focused = try Self.load("zr-sweep-19")
            let loose = Self.overlay(defocused)
            let solid = Self.overlay(focused)
            let looseFragmentation = Self.fragmentation(
                loose, width: defocused.width, height: defocused.height)
            let solidFragmentation = Self.fragmentation(
                solid, width: focused.width, height: focused.height)
            #expect(looseFragmentation > 70)
            #expect(solidFragmentation < 40)
            #expect(looseFragmentation > solidFragmentation * 2)
        }

        /// Sensitivity has to mean something on real frames, not just on synthetic edges.
        @Test("Low paints less than High on the same real frame")
        func sensitivityOrdersOnRealFrames() throws {
            let frame = try Self.load("zr-sweep-19")
            let low = Self.ink(Self.overlay(frame, sensitivity: .low))
            let high = Self.ink(Self.overlay(frame, sensitivity: .high))
            #expect(low < high)
        }
    }
#endif
