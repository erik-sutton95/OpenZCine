import Foundation
import OpenZCineCore
import XCTest

@testable import Runner

/// SIMULATED actual gallery callers; no PTP or physical qualification.
@MainActor final class NikonMediaGalleryProjectionTests: XCTestCase {
    private func clip(
        _ name: String, width: UInt32 = 6048, handle: UInt32 = 1,
        date: String = "20260727T120000", stars: Int? = nil
    ) -> MediaClip {
        .init(
            cameraID: "cam", filename: name, handle: handle, storageID: 11,
            sizeBytes: 2, captureDate: date, pixelWidth: width, pixelHeight: 4000, starRating: stars
        )
    }
    private func model(_ clips: [MediaClip]) -> NativeAppModel {
        let model = NativeAppModel()
        model.connection = .connected
        model.mediaClips = clips
        return model
    }
    /// OPENZCINE-IOS-6/-7 (build 281): the catalog screen builds every cell on each render, and a
    /// cell's RAW+J lookup rebuilt the library-wide pairing policy from all clips (246 s main-thread
    /// hang in String.lowercased under a lazy grid). One render's cells must read that render's
    /// projection pass, so a large card stays responsive.
    func testEveryGalleryCellOfALargeLibraryReadsTheRenderProjection() {
        var clips: [MediaClip] = []
        for index in 0..<1_500 {
            let stem = String(format: "DSC_%04d", index)
            clips.append(clip("\(stem).JPG", handle: UInt32(index * 2 + 1)))
            if index.isMultiple(of: 3) { clips.append(clip("\(stem).NEF", handle: UInt32(index * 2 + 2))) }
        }
        let model = model(clips)
        let projection = model.mediaGalleryProjection
        let started = ContinuousClock.now
        let items = clips.map {
            model.mediaCellItem($0, list: true, selecting: false, duration: nil, projection: projection)
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .seconds(2), "\(elapsed) to build \(clips.count) cells")
        XCTAssertTrue(items[0].metadata.contains("RAW+J"), items[0].metadata)
        XCTAssertFalse(items[2].metadata.contains("RAW+J"), items[2].metadata)
        let paired = zip(clips, items).filter { $0.1.metadata.contains("RAW+J") }.map(\.0.filename)
        XCTAssertEqual(paired.count, 500)
        XCTAssertTrue(paired.allSatisfy { $0.hasSuffix(".JPG") })
        XCTAssertEqual(model.rawSibling(of: clips[0])?.filename, "DSC_0000.NEF")
    }
    func testActualPhotoRankUsesWholeCategoryBeforeFormatAndKeepsUnknownFourWidthDomain() {
        let model = model([
            clip("L.JPG", width: 6048), clip("M.NEF", width: 4032), clip("S.TIF", width: 3024),
        ])
        model.mediaCategoryTab = .photos
        model.mediaFormatFilters = [.nef]
        model.mediaPhotoSizeFilters = [.medium]
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["M.NEF"])
        model.mediaClips.append(clip("DX.JPG", width: 2000))
        XCTAssertTrue(model.mediaFilterOptions.photoSizes.isEmpty)
        XCTAssertTrue(model.filteredMediaClips.isEmpty)
    }
    func testActualHiddenResolutionChipStillFiltersStillsWithoutOfferingVideoChip() {
        let model = model([clip("L.JPG", width: 6048), clip("M.TIF", width: 4032)])
        model.mediaCategoryTab = .photos
        model.mediaResolutionFilters = [.sixK]
        XCTAssertTrue(model.mediaFilterOptions.resolutions.isEmpty)
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["L.JPG"])
    }
    func testActualBackupMembershipMatchesEitherCardAndRawPairIsSurvivorQualified() {
        var jpeg = clip("A.JPG")
        jpeg.storageLocations = [.init(storageID: 11, handle: 1), .init(storageID: 22, handle: 2)]
        let raw = clip("A.NEF", handle: 3)
        let model = model([jpeg, raw])
        model.mediaCategoryTab = .photos
        model.mediaStorageSlotFilter = 22
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["A.JPG"])
        model.mediaStorageSlotFilter = nil
        model.mediaFormatFilters = [.nef]
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["A.NEF"])
        XCTAssertEqual(model.rawSibling(of: jpeg)?.filename, "A.NEF")
    }
    func testActualOfflineRawSurvivesUncachedJPEGAndDoesNotReadCacheWhileConnected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let raw = clip("A.NEF", handle: 2)
        let url = try store.localURL(cameraID: raw.cameraID, filename: raw.filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2]).write(to: url)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaCategoryTab = .photos
        model.mediaClips = [clip("A.JPG"), raw]
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["A.NEF"])
        model.connection = .connected
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["A.JPG"])
    }
    func testActualBurstRepresentativeSortAndExpandedOrderUseOneGridPass() {
        let a = clip("DSC_0001.JPG", handle: 1)
        let b = clip("DSC_0002.JPG", handle: 2, date: "20260727T120001")
        let c = clip("DSC_0003.JPG", handle: 3, date: "20260727T120002")
        let later = clip("LATER.JPG", handle: 4, date: "20260727T120020")
        let model = model([c, later, a, b])
        model.mediaCategoryTab = .photos
        model.mediaSortOrder = .newest
        XCTAssertEqual(model.burstExpanded([a, b, a]), [a, b])
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["LATER.JPG", "DSC_0001.JPG"])
        XCTAssertEqual(
            model.burstMembers(of: a).map(\.filename),
            ["DSC_0001.JPG", "DSC_0002.JPG", "DSC_0003.JPG"])
        XCTAssertEqual(
            model.burstExpanded([a, b, a]).map(\.filename),
            ["DSC_0001.JPG", "DSC_0002.JPG", "DSC_0003.JPG"])
        let late = clip("NOT_IN_PASS.JPG", handle: 5, date: "20260727T120040")
        XCTAssertEqual(model.burstExpanded([a, late, late]), [a, b, c, late])
        var updated = b
        updated.starRating = 4
        model.mediaClips = [a, updated, c]
        XCTAssertEqual(model.burstExpanded([a]), [a, updated, c])
        model.mediaClips = []
        XCTAssertEqual(model.burstExpanded([a, late, a]), [a, late])
    }
    func testActualRatingPayloadUpdateRebuildsPolicyAndPreservesNumericAndFilenameTies() {
        var a = clip("A.JPG", stars: 0)
        var b = clip("B.JPG", stars: 5)
        var c = clip("C.JPG", stars: 2)
        a.storageID = nil
        b.storageID = nil
        c.storageID = nil
        let model = model([a, b, c])
        model.mediaCategoryTab = .photos
        model.mediaSortOrder = .rating
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["B.JPG", "C.JPG", "A.JPG"])
        a.starRating = 5
        model.mediaClips = [a, b, c]
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["B.JPG", "A.JPG", "C.JPG"])
        model.mediaCategoryTab = .favorites
        model.mediaClips = [clip("D.JPG"), a]
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["A.JPG"])
    }
}
