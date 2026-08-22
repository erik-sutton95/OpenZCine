import Testing

@testable import OpenZCineCore

@Test func discoveryDeltaReusesStableHandles() {
    let camera: [MediaObjectHandle] = [
        MediaObjectHandle(storageID: 1, handle: 10),
        MediaObjectHandle(storageID: 1, handle: 20),
    ]
    let delta = MediaClipDiscoveryDelta.compute(
        cachedHandles: [
            MediaObjectHandle(storageID: 1, handle: 10),
            MediaObjectHandle(storageID: 1, handle: 20),
            MediaObjectHandle(storageID: 1, handle: 30),
        ],
        cameraHandles: camera
    )
    #expect(
        delta.reuseHandles == [
            MediaObjectHandle(storageID: 1, handle: 10),
            MediaObjectHandle(storageID: 1, handle: 20),
        ]
    )
    #expect(delta.fetchHandles.isEmpty)
    #expect(delta.removedHandles == [MediaObjectHandle(storageID: 1, handle: 30)])
}

@Test func discoveryDeltaFetchesOnlyNewHandles() {
    let camera: [MediaObjectHandle] = [
        MediaObjectHandle(storageID: 2, handle: 100),
        MediaObjectHandle(storageID: 2, handle: 200),
    ]
    let delta = MediaClipDiscoveryDelta.compute(
        cachedHandles: [MediaObjectHandle(storageID: 2, handle: 100)],
        cameraHandles: camera
    )
    #expect(delta.reuseHandles == [MediaObjectHandle(storageID: 2, handle: 100)])
    #expect(delta.fetchHandles == [MediaObjectHandle(storageID: 2, handle: 200)])
    #expect(delta.removedHandles.isEmpty)
}

@Test func discoveryDeltaColdCacheFetchesAll() {
    let camera: [MediaObjectHandle] = [
        MediaObjectHandle(storageID: 1, handle: 1),
        MediaObjectHandle(storageID: 1, handle: 2),
    ]
    let delta = MediaClipDiscoveryDelta.compute(cachedHandles: [], cameraHandles: camera)
    #expect(delta.reuseHandles.isEmpty)
    #expect(delta.fetchHandles.count == 2)
    #expect(delta.removedHandles.isEmpty)
}

/// Backup mode: the second card's copy shares the handle VALUE with an unrelated first-card
/// object — storage-qualified identity must keep them apart instead of "reusing" the wrong one.
@Test func discoveryDeltaKeepsCrossCardHandleCollisionsApart() {
    let camera: [MediaObjectHandle] = [
        MediaObjectHandle(storageID: 0x0001_0001, handle: 7),
        MediaObjectHandle(storageID: 0x0002_0001, handle: 7),
    ]
    let delta = MediaClipDiscoveryDelta.compute(
        cachedHandles: [MediaObjectHandle(storageID: 0x0001_0001, handle: 7)],
        cameraHandles: camera
    )
    #expect(delta.reuseHandles == [MediaObjectHandle(storageID: 0x0001_0001, handle: 7)])
    #expect(delta.fetchHandles == [MediaObjectHandle(storageID: 0x0002_0001, handle: 7)])
    #expect(delta.removedHandles.isEmpty)
    #expect(delta.supersededHandles.isEmpty)
}

/// After a card format Nikon recycles PTP handles. Matching handles with a different
/// filename/date are a new generation — reuse would keep the old names and hide the new files.
@Test func discoveryDeltaInvalidatesAStorageWhenAReusedHandleChangesIdentity() {
    let slot: UInt32 = 0x0001_0001
    let oldTen = MediaObjectHandle(storageID: slot, handle: 10)
    let oldTwenty = MediaObjectHandle(storageID: slot, handle: 20)
    let delta = MediaClipDiscoveryDelta.compute(
        cachedHandles: [oldTen, oldTwenty],
        cameraHandles: [oldTen, oldTwenty]
    )
    #expect(delta.reuseHandles == [oldTen, oldTwenty])

    let verified = delta.verifyingReusedIdentities(
        cached: [
            oldTen: MediaClipObjectIdentity(
                location: oldTen, filename: "DSC_0001.JPG", captureDate: "20260101T120000",
                sizeBytes: 1_000),
            oldTwenty: MediaClipObjectIdentity(
                location: oldTwenty, filename: "DSC_0002.JPG", captureDate: "20260101T120100",
                sizeBytes: 2_000),
        ],
        probed: [
            oldTen: MediaClipObjectIdentity(
                location: oldTen, filename: "DSC_0100.JPG", captureDate: "20260818T090000",
                sizeBytes: 3_000)
        ]
    )

    #expect(verified.reuseHandles.isEmpty)
    #expect(verified.fetchHandles == [oldTen, oldTwenty])
    #expect(verified.supersededHandles == [oldTen, oldTwenty])
    #expect(verified.removedHandles.isEmpty)
}

