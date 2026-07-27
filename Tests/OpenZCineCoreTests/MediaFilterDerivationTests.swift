import Foundation
import Testing

@testable import OpenZCineCore

/// Fixed clock so the relative date windows are deterministic: 2026-07-27, UTC.
private let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    // SAFETY: "UTC" is a constant, always-present time-zone identifier.
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

// SAFETY: a valid Gregorian y/m/d in a calendar constructed above.
private let testNow = testCalendar.date(from: DateComponents(year: 2026, month: 7, day: 27))!

/// PTP capture date `daysAgo` before the fixed clock.
private func captureDate(daysAgo: Int) -> String {
    // SAFETY: day arithmetic on a valid Gregorian date.
    let day = testCalendar.date(byAdding: .day, value: -daysAgo, to: testNow)!
    let parts = testCalendar.dateComponents([.year, .month, .day], from: day)
    return String(format: "%04d%02d%02dT120000", parts.year!, parts.month!, parts.day!)
}

private func options(_ items: [MediaFilterItem]) -> MediaFilterOptions {
    MediaFilterDerivation.options(for: items, now: testNow, calendar: testCalendar)
}

// MARK: - Format classification

@Test func formatChipCoversStillsVideosAndNothingElse() {
    #expect(MediaClipFilename.formatChip(for: "C0001.MOV") == .mov)
    #expect(MediaClipFilename.formatChip(for: "C0001.m4v") == .mov)
    #expect(MediaClipFilename.formatChip(for: "C0002.MP4") == .mp4)
    #expect(MediaClipFilename.formatChip(for: "DSC_0001.JPG") == .jpeg)
    #expect(MediaClipFilename.formatChip(for: "DSC_0001.jpeg") == .jpeg)
    #expect(MediaClipFilename.formatChip(for: "DSC_0002.NEF") == .nef)
    #expect(MediaClipFilename.formatChip(for: "DSC_0002.nrw") == .nef)
    // Nikon writes HEIF with its own `.HIF` extension.
    #expect(MediaClipFilename.formatChip(for: "DSC_0003.HIF") == .heif)
    #expect(MediaClipFilename.formatChip(for: "DSC_0003.heic") == .heif)
    // No chip is invented for an unpaired master or an unknown object.
    #expect(MediaClipFilename.formatChip(for: "A001_C004.R3D") == nil)
    #expect(MediaClipFilename.formatChip(for: "metadata.bin") == nil)
}

@Test func nikonHIFStillsAreBrowsable() {
    #expect(MediaClipFilename.isPhoto("DSC_0003.HIF"))
    #expect(MediaClipFilename.isBrowsableMedia("DSC_0003.hif"))
    #expect(MediaClipFilename.photoExtensions.contains("hif"))
}

// MARK: - Per-tab chip sets

