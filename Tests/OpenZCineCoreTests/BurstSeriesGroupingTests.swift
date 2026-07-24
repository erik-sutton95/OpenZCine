import Foundation
import Testing

@testable import OpenZCineCore

@Suite("Burst series grouping")
struct BurstSeriesGroupingTests {
    private func frame(
        _ id: String, storage: UInt32? = 1, handle: UInt32, date: String,
        stem: String? = nil, raw: Bool = false, format: String = "jpg|6048x4032"
    ) -> BurstFrame {
        BurstFrame(
            id: id, storageID: storage, handle: handle, captureDate: date,
            stem: stem ?? id, isRaw: raw, formatKey: format)
    }

    @Test func groupsAContiguousBurstOfThreeOrMore() {
        let frames = (0..<12).map {
            frame("f\($0)", handle: UInt32(100 + $0), date: "20260724T101500")
        }
        let series = BurstSeriesGrouping.group(frames)
        #expect(series.count == 1)
        #expect(series[0].count == 12)
        // Representative is the earliest frame (first by capture order).
        #expect(series[0].representativeID == "f0")
    }

    @Test func aGapLargerThanTheWindowBreaksTheSeries() {
        // Three at :00, then a 5s gap, then three at :05 — two separate runs.
        let a = (0..<3).map { frame("a\($0)", handle: UInt32(10 + $0), date: "20260724T101500") }
        let b = (0..<3).map { frame("b\($0)", handle: UInt32(20 + $0), date: "20260724T101505") }
        let series = BurstSeriesGrouping.group(a + b)
        #expect(series.count == 2)
        #expect(series.allSatisfy { $0.count == 3 })
    }

    @Test func onlyRunsMeetingTheThresholdSurvive() {
        // A 3-run, then a gap, then a 2-run — only the 3-run is a series.
        let a = (0..<3).map { frame("a\($0)", handle: UInt32(10 + $0), date: "20260724T101500") }
        let b = (0..<2).map { frame("b\($0)", handle: UInt32(20 + $0), date: "20260724T101512") }
        let series = BurstSeriesGrouping.group(a + b)
        #expect(series.count == 1)
        #expect(series[0].memberIDs == ["a0", "a1", "a2"])
    }

    @Test func singlesAndLonePairsAreNotSeries() {
        let single1 = frame("s1", handle: 1, date: "20260724T101500")
        let single2 = frame("s2", handle: 2, date: "20260724T101530")
        let jpeg = frame("p.jpg", handle: 3, date: "20260724T101600", stem: "p")
        let raw = frame(
            "p.nef", handle: 4, date: "20260724T101600", stem: "p", raw: true,
            format: "nef|6048x4032")
        #expect(BurstSeriesGrouping.group([single1, single2, jpeg, raw]).isEmpty)
        // A lone RAW+JPEG pair collapses to one shot, never a series.
        #expect(BurstSeriesGrouping.group([jpeg, raw]).isEmpty)
    }

    @Test func aBurstOfRawJpegPairsIsOneSeriesOfNShotsNotTwoN() {
        var frames: [BurstFrame] = []
        for i in 0..<6 {
            frames.append(
                frame(
                    "shot\(i).jpg", handle: UInt32(100 + i * 2), date: "20260724T101500",
                    stem: "shot\(i)"))
            frames.append(
                frame(
                    "shot\(i).nef", handle: UInt32(101 + i * 2), date: "20260724T101500",
                    stem: "shot\(i)", raw: true, format: "nef|6048x4032"))
        }
        let series = BurstSeriesGrouping.group(frames)
        #expect(series.count == 1)
        // N shots, not 2N frames — and the JPEG side represents each pair.
        #expect(series[0].count == 6)
        #expect(series[0].memberIDs.allSatisfy { $0.hasSuffix(".jpg") })
    }

    @Test func framesOnDifferentCardsDoNotShareASeries() {
        let a = (0..<2).map {
            frame("a\($0)", storage: 1, handle: UInt32(10 + $0), date: "20260724T101500")
        }
        let b = (0..<2).map {
            frame("b\($0)", storage: 2, handle: UInt32(20 + $0), date: "20260724T101500")
        }
        // 2 + 2 across two cards — neither card reaches the threshold of 3.
        #expect(BurstSeriesGrouping.group(a + b).isEmpty)
    }

    @Test func framesWithDifferentFormatsDoNotShareASeries() {
        let frames = [
            frame("a", handle: 1, date: "20260724T101500", format: "jpg|6048x4032"),
            frame("b", handle: 2, date: "20260724T101500", format: "jpg|1920x1080"),
            frame("c", handle: 3, date: "20260724T101500", format: "jpg|6048x4032"),
        ]
        #expect(BurstSeriesGrouping.group(frames).isEmpty)
    }

    @Test func undatedFramesNeverBurst() {
        let frames = (0..<4).map { frame("f\($0)", handle: UInt32(10 + $0), date: "") }
        #expect(BurstSeriesGrouping.group(frames).isEmpty)
    }

    @Test func inputOrderDoesNotAffectGrouping() {
        let frames = [
            frame("f2", handle: 12, date: "20260724T101500"),
            frame("f0", handle: 10, date: "20260724T101500"),
            frame("f1", handle: 11, date: "20260724T101500"),
        ]
        let series = BurstSeriesGrouping.group(frames)
        #expect(series.count == 1)
        // Sorted by capture identity, not the shuffled input order.
        #expect(series[0].memberIDs == ["f0", "f1", "f2"])
    }
}
