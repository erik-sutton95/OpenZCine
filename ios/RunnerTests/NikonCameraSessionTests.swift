import Foundation
import OpenCineCore
import Testing

@testable import Runner

/// CORE-02: the Nikon slice behind `OpenCineCore.CameraSession`. The driver stands in for the
/// app model's write queue and safe point; the hooks are called exactly where the model calls them.
@MainActor
@Suite("Nikon camera session seam")
struct NikonCameraSessionTests {

    @MainActor
    final class Driver: NikonControlDriver {
        var nikonControlFacts: NikonControlFacts
        /// What reached the write queue: picker, label and the encoder's writes.
        var queued: [(picker: CameraPicker, label: String, writes: [PTPCameraPropertyWrite])] = []
        var records: [Bool] = []
        /// Simulates an adapter that advertises a value the encoder cannot express.
        var encoderBroken = false

        init(_ facts: NikonControlFacts) { nikonControlFacts = facts }

        func queuePickerWrites(_ label: String, for picker: CameraPicker, operation: OperationID?)
            -> Int
        {
            // The same encoder the model's queue uses.
            let writes =
                encoderBroken
                ? []
                : PTPCameraPropertyWrite.requests(
                    control: picker.cameraControl!, label: label,
                    snapshot: nikonControlFacts.reported)
            if !writes.isEmpty { queued.append((picker, label, writes)) }
            return writes.count
        }

        func queueRecord(start: Bool, operation: OperationID) { records.append(start) }
    }

    /// A ZR in movie mode, exposure M, H.265, idle, with its own live view running.
    static func movieFacts(codec: String = "H.265 10-bit MOV") -> NikonControlFacts {
        NikonControlFacts(
            liveViewReady: true,
            reported: PTPCameraPropertySnapshot(
                iso: 800, isoAuto: false, exposureMode: "M", wbMode: "Auto", wbKelvin: 5560,
                fileType: codec, batteryPercent: 80, captureSelector: .video),
            recording: false,
            whiteBalancePresets: ["Auto", "Natural auto", "Sunny", "Cloudy", "0x8099"])
    }

    @Test("Every advertised writable value reaches the write queue; none is silently unsupported")
    func advertisedValuesAreImplemented() {
        var photo = Self.movieFacts()
        photo.reported = photo.reported.applying(property: .liveViewSelector, data: Data([0]))
        for facts in [Self.movieFacts(), Self.movieFacts(codec: "R3D NE 12-bit R3D"), photo] {
            let driver = Driver(facts)
            let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
            let snapshot = session.refresh()
            for descriptor in snapshot.capabilities.descriptors.values
            where descriptor.access == .readWrite && descriptor.availability == .available {
                guard let domain = descriptor.domain else {
                    #expect(descriptor.key == .recording)
                    #expect(session.request(.startRecording).stage == .admitted)
                    #expect(driver.records == [true])
                    continue
                }
                var values = domain.choices
                if let range = domain.range {
                    values += [range.lowerBound, range.upperBound].map {
                        .whiteBalance(.kelvin(Int($0)))
                    }
                }
                #expect(!values.isEmpty, "\(descriptor.key) advertises an empty domain")
                for value in values {
                    let before = driver.queued.count
                    let receipt = session.request(.set(value))
                    #expect(receipt.stage == .admitted, "\(value) was not admitted")
                    #expect(driver.queued.count == before + 1, "\(value) never reached the queue")
                }
            }
        }
        // The hex preset the decoder cannot name is never advertised.
        let unnamed = Driver(Self.movieFacts())
        let snapshot = NikonCameraSession(driver: unnamed, serialNumber: "").refresh()
        #expect(
            snapshot.capabilities[.whiteBalance]?.accepts(.whiteBalance(.preset("0x8099"))) == false
        )
        #expect(snapshot.device?.isProvisional == true)

