import Foundation

/// Resolution buckets for the Media browser filter chips (HD, 4K, 5.4K, 6K).
public enum MediaResolutionBucket: String, CaseIterable, Codable, Sendable {
    case hd = "HD"
    case fourK = "4K"
    case fiveFourK = "5.4K"
    case sixK = "6K"

    /// Classifies a horizontal pixel width into a bucket.
    public static func from(pixelWidth: UInt32) -> MediaResolutionBucket? {
        guard pixelWidth > 0 else { return nil }
        switch pixelWidth {
        case 6_000...: return .sixK
        case 5_300..<6_000: return .fiveFourK
        case 3_500..<5_300: return .fourK
        case 1_000..<3_500: return .hd
        default: return nil
        }
    }

    /// Best-effort bucket from filename tokens when metadata is missing.
    public static func fromFilename(_ filename: String) -> MediaResolutionBucket? {
        let upper = filename.uppercased()
        if upper.contains("6K") { return .sixK }
        if upper.contains("5.4K") || upper.contains("54K") { return .fiveFourK }
        if upper.contains("4K") || upper.contains("UHD") { return .fourK }
        if upper.contains("HD") || upper.contains("1080") { return .hd }
        return nil
    }

    /// Chooses a bucket from R3D source dimensions when linked, else proxy/clip pixels, then filename.
    public static func classify(
        filename: String,
        pixelWidth: UInt32?,
        sourcePixelWidth: UInt32?
    ) -> MediaResolutionBucket? {
        if let sourcePixelWidth {
            return from(pixelWidth: sourcePixelWidth)
        }
        if let pixelWidth {
            return from(pixelWidth: pixelWidth)
        }
        return fromFilename(filename)
    }
}

/// Nikon still image-size classes (L / M / S) for the Media browser SIZE chips.
///
/// A pixel width cannot name its own class: L is 6048 px on a ZR / Z6III / Z5II but 8256 px on a
/// Z8, so no fixed threshold works across the lineup. The class is instead *ranked* against the
/// still sizes actually present in the listing — the same approach
/// `StillCaptureState.stillSizeClassLabel(options:)` already uses to rank the live ImageSize
/// property against the body's enumerated size domain.
public enum MediaPhotoSizeClass: String, CaseIterable, Codable, Sendable {
    case large = "L"
    case medium = "M"
    case small = "S"

    /// Ranks one still's width among the distinct still widths present in the listing: widest
    /// present is L, next M, next S.
    ///
    /// Nil when the width is unknown/zero or ranks below S, so a still whose dimensions the
    /// camera never reported is silently left unclassified rather than guessed at.
    public static func rank(
        pixelWidth: UInt32,
        among presentWidths: some Sequence<UInt32>
    ) -> MediaPhotoSizeClass? {
        guard pixelWidth > 0 else { return nil }
        let ranked = Set(presentWidths.filter { $0 > 0 }).sorted(by: >)
        guard let index = ranked.firstIndex(of: pixelWidth), index < allCases.count else {
            return nil
        }
        return allCases[index]
    }
}

/// Relative capture-date windows for the Media browser DATE chips.
public enum MediaDateWindow: String, CaseIterable, Codable, Sendable {
    case today = "TODAY"
    case last7Days = "7 DAYS"
    case last30Days = "30 DAYS"

    /// Calendar days the window spans, counting today as one.
    public var dayCount: Int {
        switch self {
        case .today: 1
        case .last7Days: 7
        case .last30Days: 30
        }
    }

