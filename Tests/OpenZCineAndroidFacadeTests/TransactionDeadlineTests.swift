import Foundation
import Testing

@testable import OpenZCineAndroidFacade
@testable import OpenZCineCore

/// The wedge behind issue #328's follow-up: a property write against a body that answers a byte
/// at a time holds the transaction gate for as long as the dribble lasts — and with it, every
/// queued write, the feed, and (until the popup fix) the whole UI. A per-poll timeout cannot see
/// this: every poll finds a byte, so the socket never looks silent. iOS bounds the WHOLE
/// transaction at fifteen seconds and closes the socket on breach; this pins the same rule here.
@Test func aDribblingCameraCannotHoldTheTransactionGatePastTheDeadline() throws {
    var options = FakeZRServer.Options()
    // ~14 response bytes at 250 ms/byte ≈ 3.5 s of dribble — far past the shrunk deadline, far
    // under the suite's patience.
    options.propertyWriteResponseDribbleMillisecondsPerByte = 250
    let server = try FakeZRServer(options: options)
    defer { server.stop() }
    let session = try PTPIPClientSession.connect(
        host: "127.0.0.1", port: server.port, timeoutMilliseconds: 2_000)
    defer { session.disconnect() }
    session.commandTransactionDeadlineNanoseconds = 500_000_000  // 0.5 s for the test

    let start = DispatchTime.now()
    var thrown: Error?
    do {
        _ = try session.executeTransaction(
            .setDevicePropValue,
            parameters: [PTPPropertyCode.movieISOAutoControl.rawValue],
            dataPhase: .dataOut,
            dataOut: Data([1]))
    } catch {
        thrown = error
    }
    let elapsedMilliseconds =
        (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

    // It THREW — the dribble did not run to completion as a slow success.
    #expect(thrown != nil)
    // And it threw on the deadline's clock, not the dribble's: well before the ~3.5 s the full
    // response would take. The margin over 0.5 s absorbs poll granularity and CI scheduling.
    #expect(elapsedMilliseconds < 2_000)
}