        // An advertised value the encoder cannot express never reports progress.
        let broken = Driver(Self.movieFacts())
        broken.encoderBroken = true
        let session = NikonCameraSession(driver: broken, serialNumber: "")
        #expect(session.request(.set(.iso(.manual(1600)))).stage == .failed(.notSent))
    }

    @Test("Readback decides: match confirms, mismatch is not applied, a failed read is unknown")
    func readbackDecidesTheOutcome() {
        let driver = Driver(Self.movieFacts())
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")

        // Kelvin is two writes (colour-temperature mode, then the temperature): both must read back.
        let kelvin = session.request(.set(.whiteBalance(.kelvin(4000)))).operation
        let writes = driver.queued.last!.writes
        #expect(writes.count == 2)
        session.operationSent(kelvin)
        session.writeLanded(kelvin, write: writes[0], readback: writes[0].data)
        #expect(stage(session, kelvin) == .accepted)
        session.writeLanded(kelvin, write: writes[1], readback: writes[1].data)
        #expect(stage(session, kelvin) == .confirmed)

        // The camera took the ISO write but reports a different value (clamped or refused in part).
        let iso = session.request(.set(.iso(.manual(1600)))).operation
        let isoWrite = driver.queued.last!.writes.last!
        session.operationSent(iso)
        let other = PTPCameraPropertyWrite.isoWrite(label: "1250", dualBase: false)!
        session.writeLanded(iso, write: isoWrite, readback: other.data)
        #expect(stage(session, iso) == .failed(.notApplied))

        // The read after the write failed: the value may have landed, so never success.
        let unread = session.request(.set(.iso(.manual(3200)))).operation
        session.operationSent(unread)
        session.writeLanded(unread, write: driver.queued.last!.writes.last!, readback: nil)
        #expect(stage(session, unread) == .outcomeUnknown)

        // A PTP refusal is a rejection; a lost transaction is unknown.
        let refused = session.request(.set(.whiteBalance(.preset("Sunny")))).operation
        session.operationSent(refused)
        session.commandFailed(
            refused,
            NativeCameraSessionError.operationRejected(.setDevicePropValue, .deviceBusy))
        #expect(stage(session, refused) == .rejected(.cameraRefused))
        let lost = session.request(.set(.whiteBalance(.auto))).operation
        session.operationSent(lost)
        session.commandFailed(lost, NativeCameraSessionError.timeout("SetDevicePropValue"))
        #expect(stage(session, lost) == .outcomeUnknown)
    }

    @Test("The confirmed record target runs; a target the camera already reports sends nothing")
    func confirmedRecordTargetIsHonored() {
        // Seam: the prompt asked to start, the camera started on its own meanwhile.
        var facts = Self.movieFacts()
        facts.recording = true
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        #expect(session.request(.startRecording).stage == .confirmed)
        #expect(driver.records.isEmpty, "a satisfied start must not reach the camera")

        // A stop pressed while a start is still queued must replace it, not be skipped because
        // the camera has not started yet (the app-level regression is in RelayRecordControlTests).
        driver.nikonControlFacts.recording = false
        #expect(session.request(.startRecording).stage == .admitted)
        #expect(session.request(.stopRecording).stage == .admitted)
        #expect(driver.records == [true, false])
    }

    @Test("Leaving Auto ISO can write back the off-ladder value the camera parked on")
    func autoParkedISOIsWritable() {
        var facts = Self.movieFacts()
        facts.reported = facts.reported.applying(
            property: .isoControlSensitivity, data: Data(ByteCoding.uint32LE(51_200)))
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        #expect(session.request(.set(.iso(.manual(51_200)))).stage == .admitted)
        #expect(session.request(.set(.iso(.manual(40_000)))).stage == .rejected(.outOfDomain))
    }

    @Test("Settings need no picture; record keeps its live-view preflight")
    func commandsWithoutPicture() {
        var facts = Self.movieFacts()
        facts.liveViewReady = false
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        #expect(session.request(.set(.iso(.manual(400)))).stage == .admitted)
        #expect(session.request(.set(.whiteBalance(.kelvin(3200)))).stage == .admitted)
        #expect(driver.queued.count == 2)
        #expect(session.request(.startRecording).stage == .rejected(.unavailable(.notReady)))
        #expect(driver.records.isEmpty)
    }

    @Test("An accepted record waits for the camera's report, and times out without it")
    func recordWaitsForObservation() async {
        let driver = Driver(Self.movieFacts())
        let session = NikonCameraSession(
            driver: driver, serialNumber: "3000123", recordObservationTimeout: .milliseconds(20))
        let start = session.request(.startRecording).operation
        session.operationSent(start)
        session.recordAccepted(start)
        #expect(stage(session, start) == .awaitingObservation)
        driver.nikonControlFacts.recording = true
        session.refresh()
        #expect(stage(session, start) == .confirmed)
        #expect(session.refresh().recording.value == .recording)

        let stop = session.request(.stopRecording).operation
        session.operationSent(stop)
        session.recordAccepted(stop)
        let outcome = await session.outcome(of: stop)
        #expect(outcome?.stage == .timedOut)
        #expect(session.refresh().recording.value == .recording, "a timeout invents no state")
    }

    @Test("Dropped, closed and unknown stay honest")
    func droppedClosedAndUnknown() async {
        let driver = Driver(NikonControlFacts())
        let blank = NikonCameraSession(driver: driver, serialNumber: "")
        let unknown = blank.refresh()
        #expect(!unknown.recording.isKnown)
        #expect(!unknown.power.battery.isKnown)
        #expect(unknown.settings.isEmpty)
        #expect(unknown.capabilities[.iso]?.availability == .unavailable(.mode))

        // The session holds its driver weakly (the model owns the session), so keep it alive.
        let movie = Driver(Self.movieFacts())
        let session = NikonCameraSession(driver: movie, serialNumber: "1")
        let coalesced = session.request(.set(.iso(.manual(500)))).operation
        session.operationDropped(coalesced)
        #expect(stage(session, coalesced) == .failed(.notSent))

        let inFlight = session.request(.set(.iso(.manual(640)))).operation
        session.operationSent(inFlight)
        let queued = session.request(.set(.whiteBalance(.preset("Cloudy")))).operation
        var feed = session.snapshots().makeAsyncIterator()
        _ = await feed.next()
        session.close(.linkLost)
        #expect(stage(session, inFlight) == .outcomeUnknown)
        #expect(stage(session, queued) == .failed(.notSent))
        #expect(await feed.next()?.connection == .disconnected(.linkLost))
        #expect(await feed.next() == nil)
        #expect(session.request(.set(.iso(.manual(800)))).stage == .rejected(.sessionClosed))
    }

    private func stage(_ session: NikonCameraSession, _ operation: OperationID) -> CommandStage? {
        session.submit(
            CameraCommand(
                .stopRecording,
                preconditions: CommandPreconditions(
                    session: session.id, epoch: ControlEpoch(1),
                    capabilityRevision: CapabilityRevision()),
                operation: operation)
        ).stage
    }
}