    /// True when a PTP `YYYYMMDDThhmmss` capture date falls inside the window.
    ///
    /// Future-dated captures (a body with a skewed clock) fall outside every window, matching the
    /// existing today-only behaviour rather than inventing a special case.
    public func contains(
        ptpCaptureDate: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let day = Self.captureDay(ptpCaptureDate, calendar: calendar) else { return false }
        let today = calendar.startOfDay(for: now)
        guard
            let earliest = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today)
        else { return false }
        return day >= earliest && day <= today
    }

    /// Start-of-day for the `YYYYMMDD` prefix of a PTP capture date; nil when absent or malformed.
    public static func captureDay(_ ptpCaptureDate: String, calendar: Calendar = .current) -> Date?
    {
        let token = ptpCaptureDate.prefix(8)
        guard token.count == 8, token.allSatisfy({ $0.isASCII && $0.isNumber }),
            let year = Int(token.prefix(4)),
            let month = Int(token.dropFirst(4).prefix(2)), (1...12).contains(month),
            let day = Int(token.dropFirst(6)), (1...31).contains(day)
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

/// The per-object facts the Media browser chip derivation needs, supplied by each shell's own
/// clip record so the core stays free of any platform library model.
public struct MediaFilterItem: Equatable, Sendable {
    public let filename: String
    /// Full-frame width the camera reported for this object (nil when it reported none).
    public let pixelWidth: UInt32?
    /// Width of a linked `.R3D` master, when this object is its proxy.
    public let sourcePixelWidth: UInt32?
    /// PTP `YYYYMMDDThhmmss` capture date, or empty.
    public let captureDate: String

    public init(
        filename: String,
        pixelWidth: UInt32? = nil,
        sourcePixelWidth: UInt32? = nil,
        captureDate: String = ""
    ) {
        self.filename = filename
        self.pixelWidth = pixelWidth
        self.sourcePixelWidth = sourcePixelWidth
        self.captureDate = captureDate
    }
}

/// The chips a Media browser filter popup offers for one listing.
public struct MediaFilterOptions: Equatable, Sendable {
    /// FORMAT row — MOV/MP4 for a video listing, JPEG/HEIF/NEF for a stills listing.
    public let formats: [MediaFormatChip]
    /// RESOLUTION row — video only.
    public let resolutions: [MediaResolutionBucket]
    /// SIZE row — stills only.
    public let photoSizes: [MediaPhotoSizeClass]
    /// DATE row.
    public let dateWindows: [MediaDateWindow]

    public static let none = MediaFilterOptions(
        formats: [], resolutions: [], photoSizes: [], dateWindows: [])

    /// True when no row has a chip to show, so the popup can say so instead of rendering empty
    /// section headers.
    public var isEmpty: Bool {
        formats.isEmpty && resolutions.isEmpty && photoSizes.isEmpty && dateWindows.isEmpty
    }
}

/// Derives the Media browser's filter chips from the listing the operator is actually looking at.
///
/// One rule governs every row: **a chip is offered only when it matches at least one listed
/// object and excludes at least one.** A chip matching nothing is dead (the Photos tab used to
/// offer MOV, MP4, and 6K — none of which a still can ever be), and a chip matching everything
/// filters nothing. Deriving instead of hardcoding is also what keeps the two media kinds apart:
/// resolution buckets are classified for videos only and L/M/S for stills only, so the Photos tab
/// produces no RESOLUTION row and the Videos tab produces no SIZE row without either being told
/// which tab it is.
public enum MediaFilterDerivation {
    /// Keeps only the candidate chips that genuinely split `itemCount` items.
    ///
    /// `matchCount` reports how many listed objects a chip selects; date windows overlap (a shot
    /// from today is inside all three), so this counts matches rather than partitioning by a
    /// single classification.
    public static func partitioning<Value>(
        _ candidates: [Value],
        itemCount: Int,
        matchCount: (Value) -> Int
    ) -> [Value] {
        guard itemCount > 0 else { return [] }
        return candidates.filter { candidate in
            let matched = matchCount(candidate)
            return matched > 0 && matched < itemCount
        }
    }

    /// The chip set for one listing.
    public static func options(
        for items: [MediaFilterItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MediaFilterOptions {
        guard !items.isEmpty else { return .none }
        let count = items.count

        let formats = items.map { MediaClipFilename.formatChip(for: $0.filename) }
        let stillWidths = items.compactMap { item -> UInt32? in
            guard MediaClipFilename.isPhoto(item.filename) else { return nil }
            return item.pixelWidth
        }
        let sizes = items.map { item -> MediaPhotoSizeClass? in
            guard MediaClipFilename.isPhoto(item.filename), let width = item.pixelWidth else {
                return nil
            }
            return MediaPhotoSizeClass.rank(pixelWidth: width, among: stillWidths)
        }
        // Resolution buckets describe video frame sizes; a still's rank belongs in the SIZE row.
        let buckets = items.map { item -> MediaResolutionBucket? in
            guard !MediaClipFilename.isPhoto(item.filename) else { return nil }
            return MediaResolutionBucket.classify(
                filename: item.filename,
                pixelWidth: item.pixelWidth,
                sourcePixelWidth: item.sourcePixelWidth)
        }

        return MediaFilterOptions(
            formats: partitioning(MediaFormatChip.allCases, itemCount: count) { chip in
                formats.count { $0 == chip }
            },
            resolutions: partitioning(MediaResolutionBucket.allCases, itemCount: count) { bucket in
                buckets.count { $0 == bucket }
            },
            photoSizes: partitioning(MediaPhotoSizeClass.allCases, itemCount: count) { size in
                sizes.count { $0 == size }
            },
            dateWindows: partitioning(MediaDateWindow.allCases, itemCount: count) { window in
                items.count {
                    window.contains(ptpCaptureDate: $0.captureDate, now: now, calendar: calendar)
                }
            }
        )
    }
}
