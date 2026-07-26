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

        /// The shipped detector, on a real frame.
        ///
        /// This used to be two hand-written transcriptions — one of the Android kernel and one
        /// approximating Core Image — and they disagreed with each other AND with what shipped: the
        /// Core Image one gated on the square root of the coarse operator and compared the threshold
        /// squared, so it was scoring a linear-domain detector while iOS renders a squared-domain
        /// one. A harness that scores something other than what ships is how the previous round went
        /// wrong, so there is now exactly one implementation — `Peaking.overlay` — and it is checked
        /// against the live Core Image graph in `RunnerTests`.
        private static func overlay(
            _ frame: Frame, sensitivity: Peaking.Sensitivity = .medium, gateScale: Double = 1
        ) -> [Double] {
            Peaking.overlay(
                grey: frame.grey, width: frame.width, height: frame.height,
                sensitivity: sensitivity, gateScale: gateScale
            ).stroke
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

            // `coarseP90` measures a magnitude; the detector's gate lives in the operator's
            // SQUARED domain, so the correction is squared — `Peaking.gateScale` owns that so
            // neither shell has to remember to do it.
            let logInk = Self.ink(Self.overlay(log))
            let sdrInk = Self.ink(Self.overlay(sdr))
            let correctedInk = Self.ink(
                Self.overlay(
                    sdr,
                    gateScale: Peaking.gateScale(
                        gradientScale: Peaking.displayReferredGradientScale)))
            // Uncorrected, the SDR feed paints materially more; corrected, it lands close to the
            // log feed it should match. Not exactly — `displayReferredGradientScale` is a single
            // number standing in for a curve, and a frame's gradients come from every luminance
            // level, so the residual is ~12% here. That is the accuracy the constant claims, and
            // closing it needs a hardware A/B rather than a tighter bound. [verify-on-HW]
            #expect(sdrInk > logInk * 1.05)
            #expect(abs(correctedInk - logInk) < logInk * 0.15)
        }

        // MARK: Characterisation

        /// Records where the detector stands on real frames. The numbers are deliberately loose
        /// bounds around today's behaviour, not targets — their job is to make the next change
        /// state what it moved and in which direction.
        @Test("The sweep is scored end to end, and the numbers are recorded")
        func corpusBaseline() throws {
            var report: [String] = ["frame          ink     fragmented"]
            for name in ["zr-sweep-00", "zr-sweep-12", "zr-sweep-19", "zr-sweep-24"] {
                let frame = try Self.load(name)
                let mask = Self.overlay(frame)
                report.append(
                    String(
                        format: "%@   %6.3f%%      %4.1f%%",
                        name, Self.ink(mask),
                        Self.fragmentation(mask, width: frame.width, height: frame.height)))
            }
            for step in Peaking.Sensitivity.allCases {
                let frame = try Self.load("zr-sweep-19")
                let quiet = try Self.load("zr-sweep-00")
                report.append(
                    String(
                        format: "%-4@ gate %.5f  focused ink %6.3f%%  defocused ink %6.3f%%",
                        step.rawValue as NSString, step.noiseGate,
                        Self.ink(Self.overlay(frame, sensitivity: step)),
                        Self.ink(Self.overlay(quiet, sensitivity: step))))
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
            // Measured: 2.31% against 0.000%. The old wide-tap detector managed 5.95% against
            // 0.042% — about 140:1, already good — and the rebuilt one drives the false-positive
            // floor to zero outright, so the separation is no longer a ratio at all.
            #expect(sharp > 1, "best focus must paint")
            // Ratchet on today's floor, so a change that makes defocused frames noisier fails
            // here rather than on Erik's phone.
            #expect(quiet == 0)
        }

        /// What the rebuild actually bought, against the frame that showed the problem.
        ///
        /// This test used to assert the SHAPE of the false positives: a fully defocused frame
        /// painted little in total (0.042%) but four fifths of it stood alone as isolated specks,
        /// which read as noise however few of them there were. That was the lever — remove
        /// isolated paint and you remove mostly false positives.
        ///
        /// It no longer applies, because there is nothing left to remove. The measured detector
        /// paints EXACTLY NOTHING on a fully defocused frame at every sensitivity, so the speck
        /// analysis has no subject. What is worth guarding now is the pair of facts that replaced
        /// it: full defocus paints nothing, and what best focus paints reads as lines.
        @Test("Full defocus paints nothing at all, and best focus paints lines")
        func defocusPaintsNothingAndFocusPaintsLines() throws {
            let defocused = try Self.load("zr-sweep-00")
            let focused = try Self.load("zr-sweep-19")
            for sensitivity in Peaking.Sensitivity.allCases {
                #expect(
                    Self.ink(Self.overlay(defocused, sensitivity: sensitivity)) == 0,
                    "\(sensitivity) painted a frame with nothing in the focus plane")
            }
            let solid = Self.overlay(focused)
            #expect(Self.ink(solid) > 1)
            // Continuity is the metric whose absence let a regression ship — a line broken into
            // dashes reads as more noise than a solid line while putting LESS ink on screen. The
            // closing is what holds this down; 14.8% measured, and note that a genuine 1px line
            // has exactly two painted neighbours so it counts as "isolated" here too, which is
            // most of what remains.
            #expect(
                Self.fragmentation(solid, width: focused.width, height: focused.height) < 25)
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
