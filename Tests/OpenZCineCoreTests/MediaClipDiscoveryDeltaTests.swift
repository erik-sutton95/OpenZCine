import Testing

@testable import OpenZCineCore

@Test func discoveryDeltaReusesStableHandles() {
    let camera: [MediaObjectHandle] = [
        MediaObjectHandle(storageID: 1, handle: 10),
        MediaObjectHandle(storageID: 1, handle: 20),
    ]
    let delta = MediaClipDiscoveryDelta.compute(cachedHandles: [10, 20, 30], cameraHandles: camera)
    #expect(delta.reuseHandles == [10, 20])
    #expect(delta.fetchHandles.isEmpty)
    #expect(delta.removedHandles == [30])
}

@Test func discoveryDeltaFetchesOnlyNewHandles() {
    let camera: [MediaObjectHandle] = [
        MediaObjectHandle(storageID: 2, handle: 100),
        MediaObjectHandle(storageID: 2, handle: 200),
    ]
    let delta = MediaClipDiscoveryDelta.compute(cachedHandles: [100], cameraHandles: camera)
    #expect(delta.reuseHandles == [100])
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
