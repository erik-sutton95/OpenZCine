import Foundation
import Testing

@testable import OpenZCineCore

/// Encodes a PTP string payload (count byte + UTF-16LE + NUL) for building camera-side fixtures.
private func ptpString(_ value: String) -> Data {
    var data = Data()
    let units = Array(value.utf16) + [0]
    data.append(UInt8(units.count))
    for unit in units {
        data.append(contentsOf: ByteCoding.uint16LE(unit))
    }
    return data
}

/// The field report behind this: a body whose clock has drifted keeps its wrong time forever,
/// because nothing ever told it otherwise — the operator asked whether sync was "automatic or a
/// toggle", and the honest answer was "neither".
@Test func aDriftedClockGetsCorrected() {
    let decision = CameraClockSync.decide(
        cameraPayload: ptpString("20260817T101500"),
        phoneNow: CameraClockSync.WallClock(
            year: 2026, month: 8, day: 17, hour: 10, minute: 20, second: 5),
        isRecording: false
    )

    guard case .write(let payload) = decision else {
        Issue.record("expected a write, got \(decision)")
        return
    }
    // The write carries the PHONE's wall clock in the same PTP string shape the camera speaks.
    #expect(payload == ptpString("20260817T102005"))
}

/// Within the threshold nothing is written: transaction latency plus one-second string
/// granularity makes small corrections flappy, and a write per connect that changes nothing
/// visible is churn on the body's settings store.
@Test func aCloseEnoughClockIsLeftAlone() {
    let decision = CameraClockSync.decide(
        cameraPayload: ptpString("20260817T102003"),
        phoneNow: CameraClockSync.WallClock(
            year: 2026, month: 8, day: 17, hour: 10, minute: 20, second: 5),
        isRecording: false
    )

    #expect(decision == .inSync)
}

/// The threshold is a boundary, not a vibe: five seconds off is left alone, six is corrected.
@Test func theThresholdIsExact() {
    let now = CameraClockSync.WallClock(
        year: 2026, month: 8, day: 17, hour: 10, minute: 20, second: 10)

    #expect(
        CameraClockSync.decide(
            cameraPayload: ptpString("20260817T102005"), phoneNow: now, isRecording: false)
            == .inSync)
    guard
        case .write = CameraClockSync.decide(
            cameraPayload: ptpString("20260817T102004"), phoneNow: now, isRecording: false)
    else {
        Issue.record("six seconds of drift must correct")
        return
    }
}

/// A recording body's clock is NEVER touched. Time-of-day timecode derives from this clock on
/// the bodies that run it, and a mid-take clock step is a mid-take timecode step.
@Test func aRecordingBodyIsNeverAdjusted() {
    let decision = CameraClockSync.decide(
        cameraPayload: ptpString("20260817T090000"),
        phoneNow: CameraClockSync.WallClock(
            year: 2026, month: 8, day: 17, hour: 10, minute: 20, second: 5),
        isRecording: true
    )

    #expect(decision == .recordingHoldOff)
}

/// A payload this code cannot read is a body it must not write to. Garbage in, silence out —
/// a clock write built on a misparse could set a camera to a nonsense time.
@Test func anUnreadableClockIsNeverWritten() {
    let empty = CameraClockSync.decide(
        cameraPayload: Data(),
        phoneNow: CameraClockSync.WallClock(
            year: 2026, month: 8, day: 17, hour: 10, minute: 20, second: 5),
        isRecording: false
    )
    let garbage = CameraClockSync.decide(
        cameraPayload: ptpString("not a timestamp"),
        phoneNow: CameraClockSync.WallClock(
            year: 2026, month: 8, day: 17, hour: 10, minute: 20, second: 5),
        isRecording: false
    )

    #expect(empty == .unreadable)
    #expect(garbage == .unreadable)
}

/// Drift is judged across day boundaries too — five to midnight against five past is ten
/// minutes, not twenty-three hours fifty.
@Test func driftCrossesDayBoundaries() {
    guard
        case .write = CameraClockSync.decide(
            cameraPayload: ptpString("20260816T235500"),
            phoneNow: CameraClockSync.WallClock(
                year: 2026, month: 8, day: 17, hour: 0, minute: 5, second: 0),
            isRecording: false)
    else {
        Issue.record("ten minutes across midnight must correct")
        return
    }
}