@Test func photosTabOffersStillFormatsAndNeverVideoChips() {
    let derived = options([
        MediaFilterItem(
            filename: "DSC_0001.JPG", pixelWidth: 6048, captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(
            filename: "DSC_0002.NEF", pixelWidth: 6048, captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(
            filename: "DSC_0003.HIF", pixelWidth: 6048, captureDate: captureDate(daysAgo: 0)),
    ])
    #expect(derived.formats == [.jpeg, .heif, .nef])
    // The reported defect: video containers and video resolution buckets on a stills listing.
    #expect(!derived.formats.contains(.mov))
    #expect(!derived.formats.contains(.mp4))
    #expect(derived.resolutions.isEmpty)
}

@Test func videosTabKeepsContainerAndResolutionChips() {
    let derived = options([
        MediaFilterItem(
            filename: "C0001.MOV", pixelWidth: 6048, captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(
            filename: "C0002.MP4", pixelWidth: 1920, captureDate: captureDate(daysAgo: 0)),
    ])
    #expect(derived.formats == [.mov, .mp4])
    #expect(derived.resolutions == [.hd, .sixK])
    // Stills-only rows stay absent on a video listing.
    #expect(derived.photoSizes.isEmpty)
}

@Test func allTabOffersTheUnionActuallyPresent() {
    let derived = options([
        MediaFilterItem(
            filename: "C0001.MOV", pixelWidth: 3840, captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(
            filename: "DSC_0001.JPG", pixelWidth: 6048, captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(
            filename: "DSC_0002.NEF", pixelWidth: 3024, captureDate: captureDate(daysAgo: 0)),
    ])
    #expect(derived.formats == [.mov, .jpeg, .nef])
    #expect(derived.resolutions == [.fourK])
    #expect(derived.photoSizes == [.large, .medium])
}

// MARK: - The partition rule

@Test func chipMatchingNothingIsNotOffered() {
    // A listing with no MP4 must not advertise MP4, and no 5.4K clip must not advertise 5.4K.
    let derived = options([
        MediaFilterItem(
            filename: "C0001.MOV", pixelWidth: 1920, captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(
            filename: "C0002.MOV", pixelWidth: 6048, captureDate: captureDate(daysAgo: 0)),
    ])
    #expect(!derived.formats.contains(.mp4))
    #expect(!derived.resolutions.contains(.fiveFourK))
    #expect(derived.resolutions == [.hd, .sixK])
}

@Test func chipMatchingEverythingIsNotOffered() {
    // Every clip is a MOV, so a MOV chip would filter nothing at all.
    let derived = options([
        MediaFilterItem(
            filename: "C0001.MOV", pixelWidth: 1920, captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(
            filename: "C0002.MOV", pixelWidth: 1920, captureDate: captureDate(daysAgo: 0)),
    ])
    #expect(derived.formats.isEmpty)
    #expect(derived.resolutions.isEmpty)
    #expect(derived.isEmpty)
}

@Test func emptyListingOffersNothing() {
    #expect(options([]) == .none)
}

// MARK: - Still size class

@Test func photoSizeRanksAgainstTheSizesActuallyPresent() {
    let widths: [UInt32] = [6048, 4528, 3024]
    #expect(MediaPhotoSizeClass.rank(pixelWidth: 6048, among: widths) == .large)
    #expect(MediaPhotoSizeClass.rank(pixelWidth: 4528, among: widths) == .medium)
    #expect(MediaPhotoSizeClass.rank(pixelWidth: 3024, among: widths) == .small)
    // A Z8's native L is 8256 px — the rank is relative, so no fixed threshold is assumed.
    #expect(MediaPhotoSizeClass.rank(pixelWidth: 8256, among: [8256, 6192]) == .large)
    #expect(MediaPhotoSizeClass.rank(pixelWidth: 6192, among: [8256, 6192]) == .medium)
    // Unknown or unranked widths are left unclassified rather than guessed.
    #expect(MediaPhotoSizeClass.rank(pixelWidth: 0, among: widths) == nil)
    #expect(MediaPhotoSizeClass.rank(pixelWidth: 1024, among: widths) == nil)
}

@Test func sizeRowIsOmittedWhenStillsCarryNoDimensions() {
    // The camera reported no ImagePixWidth for these stills: no SIZE chip is faked.
    let derived = options([
        MediaFilterItem(filename: "DSC_0001.JPG", captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(filename: "DSC_0002.NEF", captureDate: captureDate(daysAgo: 0)),
    ])
    #expect(derived.photoSizes.isEmpty)
    #expect(derived.formats == [.jpeg, .nef])
}

@Test func sizeRowIsOmittedWhenEveryStillIsTheSameSize() {
    let derived = options([
        MediaFilterItem(
            filename: "DSC_0001.JPG", pixelWidth: 6048, captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(
            filename: "DSC_0002.JPG", pixelWidth: 6048, captureDate: captureDate(daysAgo: 0)),
    ])
    #expect(derived.photoSizes.isEmpty)
}

// MARK: - Date windows

@Test func dateWindowsCoverTodaySevenAndThirtyDays() {
    #expect(
        MediaDateWindow.today.contains(
            ptpCaptureDate: captureDate(daysAgo: 0), now: testNow, calendar: testCalendar))
    #expect(
        !MediaDateWindow.today.contains(
            ptpCaptureDate: captureDate(daysAgo: 1), now: testNow, calendar: testCalendar))

    #expect(
        MediaDateWindow.last7Days.contains(
            ptpCaptureDate: captureDate(daysAgo: 6), now: testNow, calendar: testCalendar))
    #expect(
        !MediaDateWindow.last7Days.contains(
            ptpCaptureDate: captureDate(daysAgo: 7), now: testNow, calendar: testCalendar))

    #expect(
        MediaDateWindow.last30Days.contains(
            ptpCaptureDate: captureDate(daysAgo: 29), now: testNow, calendar: testCalendar))
    #expect(
        !MediaDateWindow.last30Days.contains(
            ptpCaptureDate: captureDate(daysAgo: 30), now: testNow, calendar: testCalendar))
}

@Test func dateWindowRejectsMissingAndMalformedCaptureDates() {
    for value in ["", "2026", "not-a-date", "20261332T120000", "2026-07-27"] {
        #expect(
            !MediaDateWindow.last30Days.contains(
                ptpCaptureDate: value, now: testNow, calendar: testCalendar))
    }
    // A body with a skewed clock dating a shot into the future falls outside every window.
    #expect(
        !MediaDateWindow.today.contains(
            ptpCaptureDate: "20991231T120000", now: testNow, calendar: testCalendar))
}

@Test func onlyDateWindowsThatSplitTheListingAreOffered() {
    let derived = options([
        MediaFilterItem(
            filename: "C0001.MOV", pixelWidth: 1920, captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(
            filename: "C0002.MP4", pixelWidth: 1920, captureDate: captureDate(daysAgo: 3)),
        MediaFilterItem(
            filename: "C0003.MP4", pixelWidth: 1920, captureDate: captureDate(daysAgo: 90)),
    ])
    // TODAY selects one, 7 DAYS two, 30 DAYS two — all three genuinely split the listing.
    #expect(derived.dateWindows == [.today, .last7Days, .last30Days])
}

@Test func dateWindowsThatSelectEverythingOrNothingAreDropped() {
    // Everything is from today: all three windows select all three clips, so none filters.
    let allToday = options([
        MediaFilterItem(filename: "C0001.MOV", captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(filename: "C0002.MP4", captureDate: captureDate(daysAgo: 0)),
    ])
    #expect(allToday.dateWindows.isEmpty)

    // Nothing is recent: TODAY and 7 DAYS would show an empty grid, so neither is offered.
    let allOld = options([
        MediaFilterItem(filename: "C0001.MOV", captureDate: captureDate(daysAgo: 200)),
        MediaFilterItem(filename: "C0002.MP4", captureDate: captureDate(daysAgo: 20)),
    ])
    #expect(allOld.dateWindows == [.last30Days])
}

// MARK: - Stale filters across a tab switch

@Test func staleFiltersDoNotSurviveIntoATabThatCannotOfferThem() {
    // The operator filtered to MOV on Videos, then switched to Photos. Intersecting the active
    // selection with the new tab's offered chips is what both shells do on a tab change: an
    // invisible MOV filter would otherwise hide every still.
    let photos = options([
        MediaFilterItem(
            filename: "DSC_0001.JPG", pixelWidth: 6048, captureDate: captureDate(daysAgo: 0)),
        MediaFilterItem(
            filename: "DSC_0002.NEF", pixelWidth: 6048, captureDate: captureDate(daysAgo: 0)),
    ])
    let active: Set<MediaFormatChip> = [.mov, .jpeg]
    #expect(active.intersection(photos.formats) == [.jpeg])

    let staleResolutions: Set<MediaResolutionBucket> = [.sixK]
    #expect(staleResolutions.intersection(photos.resolutions).isEmpty)
}
