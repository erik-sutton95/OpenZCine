import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

/// The wire format must carry `MonitorZoneLayout.map` frames byte-for-value —
/// the Compose shell renders straight off these records.
struct MonitorZoneMapWireTests {
    // iPhone-class landscape viewport with a leading cutout, live mode.
    private let flat = MonitorZoneMapWire.flattened(
        viewportWidth: 852, viewportHeight: 393,
        safeTop: 0, safeLeading: 59, safeBottom: 21, safeTrailing: 59,
        mode: 0, isPortrait: false, aspectFill: false,
        scopeCount: 0, mirrored: false, bottomBarHeight: 58
    )

    private let map = MonitorZoneLayout.map(
        viewportWidth: 852, viewportHeight: 393,
        safeArea: MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59),
        mode: .live, isPortrait: false, aspect: .fit16x9,
        scopeCount: 0, horizontalDirection: .standard, bottomBarHeight: 58
    )

    /// Record for a kind: `[style, x, y, width, height]`, or nil when absent.
    private func record(_ kind: Float) -> [Float]? {
        for start in stride(from: 0, to: flat.count, by: MonitorZoneMapWire.stride)
        where flat[start] == kind {
            return Array(flat[(start + 1)..<(start + MonitorZoneMapWire.stride)])
        }
        return nil
    }

    @Test func recordsAreWellFormed() {
        #expect(flat.count % MonitorZoneMapWire.stride == 0)
        let allFinite = flat.allSatisfy { $0.isFinite }
        #expect(allFinite)
    }

    @Test func feedFrameMatchesCore() throws {
        let feed = try #require(record(0))
        #expect(feed[0] == -1)
        #expect(feed[1] == Float(map.feed.x))
        #expect(feed[2] == Float(map.feed.y))
        #expect(feed[3] == Float(map.feed.width))
        #expect(feed[4] == Float(map.feed.height))
    }

    @Test func infoBarCarriesPillStyle() throws {
        let info = try #require(record(1))
        #expect(info[0] == 0)  // .infoPill
        #expect(info[1] == Float(map.infoBar.frame.x))
        #expect(info[3] == Float(map.infoBar.frame.width))
    }

    @Test func systemSlotsMatchCore() throws {
        let lock = try #require(record(5))
        #expect(lock[1] == Float(map.systemSlots.lock.x))
        #expect(lock[2] == Float(map.systemSlots.lock.y))
        let rec = try #require(record(7))
        #expect(rec[1] == Float(map.systemSlots.record.x))
        #expect(rec[3] == Float(map.systemSlots.record.width))
    }

    @Test func batteryRailEmitsIndicatorFrames() throws {
        let cluster = try #require(map.batteryCluster)
        #expect(cluster.style == .batteryRail)
        let rail = MonitorBatteryRailLayout.fit(railHeight: cluster.frame.height)
        let phone = try #require(record(13))
        #expect(phone[0] == -1)
        #expect(
            phone[1]
                == Float(
                    cluster.frame.x + rail.phoneCenterX
                        - MonitorBatteryRailLayout.indicatorWidth / 2))
        let camera = try #require(record(14))
        #expect(
            camera[2]
                == Float(
                    cluster.frame.y + rail.cameraCenterY
                        - MonitorBatteryRailLayout.indicatorHeight / 2))
    }

    @Test func landscapeOmitsPortraitOnlyZones() {
        #expect(record(11) == nil)  // scopes float in landscape
        #expect(record(12) == nil)  // controls grid is command/portrait-fit only
    }
}
