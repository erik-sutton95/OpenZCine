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
}