@Test func discoveryDeltaKeepsMatchingIdentitiesAsReuse() {
    let location = MediaObjectHandle(storageID: 1, handle: 5)
    let identity = MediaClipObjectIdentity(
        location: location, filename: "C0001.MOV", captureDate: "20260713T101010",
        sizeBytes: 4_000)
    let delta = MediaClipDiscoveryDelta.compute(
        cachedHandles: [location], cameraHandles: [location])
    let verified = delta.verifyingReusedIdentities(
        cached: [location: identity], probed: [location: identity])
    #expect(verified.reuseHandles == [location])
    #expect(verified.fetchHandles.isEmpty)
    #expect(verified.supersededHandles.isEmpty)
}

@Test func discoveryDeltaUnknownSizeDoesNotInvalidateAMatchingNameAndDate() {
    let location = MediaObjectHandle(storageID: 1, handle: 9)
    let cached = MediaClipObjectIdentity(
        location: location, filename: "C0001.MOV", captureDate: "20260713T101010",
        sizeBytes: 8_000)
    let probed = MediaClipObjectIdentity(
        location: location, filename: "C0001.MOV", captureDate: "20260713T101010",
        sizeBytes: 0)
    let delta = MediaClipDiscoveryDelta.compute(
        cachedHandles: [location], cameraHandles: [location])
    let verified = delta.verifyingReusedIdentities(
        cached: [location: cached], probed: [location: probed])
    #expect(verified.reuseHandles == [location])
    #expect(verified.supersededHandles.isEmpty)
}

/// A mismatch on slot 1 must not force GetObjectInfo on an untouched slot 2.
@Test func discoveryDeltaHandleReuseInvalidationStaysOnTheDirtyCard() {
    let slot1 = MediaObjectHandle(storageID: 0x0001_0001, handle: 7)
    let slot2 = MediaObjectHandle(storageID: 0x0002_0001, handle: 7)
    let delta = MediaClipDiscoveryDelta.compute(
        cachedHandles: [slot1, slot2], cameraHandles: [slot1, slot2])
    let verified = delta.verifyingReusedIdentities(
        cached: [
            slot1: MediaClipObjectIdentity(
                location: slot1, filename: "A.JPG", captureDate: "20260101T000000", sizeBytes: 1),
            slot2: MediaClipObjectIdentity(
                location: slot2, filename: "B.JPG", captureDate: "20260101T000000", sizeBytes: 1),
        ],
        probed: [
            slot1: MediaClipObjectIdentity(
                location: slot1, filename: "C.JPG", captureDate: "20260818T000000", sizeBytes: 2)
        ]
    )
    #expect(verified.supersededHandles == [slot1])
    #expect(verified.reuseHandles == [slot2])
    #expect(verified.fetchHandles == [slot1])
}

@Test func discoveryDeltaUnprobedReuseStaysReuse() {
    let kept = MediaObjectHandle(storageID: 1, handle: 1)
    let delta = MediaClipDiscoveryDelta.compute(
        cachedHandles: [kept], cameraHandles: [kept])
    let verified = delta.verifyingReusedIdentities(cached: [:], probed: [:])
    #expect(verified == delta)
}

@Test func discoveryDeltaProbeSpreadHitsNewestOldestAndMiddle() {
    let slot: UInt32 = 1
    let handles = (1...10).map { MediaObjectHandle(storageID: slot, handle: UInt32($0)) }
    let delta = MediaClipDiscoveryDelta.compute(
        cachedHandles: Set(handles), cameraHandles: handles)
    let probed = delta.identityProbeHandles(budget: 4)
    #expect(probed.count == 4)
    #expect(probed.first == MediaObjectHandle(storageID: slot, handle: 10))
    #expect(probed.last == MediaObjectHandle(storageID: slot, handle: 1))
    #expect(Set(probed).isSubset(of: Set(handles)))
}

@Test func discoveryDeltaProbeBudgetCoversEveryReusedHandleWhenSmall() {
    let handles = [
        MediaObjectHandle(storageID: 1, handle: 3),
        MediaObjectHandle(storageID: 1, handle: 1),
    ]
    let delta = MediaClipDiscoveryDelta.compute(
        cachedHandles: Set(handles), cameraHandles: handles)
    #expect(Set(delta.identityProbeHandles(budget: 8)) == Set(handles))
    #expect(delta.identityProbeHandles(budget: 0).isEmpty)
}
