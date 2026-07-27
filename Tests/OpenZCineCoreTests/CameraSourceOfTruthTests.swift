// The camera is authoritative. These cover the shared rules that keep it that way:
// camera-announced property changes are decoded and acted on (#268), and connecting or
// picking a value never silently rewrites a body's own configuration (#257).

import Foundation
import Testing

@testable import OpenZCineCore

// MARK: - #268 · DevicePropChanged decoding

struct CameraPropertyEventDecodingTests {
    private func eventPayload(code: UInt16, parameters: [UInt32] = []) -> [UInt8] {
        var bytes = ByteCoding.uint16LE(code)
        bytes += ByteCoding.uint32LE(1)
        for parameter in parameters { bytes += ByteCoding.uint32LE(parameter) }
        return bytes
    }

    @Test func devicePropChangedNamesTheChangedProperty() throws {
        let event = try PTPEvent(
            payloadBytes: eventPayload(
                code: 0x4006, parameters: [PTPPropertyCode.movieFNumber.rawValue]))

        #expect(event.eventCode == .devicePropChanged)
        #expect(event.changedPropertyCode == .movieFNumber)
        // A property announcement is not a record-state hint.
        #expect(event.inferredRecordState == nil)
    }

    @Test func devicePropChangedFromTheGetEventExListDecodesToo() {
        // The poll's array elements carry no transaction ID — the other construction path.
        var bytes = ByteCoding.uint32LE(1)
        bytes += ByteCoding.uint16LE(0x4006)
        bytes += ByteCoding.uint16LE(1)
        bytes += ByteCoding.uint32LE(PTPPropertyCode.fNumber.rawValue)

        let events = PTPNikonEventList.parse(bytes)
        #expect(events.count == 1)
        #expect(events.first?.changedPropertyCode == .fNumber)
    }

    @Test func changedPropertyCodeIsNilForUnusableAnnouncements() throws {
        // No parameter at all.
        let bare = try PTPEvent(payloadBytes: eventPayload(code: 0x4006))
        #expect(bare.eventCode == .devicePropChanged)
        #expect(bare.changedPropertyCode == nil)

        // A property code this build does not model.
        let unmodelled = try PTPEvent(
            payloadBytes: eventPayload(code: 0x4006, parameters: [0xDEAD]))
        #expect(unmodelled.changedPropertyCode == nil)

        // A different event that happens to carry a property-shaped parameter.
        let capture = try PTPEvent(
            payloadBytes: eventPayload(
                code: 0x4002, parameters: [PTPPropertyCode.movieFNumber.rawValue]))
        #expect(capture.changedPropertyCode == nil)
    }
}

// MARK: - #268 · which announcements are worth a read (movie vs still selection)

struct MonitoredPropertyChangeTests {
    @Test func bothApertureFamiliesAreAccepted() {
        // The regression: the gate used the MOVIE poll order alone, so a photo-mode camera-side
        // aperture change (`fNumber`, which appears only in the photo order) was dropped and left
        // to the ~20 s round-robin.
        #expect(PTPPropertyCode.isMonitoredChange(.movieFNumber))
        #expect(PTPPropertyCode.isMonitoredChange(.fNumber))
        #expect(!PTPPropertyCode.liveMonitorPollOrder.contains(.fNumber))
    }

    @Test func bothExposureFamiliesSurviveAModeTransition() {
        for property in [
            PTPPropertyCode.movieShutterSpeed, .movieShutterAngle, .movieISOSensitivity,
            .stillShutterSpeed, .isoControlSensitivity, .imageSize, .liveViewSelector,
        ] {
            #expect(
                PTPPropertyCode.isMonitoredChange(property),
                "\(property) must survive the change gate in either chrome")
        }
    }

    @Test func propertiesTheMonitorNeverDecodesAreRejected() {
        // An announcement alone is not evidence the app can decode the property.
        #expect(!PTPPropertyCode.isMonitoredChange(.liveViewImageSize))
        #expect(!PTPPropertyCode.isMonitoredChange(.liveViewImageCompression))
    }

    @Test func theGateIgnoresRecordingsNarrowedPollSet() {
        // Recording narrows the POLL set to spare the camera radio, but a body-announced change is
        // one read the operator explicitly caused — it must not be dropped mid-take.
        #expect(!PTPPropertyCode.recordingMonitorPollOrder.contains(.movieFNumber))
        #expect(PTPPropertyCode.isMonitoredChange(.movieFNumber))
    }
}

// MARK: - #268 · the announcement queue drains a whole burst, in order

struct AnnouncedPropertyQueueTests {
    /// One detent of an aperture ring: the aperture the operator turned, then its dependents.
    private let ringDetentBurst: [PTPPropertyCode] = [
        .movieFNumber, .exposureIndicateStatus, .isoControlSensitivity,
    ]

