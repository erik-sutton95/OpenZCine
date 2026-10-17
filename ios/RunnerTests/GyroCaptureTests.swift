import Foundation
import OpenZCineCore
import SwiftUI
import Testing
import UIKit

@testable import Runner

@MainActor @Suite("Phone gyro capture")
struct GyroCaptureTests {
    @Test("The mixed-pose verification controls fit the real landscape test window")
    func calibrationLandscapeUI() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.configure(
            eligible: true, cameraLabel: "Nikon test camera", recording: false,
            calibrationSourceID: 1)
        coordinator.beginMountCalibration()
        for index in 0..<3 {
            fixture.feedCalibrationPose(
                index, into: coordinator, from: 10 + Double(index) * 2,
                incorrectPhone: index == 2)
            coordinator.captureMountCalibration()
        }
        #expect(coordinator.calibrationPoseCount == 2)
        #expect(coordinator.calibrationMessage != nil)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let originalOrientation = scene.interfaceOrientation
        if !scene.interfaceOrientation.isLandscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        for _ in 0..<100 {
            if scene.interfaceOrientation.isLandscape,
                scene.coordinateSpace.bounds.width > scene.coordinateSpace.bounds.height
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(scene.interfaceOrientation.isLandscape)
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: GyroMountView(coordinator: coordinator))
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            coordinator.cancelMountCalibration()
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKeyAndVisible()
            let mask: UIInterfaceOrientationMask =
                switch originalOrientation {
                case .portrait: .portrait
                case .portraitUpsideDown: .portraitUpsideDown
                case .landscapeLeft: .landscapeLeft
                default: .landscapeRight
                }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
        let controls = ["Verify and save", "Start again", "Cancel"]
        let errorMessage = try #require(coordinator.calibrationMessage)
        let labels = controls + [errorMessage]
        var elements: [NSObject] = []
        for _ in 0..<100 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            elements = calibrationUIElements(host.view)
            if labels.allSatisfy({ label in
                elements.contains {
                    $0.accessibilityLabel == label && !$0.accessibilityFrame.isEmpty
                }
            }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(window.bounds.width > window.bounds.height)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try #require(image.pngData())
        Attachment.record(Array(png), named: "SIMULATED-gyro-mixed-pose-verification-landscape.png")
        Attachment.record(
            elements.map {
                "\(type(of: $0)): \($0.accessibilityLabel ?? "") \($0.accessibilityFrame)"
            }.joined(separator: "\n"), named: "SIMULATED-gyro-calibration-accessibility.txt")
        let safeBounds = UIAccessibility.convertToScreenCoordinates(
            window.bounds.inset(by: window.safeAreaInsets), in: window)
        for label in labels {
            let element = try #require(
                elements.first { $0.accessibilityLabel == label },
                Comment(rawValue: "Missing calibration element: \(label)"))
            #expect(!element.accessibilityFrame.isEmpty)
            #expect(safeBounds.contains(element.accessibilityFrame))
            if controls.contains(label) {
                #expect(element.accessibilityTraits.contains(.button))
                #expect(!element.accessibilityTraits.contains(.notEnabled))
            }
        }
    }

    @Test("Calibration saves only after an independent third pose verifies")
    func calibratedMountLifecycle() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.configure(
            eligible: true, cameraLabel: "Nikon test camera", recording: false,
            calibrationSourceID: 1)
        coordinator.beginMountCalibration()
        #expect(coordinator.calibrationInProgress)
        #expect(!coordinator.canCaptureMountCalibration)
        for index in 0..<2 {
            fixture.feedCalibrationPose(index, into: coordinator, from: 10 + Double(index) * 2)
            coordinator.captureMountCalibration()
            #expect(coordinator.calibrationPoseCount == index + 1)
            #expect(coordinator.mountCalibration == nil)
            #expect(
                fixture.defaults.data(forKey: GyroCaptureCoordinator.calibrationPreferenceKey)
                    == nil)
        }
        fixture.feedCalibrationPose(2, into: coordinator, from: 14, incorrectPhone: true)
        coordinator.captureMountCalibration()
        #expect(coordinator.calibrationPoseCount == 2)
        #expect(coordinator.mountCalibration == nil)
        #expect(coordinator.calibrationMessage != nil)
        let validationMessage = coordinator.calibrationMessage
        fixture.feedCalibrationPose(2, into: coordinator, from: 16)
        #expect(coordinator.calibrationMessage == validationMessage)
        coordinator.captureMountCalibration()
        #expect(!coordinator.calibrationInProgress)
        #expect(fixture.driver.gravityReceiver == nil)
        #expect(coordinator.mountName == "Calibrated")
        let saved = try #require(coordinator.mountCalibration)
        #expect(saved.validationErrorDegrees < 0.001)
        let reopened = fixture.coordinator()
        await reopened.waitUntilLoaded()
        #expect(reopened.mountCalibration == saved)
        coordinator.mountPreset = .rearRight
        #expect(coordinator.mountCalibration == nil)
        #expect(
            fixture.defaults.data(forKey: GyroCaptureCoordinator.calibrationPreferenceKey) == nil)
    }

    @Test("Calibration rejects stale readings and missing camera axes")
    func calibrationFreshness() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.configure(
            eligible: true, cameraLabel: "Nikon test camera", recording: false,
            calibrationSourceID: 1)
        coordinator.beginMountCalibration()
        fixture.feedCalibrationPose(0, into: coordinator, from: 10)
        fixture.clock.time += 1
        coordinator.captureMountCalibration()
        #expect(coordinator.calibrationPoseCount == 0)
        #expect(coordinator.calibrationMessage != nil)
        coordinator.receiveCalibrationCamera(nil, at: fixture.clock.time, sourceID: 1)
        #expect(!coordinator.canCaptureMountCalibration)
        coordinator.captureMountCalibration()
        #expect(coordinator.calibrationPoseCount == 0)
        coordinator.cancelMountCalibration()
    }

    @Test("Cancellation retains a prior calibration; reset selects Unconfigured")
    func calibrationCancelAndReset() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        try fixture.seedCalibration()
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        let saved = try #require(coordinator.mountCalibration)
        coordinator.configure(
            eligible: true, cameraLabel: "Nikon test camera", recording: false,
            calibrationSourceID: 1)
        coordinator.beginMountCalibration()
        fixture.feedCalibrationPose(0, into: coordinator, from: 10)
        coordinator.captureMountCalibration()
        coordinator.cancelMountCalibration()
        #expect(coordinator.mountCalibration == saved)
        #expect(fixture.driver.gravityReceiver == nil)
        coordinator.clearMountCalibration()
        #expect(coordinator.mountCalibration == nil)
        #expect(coordinator.mountPreset == .unconfigured)
    }

    @Test("Recording, source changes, backgrounding and disconnect invalidate calibration")
    func calibrationInterruptions() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        #expect(!coordinator.canBeginMountCalibration)
        for reason in [GyroLogTermination.backgrounded, .disconnected] {
            coordinator.configure(
                eligible: true, cameraLabel: "Nikon test camera", recording: false,
                calibrationSourceID: 1)
            coordinator.beginMountCalibration()
            fixture.feedCalibrationPose(0, into: coordinator, from: 10)
            coordinator.captureMountCalibration()
            coordinator.stop(reason: reason)
            #expect(!coordinator.calibrationInProgress)
            #expect(coordinator.calibrationPoseCount == 0)
            #expect(!coordinator.canBeginMountCalibration)
            #expect(fixture.driver.gravityReceiver == nil)
        }
        coordinator.configure(
            eligible: true, cameraLabel: "Nikon test camera", recording: false,
            calibrationSourceID: 1)
        coordinator.beginMountCalibration()
        coordinator.configure(
            eligible: true, cameraLabel: "Nikon test camera", recording: false,
            calibrationSourceID: 2)
        #expect(!coordinator.calibrationInProgress)
        coordinator.beginMountCalibration()
        coordinator.receiveCalibrationCamera(GyroVector3(x: -1, y: 0, z: 0), at: 10, sourceID: 1)
        #expect(!coordinator.canCaptureMountCalibration)
        coordinator.configure(
            eligible: true, cameraLabel: "Nikon test camera", recording: true,
            calibrationSourceID: 2)
        #expect(!coordinator.calibrationInProgress)
        #expect(!coordinator.canBeginMountCalibration)
    }

    @Test("Queued REC freezes calibration even if a manual mount is selected before processing")
    func calibrationRecordingSnapshot() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        try fixture.seedCalibration()
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        let saved = try #require(coordinator.mountCalibration)
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        coordinator.observeRecording(true)
        coordinator.mountPreset = .rearLeft
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        let first = try #require(coordinator.logs.first)
        #expect(first.descriptor.mountCalibration == saved)
        #expect(first.descriptor.alignmentDetail == "Calibrated mount")
        coordinator.observeRecording(false)
        await coordinator.processPending()
        fixture.clock.time = 10.2
        coordinator.observeRecording(true)
        await coordinator.processPending()
        let next = try #require(coordinator.logs.first { $0.id != first.id })
        #expect(next.descriptor.mountCalibration == nil)
        #expect(next.descriptor.mount == .rearLeft)
        #expect(coordinator.logs.first { $0.id == first.id }?.descriptor.mountCalibration == saved)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Calibration is frozen for REC received during asynchronous loading")
    func calibrationRecordingBeforeLoad() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        try fixture.seedCalibration()
        let coordinator = fixture.coordinator()
        let saved = try #require(coordinator.mountCalibration)
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        coordinator.clearMountCalibration()
        await coordinator.waitUntilLoaded()
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.descriptor.mountCalibration == saved)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Core Motion's gyro handler can run on a background sensor queue")
    func backgroundGyroCallback() async {
        let buffer = GyroSampleBuffer()
        let handler = PhoneMotionDriver.gyroHandler(into: buffer)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let ranOnMainThread = await withCheckedContinuation { continuation in
            queue.addOperation {
                handler(nil, nil)
                continuation.resume(returning: Thread.isMainThread)
            }
        }
        #expect(!ranOnMainThread)
        let result = buffer.drain()
        #expect(result.samples.isEmpty)
        #expect(result.failure == .sensorStalled)
    }

    @Test("Mount selection defaults unconfigured and persists across launches")
    func mountPreference() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        #expect(coordinator.mountPreset == .unconfigured)
        coordinator.mountPreset = .rearLeft
        #expect(
            fixture.defaults.string(forKey: GyroCaptureCoordinator.mountPreferenceKey) == "rearLeft"
        )
        let reopened = fixture.coordinator()
        await reopened.waitUntilLoaded()
        #expect(reopened.mountPreset == .rearLeft)
        fixture.defaults.set(
            "unknown future mount", forKey: GyroCaptureCoordinator.mountPreferenceKey)
        let unknown = fixture.coordinator()
        await unknown.waitUntilLoaded()
        #expect(unknown.mountPreset == .unconfigured)
    }

    @Test("Queued REC snapshots its mount and changes apply only to the next take")
    func mountSnapshot() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.mountPreset = .rearLeft
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        coordinator.observeRecording(true)
        coordinator.mountPreset = .frontDown
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        let first = try #require(coordinator.logs.first)
        #expect(first.descriptor.mount == .rearLeft)
        coordinator.observeRecording(false)
        await coordinator.processPending()
        coordinator.mountPreset = .rearRight
        fixture.feed(from: 10.11, through: 10.2)
        coordinator.observeRecording(true)
        await coordinator.processPending()
        #expect(coordinator.logs.first { $0.id == first.id }?.descriptor.mount == .rearLeft)
        let second = try #require(coordinator.logs.first { $0.id != first.id })
        #expect(second.descriptor.mount == .rearRight)
        coordinator.enabled = false
        await coordinator.processPending()
        let exported = try #require(await coordinator.share(first))
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        #expect(
            try String(contentsOf: exported, encoding: .utf8).contains(
                "orientation,\(GyroMountPreset.rearLeft.orientation)\n"))
    }

    @Test("A REC report during recovery keeps its selected mount")
    func mountBeforeLoad() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.mountPreset = .frontUp
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        coordinator.mountPreset = .rearDown
        await coordinator.waitUntilLoaded()
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.descriptor.mount == .frontUp)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Opt-in defaults off and is persisted")
    func optIn() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        #expect(!coordinator.enabled)
        #expect(fixture.driver.starts == 0)
        coordinator.enabled = true
        #expect(fixture.driver.starts == 1)
        coordinator.enabled = false
        await coordinator.processPending()
        #expect(!coordinator.motionRunning)
        coordinator.enabled = true
        #expect(fixture.defaults.bool(forKey: GyroCaptureCoordinator.preferenceKey))
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Only reported REC opens a take; repeated states do not duplicate it")
    func cameraTake() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        fixture.feed(from: 10, through: 11.99)
        await coordinator.processPending()
        #expect(coordinator.logs.isEmpty)
        fixture.clock.time = 12
        coordinator.observeRecording(true)
        coordinator.observeRecording(true)
        await coordinator.processPending()
        #expect(coordinator.logs.count == 1)
        #expect(coordinator.logs.first?.active == true)
        fixture.feed(from: 12, through: 12.99)
        fixture.clock.time = 13
        coordinator.observeRecording(false)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.active == true)
        fixture.feed(from: 13, through: 15)
        await coordinator.processPending()
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.termination == .normal)
        #expect(summary.sampleCount > 490)
        #expect(coordinator.logs.count == 1)
        #expect(coordinator.motionRunning)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("A delayed callback batch does not prune pre-roll before the REC event")
    func delayedStartBatch() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        fixture.feed(from: 10, through: 11.99)
        await coordinator.processPending()
        fixture.clock.time = 12
        coordinator.observeRecording(true)
        fixture.feed(from: 12, through: 12.1)
        await coordinator.processPending()
        coordinator.enabled = false
        await coordinator.processPending()
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.sampleCount == 211)
        #expect(abs(summary.duration - 2.1) < 0.0001)
    }

    @Test(
        "Interruption retains queued samples and releases the sensor",
        arguments: [
            GyroLogTermination.backgrounded, .disconnected, .disabled,
        ])
    func interruption(reason: GyroLogTermination) async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        fixture.feed(from: 10, through: 10.2)
        if reason == .disabled {
            coordinator.enabled = false
        } else {
            coordinator.stop(reason: reason)
        }
        await coordinator.processPending()
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.termination == reason)
        #expect(summary.sampleCount == 21)
        #expect(summary.isPartial)
        #expect(!coordinator.motionRunning)
        #expect(fixture.driver.buffer == nil)
    }

    @Test("Rapid disable and enable finishes the prior take before rearming")
    func rapidRearm() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.mountPreset = .rearLeft
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        coordinator.enabled = false
        coordinator.mountPreset = .frontRight
        coordinator.enabled = true
        #expect(fixture.driver.starts == 1)
        await coordinator.processPending()
        #expect(fixture.driver.starts == 2)
        #expect(coordinator.logs.first?.summary?.termination == .disabled)
        await coordinator.processPending()
        #expect(coordinator.logs.first { $0.active }?.descriptor.mount == .frontRight)
        coordinator.enabled = false
        await coordinator.processPending()
        #expect(!coordinator.motionRunning)
    }

    @Test("Ineligible sources cannot start motion, including a recording report")
    func ineligible() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.enabled = true
        coordinator.configure(eligible: false, cameraLabel: "Relay", recording: true)
        await coordinator.waitUntilLoaded()
        #expect(!coordinator.motionRunning)
        #expect(fixture.driver.starts == 0)
        #expect(coordinator.logs.isEmpty)
    }

    @Test("A REC report during asynchronous recovery is retained")
    func reportBeforeLoad() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        await coordinator.waitUntilLoaded()
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.active == true)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Unavailable sensors and lost callbacks produce a visible failure")
    func sensorFailures() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        fixture.driver.unavailable = true
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        #expect(coordinator.statusIsFailure)
        #expect(!coordinator.motionRunning)
        fixture.driver.unavailable = false
        coordinator.enabled = false
        coordinator.enabled = true
        fixture.clock.time = 13
        await coordinator.processPending()
        #expect(coordinator.statusIsFailure)
        #expect(!coordinator.motionRunning)
    }

    @Test("A nonterminal sensor gap stays visible while the take continues")
    func liveGapWarning() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        fixture.feed(from: 10, through: 10.01)
        await coordinator.processPending()
        fixture.feed(from: 10.2, through: 10.21)
        await coordinator.processPending()
        #expect(coordinator.hasGapWarning)
        #expect(coordinator.statusText == "GYRO GAP")
        #expect(coordinator.motionRunning)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Disk failures abort file ownership and remain visible")
    func writeFailure() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let failing = FailingGyroStore()
        let coordinator = fixture.coordinator(store: failing)
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        #expect(coordinator.statusIsFailure)
        #expect(!coordinator.motionRunning)
        #expect(await failing.aborted)
    }

    @Test("The raw callback handoff retains at most 512 samples")
    func boundedQueue() {
        let buffer = GyroSampleBuffer()
        for index in 0..<600 {
            buffer.append(GyroSample(timestamp: Double(index) / 100, x: 1, y: 2, z: 3))
        }
        let batch = buffer.drain()
        #expect(batch.samples.count == 512)
        #expect(batch.failure == .bufferOverflow)
        #expect(buffer.drain().samples.isEmpty)
    }

    private func calibrationUIElements(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var elements: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            elements.append(object)
            let count = object.accessibilityElementCount()
            if count > 0 && count < 256 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject {
                        visit(child)
                    }
                }
            }
            if let view = object as? UIView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        return elements
    }
}

