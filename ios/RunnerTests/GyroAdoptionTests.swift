import Foundation
import OpenCineGyro
import Testing
import UIKit

@testable import OpenCineGyroApple
@testable import OpenCineNikon
@testable import Runner

@MainActor
@Suite(.serialized) struct GyroAdoptionTests {
    @Test func hostConfigurationKeepsTheLogDirectory() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyro-adoption-host", isDirectory: true)

        let host = NativeAppModel.gyroHostConfiguration(logDirectory: directory)

        #expect(host.appName == "OpenZCine")
        #expect(host.logDirectory == directory)
        #expect(host.legacyKeys?.enabled == "gyroLoggingEnabled.v1")
        #expect(host.legacyKeys?.mountPreset == "gyroMountPreset.v1")
        #expect(host.legacyKeys?.calibration == "gyroMountCalibration.v1")
    }

    @Test func frameFeedReachesTheCoordinator() async throws {
        let (model, native, _, motion) = try await makeModel()
        model.gyroCapture.enabled = true
        model.nikonGyro.connected(native.identity)
        model.applyCameraRead(.liveViewSelector, Data([1]))
        model.reconcileGyroCapture()
        model.gyroCapture.beginCalibration()
        model.gyroCapture.startRing()
        #expect(model.gyroCapture.isArmed)
        #expect(motion.buffer != nil)
        let frame = PTPLiveViewFrame(
            jpeg: Data([1]), timecode: Timecode(on: false, hour: 0, minute: 0, second: 0, frame: 0),
            isRecording: true, level: PTPLevelAngles(roll: 0, pitch: 0, yaw: 0))

        let consumed = await model.consumeCameraFrame(
            frame,
            delivery: NikonLiveViewPump.Delivery(
                first: true, headerOnly: true, frameCounter: 1, bodyBusy: false),
            session: native, incident: nil)
        #expect(consumed)
        motion.buffer?.append(
            OpenCineGyro.GyroSample(
                timestamp: ProcessInfo.processInfo.systemUptime, x: 0.01, y: 0.02, z: 0.03))

        var levelArrived = false
        let logged = await waitUntil {
            if case .posing = model.gyroCapture.ring { levelArrived = true }
            return model.gyroCapture.logs.contains(where: { $0.active }) && levelArrived
        }
        #expect(logged)
        #expect(levelArrived)
    }

    @Test func ibisWritesGoThroughTheCameraQueue() async throws {
        let (model, native, _, _) = try await makeModel()
        native.close()
        let write = try #require(PTPCameraPropertyWrite.vibrationReduction(label: "OFF"))

        let result = Task { await model.writeGyroStabilization([write]) }
        for _ in 0..<100 {
            if model.debugPendingCameraWriteCount == 1 { break }
            await Task.yield()
        }

        #expect(model.debugPendingCameraWriteCount == 1)
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await result.value)
        #expect(model.debugPendingCameraWriteCount == 0)
    }

    @Test func disconnectRestoresBeforeClosing() async throws {
        let (model, native, transport, state) = try await makeModel()
        model.gyroCapture.enabled = true
        model.nikonGyro.connected(native.identity)
        model.applyCameraRead(.movieVibrationReduction, Data([2]))
        model.applyCameraRead(.electronicVR, Data([1]))
        model.applyCameraRead(.liveViewSelector, Data([1]))
        model.reconcileGyroCapture()
        model.gyroCapture.setupTurnOffStabilization()
        await model.gyroCapture.waitForCameraWrites()
        #expect(model.gyroCapture.isArmed)
        let pendingData = try #require(
            state.keyValues.data(forKey: GyroPreferenceKeys.namespaced("gyro.v2.").pendingRestores))
        let pending = try JSONDecoder().decode([GyroPendingRestore].self, from: pendingData)
        #expect(pending.map(\.saved) == [["movieVR": "SPORT", "electronicVR": "ON"]])
        #expect(
            model.gyroCapture.stabilization?.values == ["movieVR": "OFF", "electronicVR": "OFF"])

        model.disconnect()
        model.disconnect()
        for _ in 0..<100 {
            if !model.debugHasCameraSession && model.debugPendingCameraWriteCount == 0 { break }
            if model.debugPendingCameraWriteCount > 0 {
                _ = await model.debugServiceNextCameraWrite()
            } else {
                await Task.yield()
            }
        }
        await model.gyroCapture.waitForCameraWrites()

        for _ in 0..<100 {
            if await transport.calls.last?.operation == .closeSession { break }
            await Task.yield()
        }
        let calls = await transport.calls
        let writes = calls.filter {
            $0.operation == .setDevicePropValue || $0.operation == .closeSession
        }
        #expect(!model.debugHasCameraSession)
        #expect(model.debugPendingCameraWriteCount == 0)
        #expect(
            writes.suffix(3).map(\.operation) == [
                .setDevicePropValue, .setDevicePropValue, .closeSession,
            ])
        let restoreValues = writes.filter { $0.operation == .setDevicePropValue }.suffix(2)
        #expect(restoreValues.map { $0.dataOut.map { Array($0) } } == [[2], [1]])
        #expect(model.debugHasDiscoveryLoop)
    }

    @Test func internetHopRestoresBeforeLeavingTheCameraNetwork() async throws {
        let (model, native, transport, _) = try await makeModel()
        await armGyro(model, native: native)
        var leaves = 0
        model.hopNative = .init(
            currentSSID: { "SIMULATED-AP" },
            leaveNetwork: { _, _ in leaves += 1 }, rejoin: nil)

        model.beginInternetHop()
        for _ in 0..<100 {
            if leaves == 1 { break }
            await Task.yield()
        }

        #expect(leaves == 1)
        for _ in 0..<100 {
            if await transport.calls.last?.operation == .closeSession { break }
            await Task.yield()
        }
        let calls = await transport.calls
        #expect(
            calls.filter { $0.operation == .setDevicePropValue }.suffix(2).map {
                $0.dataOut.map { Array($0) }
            } == [[2], [1]])
        #expect(calls.last?.operation == .closeSession)
        native.close()
    }

    @Test func demoEntryRestoresBeforeEnablingTheDemoWriteGuard() async throws {
        let (model, native, transport, _) = try await makeModel()
        await armGyro(model, native: native)

        model.startDemoSession()
        for _ in 0..<100 {
            if model.isDemoSession { break }
            await Task.yield()
        }

        #expect(model.isDemoSession)
        for _ in 0..<100 {
            if await transport.calls.last?.operation == .closeSession { break }
            await Task.yield()
        }
        let calls = await transport.calls
        #expect(
            calls.filter { $0.operation == .setDevicePropValue }.suffix(2).map {
                $0.dataOut.map { Array($0) }
            } == [[2], [1]])
        #expect(calls.last?.operation == .closeSession)
        native.close()
    }

    @Test func gyroWriteFailsWhenReadbackDoesNotMatch() async throws {
        let (model, native, transport, _) = try await makeModel()
        let movie = try #require(PTPCameraPropertyWrite.vibrationReduction(label: "SPORT"))
        let electronic = PTPCameraPropertyWrite.electronicVR(on: true)

        #expect(await model.writeGyroStabilization([movie]))
        await transport.refuseNextWrite()
        #expect(await model.writeGyroStabilization([electronic]) == false)
        native.close()
    }

    @Test func disconnectedSessionRejectsGyroWriteWithoutQueueing() async throws {
        let model = NativeAppModel()
        let write = try #require(PTPCameraPropertyWrite.vibrationReduction(label: "OFF"))
        let result = Task { await model.writeGyroStabilization([write]) }
        for _ in 0..<100 {
            if model.debugPendingCameraWriteCount > 0 { break }
            await Task.yield()
        }

        #expect(model.debugPendingCameraWriteCount == 0)
        if model.debugPendingCameraWriteCount == 0 {
            #expect(await result.value == false)
        } else {
            result.cancel()
        }
    }

    @Test func joinRelayKeepsRelayStateAfterGyroRestore() async throws {
        let (model, native, transport, _) = try await makeModel()
        await armGyro(model, native: native)
        let discovery = MonitorRelayDiscovery(
            id: "SIMULATED-gyro-relay", name: "SIMULATED gyro relay",
            endpoint: .hostPort(host: "127.0.0.1", port: 65500))
        defer { model.leaveRelay() }

        model.joinRelay(discovery)
        for _ in 0..<100 {
            if await transport.calls.last?.operation == .closeSession { break }
            await Task.yield()
        }

        #expect(model.videoSource == .relay)
        let calls = await transport.calls
        #expect(
            calls.filter { $0.operation == .setDevicePropValue }.suffix(2).map {
                $0.dataOut.map { Array($0) }
            } == [[2], [1]])
        native.close()
    }

    @Test func leavingDuringGyroRestoreCancelsRelayJoin() async throws {
        let (model, native, _, _) = try await makeModel()
        await armGyro(model, native: native)
        let discovery = MonitorRelayDiscovery(
            id: "SIMULATED-cancelled-relay", name: "SIMULATED cancelled relay",
            endpoint: .hostPort(host: "127.0.0.1", port: 65500))

        model.joinRelay(discovery)
        model.leaveRelay()
        let completed = await waitUntil { model.debugRelayJoinTaskCompleted }

        #expect(completed)
        #expect(model.debugRelayClientCreationCount == 0)
        #expect(model.videoSource != .relay)
        native.close()
    }

    @Test func disconnectDuringGyroRestoreCancelsRelayJoin() async throws {
        let (model, native, _, _) = try await makeModel()
        await armGyro(model, native: native)
        let discovery = MonitorRelayDiscovery(
            id: "SIMULATED-disconnect-relay", name: "SIMULATED disconnect relay",
            endpoint: .hostPort(host: "127.0.0.1", port: 65500))

        model.joinRelay(discovery)
        model.disconnect()
        let completed = await waitUntil { model.debugRelayJoinTaskCompleted }

        #expect(completed)
        #expect(model.debugRelayClientCreationCount == 0)
        #expect(model.videoSource != .relay)
        native.close()
    }

    @Test func secondRelayJoinSupersedesTheFirst() async throws {
        let (model, native, transport, _) = try await makeModel()
        await armGyro(model, native: native)
        let first = MonitorRelayDiscovery(
            id: "SIMULATED-first-relay", name: "SIMULATED first relay",
            endpoint: .hostPort(host: "127.0.0.1", port: 65500))
        let second = MonitorRelayDiscovery(
            id: "SIMULATED-second-relay", name: "SIMULATED second relay",
            endpoint: .hostPort(host: "127.0.0.1", port: 65501))
        defer { model.leaveRelay() }

        model.joinRelay(first)
        model.joinRelay(second)
        let completed = await waitUntil { model.debugRelayJoinTaskCompleted }
        #expect(completed)
        for _ in 0..<100 {
            if await transport.calls.last?.operation == .closeSession { break }
            await Task.yield()
        }

        #expect(model.debugRelayClientCreationCount == 1)
        #expect(model.videoSource == .relay)
        let calls = await transport.calls
        #expect(calls.last?.operation == .closeSession)
        native.close()
    }

    @Test func enabledGyroSettingsRemainActionableWhileUnavailable() {
        let model = NativeAppModel()
        model.gyroCapture.enabled = true

        #expect(model.gyroSettingsAvailable)
    }

    @Test func demoSessionNeverWrites() async throws {
        let model = NativeAppModel()
        model.startDemoSession()
        let write = try #require(PTPCameraPropertyWrite.vibrationReduction(label: "OFF"))

        #expect(await model.writeGyroStabilization([write]) == false)
        #expect(model.debugPendingCameraWriteCount == 0)
    }

    @Test func demoLoggingWorksWithoutCameraWrites() async throws {
        let motion = GyroAdoptionMotion()
        let model = NativeAppModel(
            gyroCapture: OpenCineGyroApple.GyroCaptureCoordinator(
                host: NativeAppModel.gyroHostConfiguration(logDirectory: motion.logDirectory),
                driver: motion,
                keyValueStore: motion.keyValues))
        await model.gyroCapture.waitUntilLoaded()
        model.startDemoSession()
        model.setGyroCaptureEnabled(true)
        #expect(model.gyroCapture.camera != nil)
        #expect(model.gyroCapture.isArmed)
        #expect(model.gyroCapture.motionRunning)
        #expect(motion.buffer != nil)
        model.preferences.recordConfirmationEnabled = false
        model.toggleRecording()
        motion.buffer?.append(
            OpenCineGyro.GyroSample(
                timestamp: ProcessInfo.processInfo.systemUptime, x: 0.01, y: 0.02, z: 0.03))
        model.toggleRecording()
        let logged = await waitUntil { model.gyroCapture.logs.contains(where: { !$0.active }) }
        let write = try #require(PTPCameraPropertyWrite.vibrationReduction(label: "OFF"))

        #expect(!model.debugHasCameraSession)
        #expect(logged)
        #expect(await model.writeGyroStabilization([write]) == false)
        #expect(model.debugPendingCameraWriteCount == 0)
    }

    @Test func upgradeKeepsLogsToggleAndCalibration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyro-adoption-upgrade-\(UUID().uuidString)", isDirectory: true)
        let suite = "gyro-adoption-upgrade-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let vectors = [
            OpenCineGyro.GyroVector3(x: -1, y: 0, z: 0),
            OpenCineGyro.GyroVector3(x: -sqrt(0.75), y: 0, z: 0.5),
            OpenCineGyro.GyroVector3(x: -0.75, y: sqrt(0.1875), z: 0.5),
        ]
        let poses = vectors.map {
            OpenCineGyro.GyroCalibrationPose(phoneDown: $0, cameraDown: $0)
        }
        let calibration = try OpenCineGyro.GyroMountCalibration.solve(
            first: poses[0], second: poses[1], validation: poses[2])
        defaults.set(true, forKey: "gyroLoggingEnabled.v1")
        defaults.set("rearDown", forKey: "gyroMountPreset.v1")
        defaults.set(try JSONEncoder().encode(calibration), forKey: "gyroMountCalibration.v1")
        let host = NativeAppModel.gyroHostConfiguration(logDirectory: directory)
        let store = OpenCineGyro.GyroLogStore(directory: host.logDirectory)
        _ = try await store.load()
        let finished = OpenCineGyro.GyroLogDescriptor(
            appName: host.appName, cameraLabel: "Nikon test camera",
            startDate: Date(timeIntervalSince1970: 10), approximateStartOffset: 2,
            isPartial: false)
        let finishedFolder = host.logDirectory.appendingPathComponent(
            finished.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: finishedFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(finished).write(
            to: finishedFolder.appendingPathComponent("descriptor.json"))
        let header = OpenCineGyro.GyroGCSVEncoder.header(descriptor: finished)
        try header.write(to: finishedFolder.appendingPathComponent(finished.filename))
        let descriptorObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(finished)) as? [String: Any]
        )
        let summary: [String: Any] = [
            "descriptor": descriptorObject, "sampleCount": 2, "duration": 0.01,
            "measuredRate": 100.0, "largestGap": 0.01, "rejectedSampleCount": 0,
            "termination": "normal", "isPartial": false, "approximateStartOffset": 2.0,
        ]
        try JSONSerialization.data(withJSONObject: summary).write(
            to: finishedFolder.appendingPathComponent("summary.json"))
        let saved = try await store.load().entries
        var interrupted = OpenCineGyro.GyroTakeSession(appName: host.appName)
        var updates = interrupted.observeRecording(
            true, at: 20, date: Date(), cameraLabel: "Nikon test camera")
        updates += interrupted.ingest([OpenCineGyro.GyroSample(timestamp: 20, x: 1, y: 2, z: 3)])
        let unfinished = try await store.apply(updates, at: 20.1)
        _ = await store.abort()
        let camera = GyroAdoptionCamera()
        let coordinator = OpenCineGyroApple.GyroCaptureCoordinator(
            host: host, keyValueStore: UserDefaultsGyroStore(defaults: defaults),
            automaticProcessing: false)

        await coordinator.waitUntilLoaded()
        coordinator.attach(camera)
        camera.sink?.receive(.connected(.init(id: "nikon-123", name: "Nikon test camera")))

        #expect(coordinator.enabled)
        #expect(coordinator.logs.count == 2)
        #expect(saved[0].descriptor.isPartial == false)
        #expect(saved[0].summary?.termination == .normal)
        #expect(coordinator.logs.first { $0.id == saved[0].id }?.status == .notCalibrated)
        #expect(coordinator.logs.first { $0.id == unfinished[0].id }?.status == .cutShort)
        #expect(defaults.object(forKey: "gyroMountPreset.v1") == nil)
        #expect(coordinator.hasSavedCalibration)
        camera.sink?.receive(.disconnected)
        camera.sink?.receive(.connected(.init(id: "nikon-456", name: "Second camera")))
        #expect(!coordinator.hasSavedCalibration)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }

    private func armGyro(_ model: NativeAppModel, native: NativeCameraSession) async {
        model.gyroCapture.enabled = true
        model.nikonGyro.connected(native.identity)
        model.applyCameraRead(.movieVibrationReduction, Data([2]))
        model.applyCameraRead(.electronicVR, Data([1]))
        model.applyCameraRead(.liveViewSelector, Data([1]))
        model.reconcileGyroCapture()
        model.gyroCapture.setupTurnOffStabilization()
        await model.gyroCapture.waitForCameraWrites()
        #expect(model.gyroCapture.isArmed)
    }

    private func makeModel() async throws -> (
        NativeAppModel, NativeCameraSession, LargeTransferTransport, GyroAdoptionMotion
    ) {
        let transport = LargeTransferTransport(
            operations: [.setDevicePropValue, .getDevicePropValue], kind: .ptpIP)
        let native = try await NativeCameraSession.establish(
            transport: transport, host: "tcp:SIMULATED-gyro-adoption",
            cameraName: "SIMULATED", requestPairing: false)
        let motion = GyroAdoptionMotion()
        let model = NativeAppModel(
            gyroCapture: OpenCineGyroApple.GyroCaptureCoordinator(
                host: NativeAppModel.gyroHostConfiguration(logDirectory: motion.logDirectory),
                driver: motion,
                keyValueStore: motion.keyValues))
        model.debugAdoptEstablishedMediaSession(native)
        model.connectedIdentity = native.identity
        model.connection = .connected
        model.gyroCapture.attach(model.nikonGyro)
        model.isMonitorPresented = true
        await model.gyroCapture.waitUntilLoaded()
        return (model, native, transport, motion)
    }
}

