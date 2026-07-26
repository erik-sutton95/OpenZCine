// Wire-level proof that the camera stays authoritative.
//
// #257 — connecting a differently-configured body must not reconfigure it. Reported scenario: a
// phone left a Nikon Z5II, connected to a Z6III set to shutter ANGLE, and the Z6III came back on
// shutter SPEED. These drive the real facade session over a socket pair against two fakes that
// differ only in their `MovieShutterMode` readback, and assert on what reached the wire.
//
// #268 — a camera-announced property change must turn into an authoritative read, in photo chrome
// as well as movie chrome.

import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct CameraIdentitySwapTests {
    /// A body on shutter speed, standing in for the Z5II the operator disconnects from.
    private func speedBody() throws -> FakeZRServer {
        var options = FakeZRServer.Options()
        options.movieShutterModeRaw = 1  // speed
        options.model = "Z5II"
        options.serialNumber = "5200001"
        return try FakeZRServer(options: options)
    }

    /// A body on shutter angle, standing in for the Z6III the operator connects to.
    private func angleBody() throws -> FakeZRServer {
        var options = FakeZRServer.Options()
        options.movieShutterModeRaw = 2  // angle
        options.model = "Z6III"
        options.serialNumber = "6300002"
        return try FakeZRServer(options: options)
    }

    private func connect(to server: FakeZRServer) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1",
            port: server.port,
            timeoutMilliseconds: 2_000,
            strategy: .savedProfile,
            onPhase: { _, _ in })
    }

    /// Connect, hydrate the full monitor property + descriptor set, and disconnect.
    private func connectAndHydrate(_ server: FakeZRServer) throws -> PTPCameraPropertySnapshot {
        let session = try connect(to: server)
        defer { session.disconnect() }
        let readback = session.refreshAndroidPropertySnapshot(.bootstrap)
        return readback.properties
    }

    @Test func connectingAndHydratingWritesNothingToEitherBody() throws {
        // Session setup, capability hydration, and descriptor discovery are all READS. The only
        // legitimate connect-time writes in the product are the live-view preview bytes, and those
        // belong to `configureLiveView`, which this flow never calls.
        let z5 = try speedBody()
        defer { z5.stop() }
        let fromZ5 = try connectAndHydrate(z5)
        #expect(fromZ5.shutterMode == .speed)
        #expect(z5.receivedPropertyWrites().isEmpty)

        let z6 = try angleBody()
        defer { z6.stop() }
        let fromZ6 = try connectAndHydrate(z6)
        #expect(fromZ6.shutterMode == .angle)
        #expect(z6.receivedPropertyWrites().isEmpty)
    }

    @Test func reverseSwapAlsoWritesNothing() throws {
        let z6 = try angleBody()
        defer { z6.stop() }
        #expect(try connectAndHydrate(z6).shutterMode == .angle)
        #expect(z6.receivedPropertyWrites().isEmpty)

        let z5 = try speedBody()
        defer { z5.stop() }
        #expect(try connectAndHydrate(z5).shutterMode == .speed)
        #expect(z5.receivedPropertyWrites().isEmpty)
    }

    @Test func reconnectingToTheSameBodyStillWritesNothing() throws {
        // A reconnect must not become the moment the app "restores" anything.
        let z6 = try angleBody()
        defer { z6.stop() }
        for _ in 0..<2 {
            #expect(try connectAndHydrate(z6).shutterMode == .angle)
        }
        #expect(z6.receivedPropertyWrites().isEmpty)
    }

    @Test func aSpeedValueIsRefusedOnAnAngleBodyRatherThanFlippingItsMode() throws {
        // The regression itself: picking a speed-shaped value on a body configured for angle used
        // to write `MovieShutterSpeed`, which makes a Nikon body switch to shutter speed. The
        // control must now be refused, and the wire must stay clean.
        let z6 = try angleBody()
        defer { z6.stop() }
        let session = try connect(to: z6)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)
        let baseline = z6.receivedPropertyWrites().count

        #expect(throws: (any Error).self) {
            try session.applyControl(.shutter, label: "1/50")
        }
        #expect(z6.receivedPropertyWrites().count == baseline)
    }

    @Test func anAngleValueIsRefusedOnASpeedBody() throws {
        let z5 = try speedBody()
        defer { z5.stop() }
        let session = try connect(to: z5)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)
        let baseline = z5.receivedPropertyWrites().count

        #expect(throws: (any Error).self) {
            try session.applyControl(.shutter, label: "180°")
        }
        #expect(z5.receivedPropertyWrites().count == baseline)
    }

    @Test func theMatchingCircuitStillReachesTheBody() throws {
        // The guard must not disarm shutter control: the body's own circuit still writes.
        let z6 = try angleBody()
        defer { z6.stop() }
        let session = try connect(to: z6)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)
        let baseline = z6.receivedPropertyWrites().count

        try session.applyControl(.shutter, label: "180°")
        let writes = Array(z6.receivedPropertyWrites().dropFirst(baseline))
        #expect(writes.map(\.property) == [PTPPropertyCode.movieShutterAngle.rawValue])
    }
}

struct CameraPropertyChangeEventWireTests {
    private func connect(to server: FakeZRServer) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1",
            port: server.port,
            timeoutMilliseconds: 2_000,
            strategy: .savedProfile,
            onPhase: { _, _ in })
    }

    private func valueReadCount(_ server: FakeZRServer) -> Int {
        server.receivedOperations().filter {
            $0 == .getDevicePropValue || $0 == .getDevicePropValueEx
        }.count
    }

    @Test func aPhotoModeApertureAnnouncementNowTriggersARead() throws {
        // The gate used to be `liveMonitorPollOrder.contains(...)`, which holds `movieFNumber` but
        // NOT `fNumber` — so a photo-mode camera-side aperture change was acknowledged and then
        // silently dropped, leaving IRIS to the ~20 s round-robin (#268).
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

        let baseline = valueReadCount(server)
        _ = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.fNumber.rawValue))
        #expect(valueReadCount(server) > baseline)
    }

    @Test func aMovieApertureAnnouncementStillTriggersARead() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

        let baseline = valueReadCount(server)
        _ = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.movieFNumber.rawValue))
        #expect(valueReadCount(server) > baseline)
    }

    @Test func anAnnouncementForAnUndecodedPropertyCostsNoTraffic() throws {
        // An announcement alone is not evidence the monitor can decode the property — the gate
        // must still refuse, so a chatty body cannot turn the event channel into a read storm.
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

        let baseline = valueReadCount(server)
        _ = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.liveViewImageSize.rawValue))
        _ = session.refreshAndroidPropertySnapshot(.propertyChanged(0xDEAD))
        #expect(valueReadCount(server) == baseline)
    }
}
