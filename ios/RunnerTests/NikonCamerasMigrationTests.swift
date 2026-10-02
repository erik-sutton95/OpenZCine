import OpenCineAppKit
import OpenCineCore
import XCTest

@testable import OpenZCineCore
@testable import Runner

/// SHELL-02 step 9: the app's saved setups through the shared document (`NikonCameras.store`),
/// with the records every older build reads kept mirrored. Records are written the way the app's
/// own store writes them (`NativeCameraConnectionStore.saveSavedCameras`).
@MainActor
final class NikonCamerasMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var legacyWrites = 0

    override func setUp() async throws {
        suite = "NikonCamerasMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        legacyWrites = 0
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func store() -> SavedCamerasStore {
        let store = NikonCameras.store(defaults) { [unowned self] in self.legacyWrites += 1 }
        store.load()
        return store
    }

    /// The app's own encoder.
    private func appWrite(_ records: [PTPIPSavedCameraRecord]) throws {
        defaults.set(try JSONEncoder().encode(PTPIPSavedCameraRecords.canonicalized(records)), forKey: NikonCameras.legacyKey)
    }

    /// The app's own decoder (what an older build reads).
    private func appRead() throws -> [PTPIPSavedCameraRecord] {
        try JSONDecoder().decode([PTPIPSavedCameraRecord].self, from: XCTUnwrap(defaults.data(forKey: NikonCameras.legacyKey)))
    }

    private var studio: [PTPIPSavedCameraRecord] {
        [
            PTPIPSavedCameraRecord(
                host: "192.168.1.30", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000),
                serialNumber: "6002199", path: .infrastructure(networkName: "Studio"), setupName: "Stage left"),
            PTPIPSavedCameraRecord(
                host: "usb:demo-zr", displayName: "ZR_6002199", transport: "USB-C", lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
                serialNumber: "6002199", path: .usbC),
            PTPIPSavedCameraRecord(
                host: "192.168.1.1", displayName: "Z6_3001234", transport: "Wi-Fi", lastSeenAt: Date(timeIntervalSince1970: 1_750_000_000),
                presentation: PTPIPSavedCameraPresentation(customName: "B cam", wifiSSID: "Z6_3001234"),
                pairedViaCameraAccessPoint: true, path: .cameraAccessPoint(ssid: "Z6_3001234")),
        ]
    }

    func testUpgradeKeepsEverySetupAndNeverRewritesTheRecords() throws {
        try appWrite(studio)
        let before = try XCTUnwrap(defaults.data(forKey: NikonCameras.legacyKey))
        defaults.set(Data([1, 2, 3]), forKey: "OpenZCine.PTPIP.GUID")
        defaults.set(["192.168.1.30"], forKey: "OpenZCine.PTPIP.PairedHosts")

        let cameras = store().cameras

        XCTAssertEqual(cameras.count, 2, "one card per body: two setups of 6002199, one access point camera")
        let zr = try XCTUnwrap(cameras.first { $0.id == "serial:6002199" })
        XCTAssertEqual(zr.routes.map(\.kind), [.infrastructureNetwork, .usb])
        XCTAssertEqual(zr.routes.first?.title, "Stage left")
        XCTAssertEqual(zr.routes.first?.network, "Studio")
        XCTAssertEqual(zr.device, .durable("6002199", integration: NikonCameraSession.integration))
        let bcam = try XCTUnwrap(cameras.first { $0.routes.contains { $0.kind == .cameraAccessPoint } })
        XCTAssertEqual(bcam.name, "B cam")
        XCTAssertEqual(defaults.data(forKey: NikonCameras.legacyKey), before, "a read never writes the records")
        XCTAssertNotNil(defaults.data(forKey: NikonCameras.documentKey))
        XCTAssertEqual(defaults.data(forKey: "OpenZCine.PTPIP.GUID"), Data([1, 2, 3]))
        XCTAssertEqual(defaults.stringArray(forKey: "OpenZCine.PTPIP.PairedHosts"), ["192.168.1.30"])
        XCTAssertEqual(legacyWrites, 0)
    }

    func testLaunchingAgainChangesNothing() throws {
        try appWrite(studio)
        _ = store()
        let document = defaults.data(forKey: NikonCameras.documentKey)
        let legacy = defaults.data(forKey: NikonCameras.legacyKey)
        for _ in 0..<3 { _ = store() }
        XCTAssertEqual(defaults.data(forKey: NikonCameras.documentKey), document)
        XCTAssertEqual(defaults.data(forKey: NikonCameras.legacyKey), legacy)
    }

    /// The funnel saves a connect with its own rules; `reloadSaved` (CamerasModel) merges it at
    /// once and the document keeps the route ids it minted.
    func testAnAppWriteMergesAndKeepsRouteIDs() throws {
        try appWrite(studio)
        let ids = store().cameras.flatMap(\.routes).map(\.id)
        var records = studio
        records.append(
            PTPIPSavedCameraRecord(
                host: "172.20.10.2", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: Date(timeIntervalSince1970: 1_900_000_000),
                serialNumber: "6002199", path: .phoneHotspot))
        try appWrite(records)

        let zr = try XCTUnwrap(store().cameras.first { $0.id == "serial:6002199" })
        XCTAssertEqual(Set(zr.routes.map(\.kind)), [.infrastructureNetwork, .usb, .phoneHotspot])
        XCTAssertTrue(Set(ids).isSubset(of: Set(store().cameras.flatMap(\.routes).map(\.id))))
    }

    /// A rename and a forgotten setup on the shared page reach the records an older build reads,
    /// and the app is told (it re-reads them and drops a removed access point's key).
    func testSharedEditsPatchTheRecords() throws {
        try appWrite(studio)
        let store = store()
        var cameras = store.cameras
        let zr = try XCTUnwrap(cameras.firstIndex { $0.id == "serial:6002199" })
        cameras[zr].name = "A cam"
        cameras[zr].routes.removeAll { $0.kind == .usb }
        cameras.removeAll { $0.routes.contains { $0.kind == .cameraAccessPoint } }
        store.save(cameras)

        let records = try appRead()
        XCTAssertEqual(records.map(\.host), ["192.168.1.30"])
        XCTAssertEqual(records.first?.presentation?.customName, "A cam")
        XCTAssertEqual(records.first?.setupName, "Stage left")
        XCTAssertEqual(legacyWrites, 1)
    }

    /// An older build edited the records (added a camera, forgot one, renamed one): the next
    /// launch of this build shows every edit and keeps the document's own route ids.
    func testDowngradeEditsMergeOnUpgrade() throws {
        try appWrite(studio)
        let zrRoutes = try XCTUnwrap(store().cameras.first { $0.id == "serial:6002199" }).routes.map(\.id)

        var old = try appRead()
        old.removeAll { $0.path?.kind == .cameraAccessPoint }
        old[0].presentation = PTPIPSavedCameraPresentation(customName: "Renamed on the old build")
        old.append(
            PTPIPSavedCameraRecord(
                host: "10.0.0.7", displayName: "Z8_4005555", transport: "Wi-Fi", lastSeenAt: Date(timeIntervalSince1970: 1_950_000_000),
                serialNumber: "4005555", path: .infrastructure(networkName: "Set")))
        try appWrite(old)

        let cameras = store().cameras
        XCTAssertEqual(Set(cameras.map(\.id)), ["serial:6002199", "serial:4005555"])
        let zr = try XCTUnwrap(cameras.first { $0.id == "serial:6002199" })
        XCTAssertEqual(zr.name, "Renamed on the old build")
        XCTAssertEqual(zr.routes.map(\.id), zrRoutes)
    }

    /// One record per setup: the app drops one setup of a body that keeps another (an abandoned
    /// pairing, a forget). The setup leaves the document and a shared edit never writes it back.
    func testASetupTheAppDropsStaysGone() throws {
        try appWrite(studio)
        _ = store()
        try appWrite(studio.filter { $0.path != .usbC })

        let store = store()
        let zr = try XCTUnwrap(store.cameras.firstIndex { $0.id == "serial:6002199" })
        XCTAssertEqual(store.cameras[zr].routes.map(\.kind), [.infrastructureNetwork])
        var cameras = store.cameras
        cameras[zr].name = "A cam"
        store.save(cameras)
        XCTAssertFalse(try appRead().contains { $0.host == "usb:demo-zr" })
    }

    /// One record an older or newer build wrote that this one cannot read: kept in the records,
    /// skipped in the document, never overwritten by a shared edit.
    func testABadRecordIsKept() throws {
        var array = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(studio)) as? [Any])
        array.append(["host": 42, "future": true])
        defaults.set(try JSONSerialization.data(withJSONObject: array), forKey: NikonCameras.legacyKey)

        let store = store()
        XCTAssertEqual(store.cameras.count, 2)
        var cameras = store.cameras
        cameras[0].name = "Edited"
        store.save(cameras)

        let stored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: NikonCameras.legacyKey))) as? [[String: Any]])
        XCTAssertEqual(stored.count, 4)
        XCTAssertEqual(stored.last?["future"] as? Bool, true)
    }

    /// Add setup offers what the camera does not have yet; Wi-Fi stays on offer (one setup per
    /// network).
    func testAddSetupOffersMissingKinds() {
        let kinds = NikonCameras.missingKinds(Array(studio.prefix(2)))
        XCTAssertTrue(kinds.contains(.infrastructure))
        XCTAssertTrue(kinds.contains(.cameraAccessPoint))
        XCTAssertTrue(kinds.contains(.phoneHotspot))
        XCTAssertFalse(kinds.contains(.usbC))
    }

    /// The cameras list's discovery is passive (D8: presence and liveness dials stay allowed,
    /// never the PTP/IP port or a PTP byte); only pairing and an armed setup watch probe.
    func testTheCameraListIsPassive() {
        let model = NativeAppModel()
        model.startupMode = .savedCameras
        XCTAssertEqual(model.discoveryMode, .passive)
        model.pendingSetupIntent = .init(anchor: studio[0], kind: .usbC)
        XCTAssertEqual(model.discoveryMode, .active, "an armed setup watch may probe")
        model.pendingSetupIntent = nil
        model.startupMode = .discovery
        XCTAssertEqual(model.discoveryMode, .active, "pairing may probe")
    }
}