    @Test func aWholeBurstDrainsOnTheTickThatSeesIt() {
        // The regression: one property per tick left the rest queued, so a burst took as many
        // frame-gated ticks as it had entries to land.
        var queue = CameraAnnouncedPropertyQueue()
        for property in ringDetentBurst { queue.note(property) }

        #expect(queue.nextBatch() == ringDetentBurst)
        #expect(queue.isEmpty)
    }

    @Test func announcementOrderIsPreserved() {
        // Draining a `Set` with `popFirst()` returned an arbitrary hash-order element, so the one
        // value the operator was staring at could be passed over tick after tick.
        var queue = CameraAnnouncedPropertyQueue()
        let reversed = Array(ringDetentBurst.reversed())
        for property in reversed { queue.note(property) }

        #expect(queue.nextBatch() == reversed)
    }

    @Test func aReAnnouncementIsNotReordered() {
        var queue = CameraAnnouncedPropertyQueue()
        queue.note(.movieFNumber)
        queue.note(.exposureIndicateStatus)
        // The operator keeps turning: the body re-announces the aperture it already queued.
        queue.note(.movieFNumber)

        #expect(queue.pending == [.movieFNumber, .exposureIndicateStatus])
    }

    @Test func theBatchIsCappedAndTheRemainderSurvives() {
        // A chatty body must not monopolise the poll loop — and must not lose announcements
        // either: what the cap defers is read on the next tick, not dropped.
        var queue = CameraAnnouncedPropertyQueue()
        let burst = Array(
            PTPPropertyCode.liveMonitorPollOrder.prefix(
                CameraAnnouncedPropertyQueue.batchLimit + 2))
        for property in burst { queue.note(property) }

        let first = queue.nextBatch()
        #expect(first.count == CameraAnnouncedPropertyQueue.batchLimit)
        #expect(first == Array(burst.prefix(CameraAnnouncedPropertyQueue.batchLimit)))
        #expect(!queue.isEmpty)
        #expect(queue.nextBatch() == Array(burst.dropFirst(first.count)))
        #expect(queue.isEmpty)
    }

    @Test func onlyDecodableAnnouncementsAreQueued() {
        var queue = CameraAnnouncedPropertyQueue()
        queue.note(.liveViewImageSize)
        #expect(queue.isEmpty)
        #expect(queue.nextBatch().isEmpty)
    }

    @Test func aConfirmedWriteCancelsItsPendingReRead() {
        var queue = CameraAnnouncedPropertyQueue()
        for property in ringDetentBurst { queue.note(property) }
        queue.cancel(.movieFNumber)

        #expect(queue.nextBatch() == [.exposureIndicateStatus, .isoControlSensitivity])
    }
}

// MARK: - #268 · bounded polling fallback

struct MonitorPollFallbackTests {
    @Test func theRoundRobinStillCoversEveryPropertyWithoutEvents() {
        // The event path is an accelerator, not a replacement: a body that never emits 0x4006
        // must still see every monitored property come round.
        let order = PTPPropertyCode.monitorPollOrder(isRecording: false, captureSelector: .video)
        var seen: Set<PTPPropertyCode> = []
        for tick in 0..<(order.count * 4) {
            seen.insert(
                CameraMonitorPollPolicy.nextProperty(pollIndex: tick, isRecording: false))
        }
        #expect(seen.isSuperset(of: order))
    }

    @Test func theApertureRevisitGapIsWhyTheEventPathExists() throws {
        // Documents WHY #268 needed the event: with one read per tick and every other tick spent
        // on the selector, `movieFNumber` comes round only once per ~2× the order length. At the
        // shells' ~4 Hz tick that is tens of seconds of stale IRIS after a lens-ring turn.
        let order = PTPPropertyCode.liveMonitorPollOrder
        var visits: [Int] = []
        for tick in 0..<(order.count * 6)
        where
            CameraMonitorPollPolicy.nextProperty(pollIndex: tick, isRecording: false)
            == .movieFNumber
        {
            visits.append(tick)
        }
        let first = try #require(visits.first)
        let second = try #require(visits.dropFirst().first)
        #expect(second - first > order.count)
    }

    @Test func recordingKeepsTheCompactHealthSet() {
        for tick in 0..<12 {
            let property = CameraMonitorPollPolicy.nextProperty(pollIndex: tick, isRecording: true)
            #expect(PTPPropertyCode.recordingMonitorPollOrder.contains(property))
        }
    }
}

// MARK: - #257 · shutter mode and value are one camera-supported state

struct ShutterModeAtomicityTests {
    private func snapshot(_ mode: ShutterDisplayMode?) -> PTPCameraPropertySnapshot {
        PTPCameraPropertySnapshot(shutterMode: mode)
    }

