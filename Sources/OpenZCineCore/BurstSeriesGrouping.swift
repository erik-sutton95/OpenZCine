/// One media frame handed to burst detection. Platform-neutral so both shells feed their own
/// media records through the same grouping. `id` is opaque (the shell's clip id); grouping only
/// reads the capture identity, a pair stem, and a format signature.
public struct BurstFrame: Sendable, Equatable {
    public let id: String
    public let storageID: UInt32?
    public let handle: UInt32?
    /// PTP capture date `YYYYMMDDThhmmss` (or empty — an undated frame never joins a burst).
    public let captureDate: String
    /// Case-insensitive filename stem; RAW and JPEG of one shot share it.
    public let stem: String
    /// True for the RAW side of a RAW+JPEG pair (collapsed into the JPEG shot).
    public let isRaw: Bool
    /// Format + dimensions signature; frames must match to share a series.
    public let formatKey: String

    public init(
        id: String, storageID: UInt32?, handle: UInt32?, captureDate: String,
        stem: String, isRaw: Bool, formatKey: String
    ) {
        self.id = id
        self.storageID = storageID
        self.handle = handle
        self.captureDate = captureDate
        self.stem = stem
        self.isRaw = isRaw
        self.formatKey = formatKey
    }
}

/// A detected burst run: `memberIDs` in capture order; the representative is the first.
public struct BurstSeries: Sendable, Equatable {
    public let memberIDs: [String]

    public init(memberIDs: [String]) {
        self.memberIDs = memberIDs
    }

    public var representativeID: String { memberIDs[0] }
    public var count: Int { memberIDs.count }
}

/// Pure, app-side burst detection — no new protocol. A continuous-drive run groups in the body's
/// playback as a "series"; this reproduces that grouping from the same pragmatic signals the
/// RAW+JPEG pairing key already uses (contiguous same-storage handles, tight capture-time window,
/// shared format).
public enum BurstSeriesGrouping {
    /// Groups frames into burst series of at least `minCount` shots. A run extends while frames are
    /// on the same storage, share a `formatKey`, and each is within `windowSeconds` of the previous
    /// (capture dates carry 1-second resolution, so a gap larger than the window breaks the run).
    /// RAW+JPEG frames of one shot collapse to a single member (a burst of N pairs is one series of
    /// N shots, not 2N), so ordinary singles and lone pairs are never grouped. Undated or
    /// storage-less frames stay singletons. Input order is irrelevant — grouping sorts by capture
    /// identity so contiguity means capture order, not display order.
    public static func group(
        _ frames: [BurstFrame], minCount: Int = 3, windowSeconds: Int = 1
    ) -> [BurstSeries] {
        let shots = collapsePairs(frames)

        // Sort by capture identity so a run is contiguous in capture order.
        let sorted = shots.sorted { lhs, rhs in
            let ls = lhs.storageID ?? 0
            let rs = rhs.storageID ?? 0
            if ls != rs { return ls < rs }
            if lhs.captureDate != rhs.captureDate { return lhs.captureDate < rhs.captureDate }
            return (lhs.handle ?? 0) < (rhs.handle ?? 0)
        }

        var series: [BurstSeries] = []
        var run: [BurstFrame] = []
        func flush() {
            if run.count >= minCount { series.append(BurstSeries(memberIDs: run.map(\.id))) }
            run = []
        }
        for shot in sorted {
            guard shot.storageID != nil, let seconds = captureSeconds(shot.captureDate) else {
                flush()  // undated / storage-less frames can't burst — they break the run
                continue
            }
            if let last = run.last, let lastSeconds = captureSeconds(last.captureDate),
                last.storageID == shot.storageID, last.formatKey == shot.formatKey,
                seconds - lastSeconds <= windowSeconds
            {
                run.append(shot)
            } else {
                flush()
                run = [shot]
            }
        }
        flush()
        return series
    }

    /// One shot per `(storageID, stem)`; the JPEG side represents a RAW+JPEG pair. First appearance
    /// wins the ordering slot so a later RAW never reorders the shot.
    private static func collapsePairs(_ frames: [BurstFrame]) -> [BurstFrame] {
        var byKey: [String: BurstFrame] = [:]
        var order: [String] = []
        for frame in frames {
            let key = "\(frame.storageID.map(String.init) ?? "-")/\(frame.stem)"
            if let existing = byKey[key] {
                // Prefer the non-RAW (JPEG) side as the representative.
                if existing.isRaw, !frame.isRaw { byKey[key] = frame }
            } else {
                byKey[key] = frame
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Parses `YYYYMMDDThhmmss` to a monotonic second key with EXACT same-day differences; nil for
    /// an empty or malformed date. The calendar is approximate (ignores month lengths) on purpose:
    /// only differences within one run matter, and any cross-day gap lands far above the window,
    /// which correctly breaks a run — a continuous-drive burst never spans midnight.
    static func captureSeconds(_ captureDate: String) -> Int? {
        guard captureDate.count >= 15 else { return nil }
        let chars = Array(captureDate)
        guard chars[8] == "T" else { return nil }
        func number(_ start: Int, _ end: Int) -> Int? { Int(String(chars[start..<end])) }
        guard let year = number(0, 4), let month = number(4, 6), let day = number(6, 8),
            let hour = number(9, 11), let minute = number(11, 13), let second = number(13, 15)
        else { return nil }
        return ((((year * 12 + month) * 31 + day) * 24 + hour) * 60 + minute) * 60 + second
    }
}