@MainActor private final class GyroTestClock {
    var time: Double = 10
}

@MainActor private final class FakeGyroDriver: GyroMotionDriving {
    var buffer: GyroSampleBuffer?
    var starts = 0
    var unavailable = false
    var gravityReceiver: ((GyroVector3, Double) -> Void)?
    func startGyro(into buffer: GyroSampleBuffer) throws {
        if unavailable { throw PhoneMotionError.unavailable }
        starts += 1
        self.buffer = buffer
    }
    func stopGyro() { buffer = nil }
    func startGravity(_ receive: @escaping (GyroVector3, Double) -> Void) throws -> UUID {
        if unavailable { throw PhoneMotionError.gravityUnavailable }
        gravityReceiver = receive
        return UUID()
    }
    func stopGravity(_ id: UUID) { gravityReceiver = nil }
}

@MainActor private struct GyroFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = UUID().uuidString
    let driver = FakeGyroDriver()
    let clock = GyroTestClock()
    let defaults: UserDefaults
    init() {
        // SAFETY: a syntactically valid, unique suite always creates a defaults domain.
        defaults = UserDefaults(suiteName: suite)!
    }
    func coordinator(store: (any GyroLogStoring)? = nil) -> GyroCaptureCoordinator {
        GyroCaptureCoordinator(
            defaults: defaults, driver: driver, store: store ?? GyroLogStore(directory: directory),
            now: { clock.time }, automaticProcessing: false)
    }
    func feed(from start: Double, through end: Double) {
        for index in 0...Int(((end - start) * 100).rounded()) {
            driver.buffer?.append(
                GyroSample(timestamp: start + Double(index) / 100, x: 1, y: 2, z: 3))
        }
        clock.time = end
    }
    func feedCalibrationPose(
        _ index: Int, into coordinator: GyroCaptureCoordinator, from base: Double,
        incorrectPhone: Bool = false
    ) {
        let poses = Self.calibrationPoses
        for sample in 0..<40 {
            let time = base + Double(sample) / 30
            coordinator.receiveCalibrationCamera(
                poses[index],
                at: base + Double(sample / 6) / 5, sourceID: 1)
            driver.gravityReceiver?(
                incorrectPhone ? GyroVector3(x: -0.5, y: 0.5, z: 0.7071067811865476) : poses[index],
                time)
            clock.time = time
        }
    }
    func seedCalibration() throws {
        var calibration = GyroMountCalibrationSession()
        var saved: GyroMountCalibration?
        for (index, pose) in Self.calibrationPoses.enumerated() {
            let base = Double(index) * 2
            for sample in 0..<40 {
                calibration.add(
                    phoneDown: pose, phoneTimestamp: base + Double(sample) / 30,
                    cameraDown: pose, cameraTimestamp: base + Double(sample / 6) / 5)
            }
            saved = try calibration.capture(at: base + 39.0 / 30)
        }
        let value = try #require(saved)
        defaults.set(
            try JSONEncoder().encode(value),
            forKey: GyroCaptureCoordinator.calibrationPreferenceKey)
    }
    private static let calibrationPoses = [
        GyroVector3(x: -1, y: 0, z: 0),
        GyroVector3(x: -0.8660254037844386, y: 0, z: 0.5),
        GyroVector3(x: -0.6123724356957945, y: 0.6123724356957945, z: 0.5),
    ]
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor FailingGyroStore: GyroLogStoring {
    var aborted = false
    func load() -> GyroLogRecoveryResult { .init(entries: [], warning: nil) }
    func apply(_ updates: [GyroLogUpdate], at time: Double) throws -> [GyroLogEntry] {
        throw CocoaError(.fileWriteOutOfSpace)
    }
    func abort() -> GyroLogRecoveryResult {
        aborted = true
        return .init(entries: [], warning: nil)
    }
    func share(_ id: UUID) throws -> URL { throw GyroStoreError.missing }
    func delete(_ id: UUID) -> [GyroLogEntry] { [] }
}