    @Test func anAngleBodyRefusesASpeedValue() {
        // The exact #257 regression direction: a Z6III configured for shutter ANGLE must not be
        // pushed a "1/50" label, because accepting `MovieShutterSpeed` flips the body to speed.
        #expect(
            PTPCameraPropertyWrite.requests(
                control: .shutter, label: "1/50", snapshot: snapshot(.angle)
            ).isEmpty)
    }

    @Test func aSpeedBodyRefusesAnAngleValue() {
        // The reverse swap (Z6III → Z5II) must be just as safe.
        #expect(
            PTPCameraPropertyWrite.requests(
                control: .shutter, label: "180°", snapshot: snapshot(.speed)
            ).isEmpty)
    }

    @Test func aMatchingCircuitStillWrites() {
        let angle = PTPCameraPropertyWrite.requests(
            control: .shutter, label: "180°", snapshot: snapshot(.angle))
        #expect(angle.map(\.property) == [.movieShutterAngle])

        let speed = PTPCameraPropertyWrite.requests(
            control: .shutter, label: "1/50", snapshot: snapshot(.speed))
        #expect(speed.map(\.property) == [.movieShutterSpeed])
    }

    @Test func anUnreportedModeKeepsLabelShapeEncoding() {
        // Bodies that never advertise `MovieShutterMode` must stay controllable: with no
        // authoritative mode there is nothing to contradict, so the label shape still decides.
        #expect(
            PTPCameraPropertyWrite.requests(
                control: .shutter, label: "1/50", snapshot: snapshot(nil)
            ).map(\.property) == [.movieShutterSpeed])
    }

    @Test func modeSwitchingRemainsItsOwnExplicitWrite() {
        // Changing the circuit is `shutterMode(_:)`'s job — an operator action, not a side effect
        // of picking a value.
        #expect(PTPCameraPropertyWrite.shutterMode(.speed).property == .movieShutterMode)
        #expect(
            PTPCameraPropertyWrite.shutterValueProperty(for: .angle) == .movieShutterAngle)
        #expect(
            PTPCameraPropertyWrite.shutterValueProperty(for: .speed) == .movieShutterSpeed)
    }
}

// MARK: - #268 · a late app-originated echo must not outrank a newer camera value

struct StaleWriteOrderingTests {
    @Test func aReadbackAfterAWriteWinsOverTheRequestedBytes() throws {
        // Sequence: the app queues f/4; the operator turns the aperture ring to f/8 while the
        // write is in flight; the poll reads f/8; the write completes. Applying the REQUESTED
        // bytes at that point would show a stale f/4 until the next full poll cycle — applying the
        // camera's own readback keeps the body authoritative.
        let requested = PTPCameraPropertyWrite.request(control: .iris, label: "f/4")
        let request = try #require(requested)

        var snapshot = PTPCameraPropertySnapshot()
        snapshot = snapshot.applying(property: request.property, data: request.data)
        #expect(snapshot.fNumber == "f/4.0")

        // Camera-originated change lands first.
        snapshot = snapshot.applying(
            property: .movieFNumber, data: Data(ByteCoding.uint16LE(800)))
        #expect(snapshot.fNumber == "f/8.0")

        // Write completes: the readback, not the request, is what gets applied.
        let readback = Data(ByteCoding.uint16LE(800))
        snapshot = snapshot.applying(property: request.property, data: readback)
        #expect(snapshot.fNumber == "f/8.0")
    }

    @Test func aClampedWriteReportsWhatTheBodyActuallyTook() throws {
        // A body that clamps to its nearest advertised stop must not be misreported as having
        // taken the requested value.
        let request = try #require(PTPCameraPropertyWrite.request(control: .iris, label: "f/1.2"))
        var snapshot = PTPCameraPropertySnapshot()
        snapshot = snapshot.applying(
            property: request.property, data: Data(ByteCoding.uint16LE(180)))
        #expect(snapshot.fNumber == "f/1.8")
    }
}

// MARK: - #257 · nothing about connecting replays another body's settings

struct SavedCameraRecordAuthorityTests {
    @Test func savedRecordsCarryNoCameraSettings() throws {
        // Presentation metadata only. If a shooting setting ever gains a home here, connecting
        // could replay one body's configuration onto another — the #257 failure mode.
        let record = PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "Z6III",
            transport: "Wi-Fi",
            lastSeenAt: nil,
            presentation: PTPIPSavedCameraPresentation(customName: "A-cam"))
        let encoded = try JSONEncoder().encode(record)
        let fields = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(
            Set(fields.keys)
                == ["host", "displayName", "transport", "presentation"])
        let presentation = try #require(fields["presentation"] as? [String: Any])
        #expect(
            Set(presentation.keys).isSubset(of: ["customName", "borderColor", "icon", "wifiSSID"]))
    }
}