private final class GyroAdoptionKeyValues: GyroKeyValueStore {
    private var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func setData(_ data: Data?, forKey key: String) { values[key] = data }
}

@MainActor private final class GyroAdoptionMotion: OpenCineGyroApple.GyroMotionDriving {
    let keyValues = GyroAdoptionKeyValues()
    let logDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gyro-adoption-\(UUID().uuidString)", isDirectory: true)
    var buffer: OpenCineGyroApple.GyroSampleBuffer?

    deinit { try? FileManager.default.removeItem(at: logDirectory) }

    func startGyro(into buffer: OpenCineGyroApple.GyroSampleBuffer) throws { self.buffer = buffer }
    func stopGyro() { buffer = nil }
    func startMotion(_ receive: @escaping (OpenCineGyro.GyroDriftReading) -> Void) throws
        -> UUID
    { UUID() }
    func stopMotion(_ id: UUID) {}
    func startLevel(_ receive: @escaping (Double, Double, Double) -> Void) -> UUID { UUID() }
    func stopLevel(_ id: UUID) {}
}

@MainActor private final class GyroAdoptionCamera: GyroCameraAdapter {
    let providesLevel = true
    let stabilizationSettings: [GyroStabilizationSetting] = []
    weak var sink: (any GyroCameraSink)?

    func attach(_ sink: any GyroCameraSink) { self.sink = sink }
    func detach() { sink = nil }
    func writeStabilization(_ values: [String: String]) async -> Bool { true }
}
