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
        let host = UIHostingController(rootView: AnyView(GyroMountView(coordinator: coordinator)))
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
                "\(type(of: $0)): \($0.accessibilityLabel ?? "") \($0.accessibilityFrame) id=\(GyroReachGeometry.identifier($0) ?? "") traits=\($0.accessibilityTraits.rawValue)"
            }.joined(separator: "\n"), named: "SIMULATED-gyro-calibration-accessibility.txt")
        let safeBounds = UIAccessibility.convertToScreenCoordinates(
            window.bounds.inset(by: window.safeAreaInsets), in: window)
        for label in labels {
            let element = try #require(
                elements.first {
                    $0.accessibilityLabel == label
                        && (!controls.contains(label) || $0.accessibilityTraits.contains(.button))
                },
                Comment(rawValue: "Missing calibration element: \(label)"))
            #expect(!element.accessibilityFrame.isEmpty)
            #expect(safeBounds.contains(element.accessibilityFrame))
            if controls.contains(label) {
                #expect(element.accessibilityTraits.contains(.button))
                #expect(!element.accessibilityTraits.contains(.notEnabled))
            }
        }
        // Under the native input bridge envelope the 44pt floor is proven by the attach-only
        // reader's public coordinate taps with real outcomes and an outside negative; without
        // the envelope this test keeps its direct layout-and-visibility checks alone.
        var reach: [String] = []
        let observer = try GyroReachObserver(
            window: window, host: host, coordinator: coordinator)
        defer { observer.stop() }
        if observer.active {
            let identifiers = [
                "gyro.calibration.capture", "gyro.calibration.restart",
                "gyro.calibration.cancel",
            ]
            let poseControls = try identifiers.map {
                try GyroReachGeometry.control(identifier: $0, in: elements)
            }
            observer.publication = .init(
                mode: "gyro-restart-ready",
                controls: poseControls.map { receiptControl($0, in: window) },
                outsidePoint: GyroReachPoint(
                    try GyroReachGeometry.outsidePoint(above: poseControls), in: window))
            // The reader taps the outside point first (no outcome may change), then the
            // restart control's reach point; restarting resets the pose sequence.
            try await wait("the restart reach outcome") {
                coordinator.calibrationPoseCount == 0
            }
            #expect(coordinator.calibrationInProgress)
            reach.append("restart: poses 0, in progress true")
            observer.ownerObservations = reach
            // Re-begin and reach "Cancel": ending the calibration is that control's outcome.
            coordinator.beginMountCalibration()
            fixture.feedCalibrationPose(0, into: coordinator, from: 16)
            elements = try await settled(host: host, elements: elements, by: identifiers)
            let cancelControls = try identifiers.map {
                try GyroReachGeometry.control(identifier: $0, in: elements)
            }
            observer.publication = .init(
                mode: "gyro-cancel-ready",
                controls: cancelControls.map { receiptControl($0, in: window) })
            try await wait("the cancel reach outcome") { !coordinator.calibrationInProgress }
            reach.append("cancel: in progress false")
            observer.ownerObservations = reach
            // Re-begin once more; the reader reaches "Capture pose" with a fresh pose.
            coordinator.beginMountCalibration()
            fixture.feedCalibrationPose(0, into: coordinator, from: 18)
            elements = try await settled(host: host, elements: elements, by: identifiers)
            let captureControls = try identifiers.map {
                try GyroReachGeometry.control(identifier: $0, in: elements)
            }
            observer.publication = .init(
                mode: "gyro-capture-ready",
                controls: captureControls.map { receiptControl($0, in: window) })
            try await wait("the capture reach outcome") {
                coordinator.calibrationPoseCount == 1
            }
            #expect(coordinator.calibrationInProgress)
            reach.append("capture: poses 1, in progress true")
            observer.ownerObservations = reach
        }
        coordinator.cancelMountCalibration()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        fixture.feed(from: 20, through: 20.1)
        await coordinator.processPending()
        coordinator.enabled = false
        await coordinator.processPending()
        try #require(coordinator.logs.first?.summary != nil)
        coordinator.enabled = true
        var statusPaintFrame = CGRect.zero
        host.rootView = AnyView(
            VStack {
                GyroMonitorStatus(coordinator: coordinator)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: {
                        statusPaintFrame = $0
                    }
                GyroLogsView(coordinator: coordinator)
            }
            .padding(.top, 12))
        for _ in 0..<100 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            elements = calibrationUIElements(host.view)
            if ["Share", "Delete"].allSatisfy({ label in
                elements.contains {
                    $0.accessibilityLabel == label && !$0.accessibilityFrame.isEmpty
                }
            }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Viewport preparation only. The fixture hosts a complete, scrollable production
        // logs screen; bring its long take row into view before publishing any input points.
        // This public scroll operation invokes no gyro action and is not touch evidence.
        let initialLogActions = try ["Share", "Delete"].map {
            try GyroReachGeometry.control(labelled: $0, in: elements)
        }
        if let scroll = elements.compactMap({ $0 as? UIScrollView }).first(where: {
            $0.contentSize.height > $0.bounds.height
        }) {
            let targetOnScreen = initialLogActions.reduce(CGRect.null) {
                $0.union($1.button.accessibilityFrame)
            }
            let targetInWindow = window.convert(targetOnScreen, from: window.screen.coordinateSpace)
            scroll.scrollRectToVisible(
                scroll.convert(targetInWindow, from: window).insetBy(dx: 0, dy: -24),
                animated: false)
        }
        try await wait("the visible log controls and status paint") {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            elements = calibrationUIElements(host.view)
            return !statusPaintFrame.isEmpty
                && ["Share", "Delete"].allSatisfy { label in
                    elements.contains {
                        $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
                            && safeBounds.contains($0.accessibilityFrame)
                    }
                }
        }
        let statusButton = try GyroReachGeometry.control(
            identifier: "monitor.gyroStatus", in: elements
        ).button
        let statusControl = GyroReachGeometry.Control(
            button: statusButton,
            painted: window.convert(statusPaintFrame, to: window.screen.coordinateSpace))
        let logActions = try ["Share", "Delete"].map { label in
            try GyroReachGeometry.control(labelled: label, in: elements)
        }
        for control in [statusControl] + logActions {
            #expect(control.button.accessibilityTraits.contains(.button))
            #expect(!control.button.accessibilityTraits.contains(.notEnabled))
            #expect(safeBounds.contains(control.button.accessibilityFrame))
        }
        Attachment.record(
            ([statusControl] + logActions).map {
                "\($0.button.accessibilityLabel ?? ""): \($0.button.accessibilityFrame)"
            }.joined(separator: "\n"), named: "SIMULATED-gyro-log-touch-targets.txt")
        let logImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(
            Array(try #require(logImage.pngData())),
            named: "SIMULATED-gyro-log-touch-targets-landscape.png")
        // Under the envelope, the reader taps the passive area above the Share/Delete gap
        // (no outcome may change),
        // then the status pill's reach point; `openLogs` is the coordinator's own
        // observation. The reader then opens and closes the real Share sheet before Delete.
        if observer.active {
            let logControls = [statusControl] + logActions
            observer.publication = .init(
                mode: "gyro-logs-ready",
                controls: logControls.map { receiptControl($0, in: window) },
                neighborPoint: GyroReachPoint(
                    try GyroReachGeometry.neighborPoint(
                        between: logActions[0], logActions[1]), in: window))
            try await wait("the status reach outcome") { coordinator.logsPresented }
            reach.append("status: logs presented true")
            observer.ownerObservations = reach
            observer.publication = .init(
                mode: "gyro-share-ready",
                controls: logControls.map { receiptControl($0, in: window) })
            try await wait("the share reach outcome") { host.presentedViewController != nil }
            reach.append("share: system sheet presented")
            observer.ownerObservations = reach
            try await wait("the share sheet's public close") { host.presentedViewController == nil }
            #expect(coordinator.logs.count == 1)
            // The reader reaches Delete, sees the confirmation dialog, and confirms it; the
            // coordinator's own delete empties the logs as the real outcome.
            observer.publication = .init(
                mode: "gyro-delete-ready",
                controls: logControls.map { receiptControl($0, in: window) })
            try await wait("the delete confirm outcome") { coordinator.logs.isEmpty }
            reach.append("delete: logs emptied after confirm")
            observer.ownerObservations = reach
            observer.publication = .init(
                mode: "gyro-settled", controls: logControls.map { receiptControl($0, in: window) })
            // Leave the final owner observation available for the established polling bridge
            // before restoring the original window and stopping its publication timer.
            try await Task.sleep(for: .seconds(1))
        }
        Attachment.record(
            reach.joined(separator: "\n"), named: "SIMULATED-gyro-log-reach.txt")
        if observer.active {
            #expect(observer.writeFailure == nil)
        }
        coordinator.enabled = false
        await coordinator.processPending()
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

    @Test("Only a reported video selector arms; photo and an unread selector wait (ZT-06)")
    func selectorArms() {
        #expect(!GyroCaptureCoordinator.selectorArms(nil))
        #expect(!GyroCaptureCoordinator.selectorArms(.photo))
        #expect(GyroCaptureCoordinator.selectorArms(.video))
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
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
            elements.append(object)
            // The complete vended tree: SwiftUI hands its nodes over through
            // `accessibilityElements`, while indexed elements answer with a second, partial
            // copy — a walk that follows only one of them misses hosted controls.
            var children = object.accessibilityElements as? [NSObject] ?? []
            let count = object.accessibilityElementCount()
            if count > 0, count != NSNotFound, count < 256 {
                children += (0..<count).compactMap {
                    object.accessibilityElement(at: $0) as? NSObject
                }
            }
            children += (object as? UIView)?.subviews ?? []
            for child in children { visit(child) }
        }
        visit(root)
        return elements
    }

    /// Re-walks after a layout change until every identifier is reachable again.
    private func settled(
        host: UIHostingController<AnyView>, elements: [NSObject], by identifiers: [String]
    ) async throws -> [NSObject] {
        for _ in 0..<100 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let walked = calibrationUIElements(host.view)
            if identifiers.allSatisfy({ identifier in
                walked.contains {
                    GyroReachGeometry.identifier($0) == identifier && !$0.accessibilityFrame.isEmpty
                }
            }) {
                return walked
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw GyroReachGeometry.Failure(reason: "The calibration controls never resettled.")
    }

    /// Bounded local poll loop at the accepted 30s convention.
    private func wait(
        _ what: String, bound: Duration = .seconds(30), _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: bound)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw GyroReachGeometry.Failure(reason: "Timed out waiting for \(what).")
    }

    /// The receipt description of one walked control: its identity, its painted and expanded
    /// frames, and the reach point the reader taps in the expanded lower band.
    private func receiptControl(_ control: GyroReachGeometry.Control, in window: UIWindow)
        -> GyroReachControl
    {
        let axFrame = control.button.accessibilityFrame
        let expanded = GyroReachGeometry.region(for: axFrame)
        return GyroReachControl(
            identifier: GyroReachGeometry.identifier(control.button),
            label: control.button.accessibilityLabel,
            button: control.button.accessibilityTraits.contains(.button),
            axFrame: GyroReachRect(axFrame),
            textFrame: control.painted == axFrame ? nil : GyroReachRect(control.painted),
            expandedFrame: GyroReachRect(expanded),
            reachPoint: GyroReachPoint(CGPoint(x: expanded.midX, y: expanded.maxY - 2), in: window))
    }

}

/// Gyro 44pt reach geometry: the painted frame, the expanded hit region the tap-target
/// helpers produce, and the app-published points the attach-only reader taps. The floor is
/// proven by real action outcomes from the reader's public coordinate input, never by frame
/// arithmetic alone; these helpers only describe and locate.
@MainActor
enum GyroReachGeometry {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// One walked control: the button element and the tightest same-label painted frame.
    struct Control {
        let button: NSObject
        let painted: CGRect
    }

    /// The interaction region the tap-target helpers expand to: the accessibility frame
    /// grown symmetrically to Apple's 44pt HIG floor, mirroring `MinTapTargetModifier`'s
    /// positive padding around the measured content.
    static func region(for frame: CGRect) -> CGRect {
        frame.insetBy(
            dx: -max(0, (44 - frame.width) / 2), dy: -max(0, (44 - frame.height) / 2))
    }

    /// Verbatim public getter from the accepted HostedAccessibility.identifier helper.
    /// SwiftUI's vended nodes need not conform to UIAccessibilityIdentification.
    static func identifier(_ object: NSObject) -> String? {
        let getter = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: getter) else { return nil }
        return object.perform(getter)?.takeUnretainedValue() as? String
    }

    /// The walked control with a declared accessibility identifier; identifiers decide over
    /// generic same-label matches wherever the product declares one.
    static func control(identifier: String, in elements: [NSObject]) throws -> Control {
        guard
            let button = elements.first(where: {
                self.identifier($0) == identifier
                    && $0.accessibilityTraits.contains(.button)
            })
        else {
            throw Failure(reason: "Missing \(identifier) in the walked tree.")
        }
        return Control(button: button, painted: paintedFrame(of: button, in: elements))
    }

    /// The button element for `label`. A generic same-label match can hit a static text
    /// title instead of the control, so the button trait decides, per the physical owner's
    /// measured selector evidence.
    static func control(labelled label: String, in elements: [NSObject]) throws -> Control {
        let matching = elements.filter { $0.accessibilityLabel == label }
        let button = matching.first(where: { $0.accessibilityTraits.contains(.button) })
        guard let button else {
            throw Failure(reason: "No \(label) control in the walked tree.")
        }
        return Control(button: button, painted: paintedFrame(of: button, in: elements))
    }

    /// The tightest same-label frame in the walk: the painted control, when the style pads
    /// the button element out to the floor.
    static func paintedFrame(of button: NSObject, in elements: [NSObject]) -> CGRect {
        let frames = elements.filter { $0.accessibilityLabel == button.accessibilityLabel }
            .map(\.accessibilityFrame)
        return frames.min { $0.width * $0.height < $1.width * $1.height }
            ?? button.accessibilityFrame
    }

    /// A point inside the window and at least 8pt above every control's expanded region.
    static func outsidePoint(above controls: [Control]) throws -> CGPoint {
        guard let first = controls.first else {
            throw Failure(reason: "No control frames to avoid.")
        }
        let top =
            controls.map { region(for: $0.button.accessibilityFrame).minY }.min()
            ?? region(for: first.button.accessibilityFrame).minY
        return CGPoint(x: first.button.accessibilityFrame.midX, y: top - 8)
    }

    /// A passive neighbor above the inter-button gap, outside both action bands.
    /// Borderless native buttons can own the nominal horizontal AX gap as well; the 44pt
    /// floor describes a minimum, so an AX-gap midpoint is not an outside-hit oracle.
    static func neighborPoint(between left: Control, _ right: Control) throws -> CGPoint {
        let leftRegion = region(for: left.button.accessibilityFrame)
        let rightRegion = region(for: right.button.accessibilityFrame)
        guard rightRegion.minX - leftRegion.maxX >= 2 else {
            throw Failure(reason: "The sibling gap disappeared; no neighbor point exists.")
        }
        return CGPoint(
            x: (leftRegion.maxX + rightRegion.minX) / 2,
            y: min(leftRegion.minY, rightRegion.minY) - 24)
    }
}

// The receipt value types below are mirrored verbatim in the attach-only reader
// (RunnerUITests): the accepted cross-process contract keeps one shape on both sides.

/// Screen-space point as the app observed it; the reader taps exactly this point.
struct GyroReachPoint: Codable, Equatable {
    let x: Double
    let y: Double
    let nativeX: Double
    let nativeY: Double

    init(_ point: CGPoint, in window: UIWindow) {
        // Geometry and AX frames use the scene-oriented screen space. Public XCTest event
        // screenPoint uses the fixed screen space, so the app observes and publishes both.
        x = point.x.rounded(.down)
        y = point.y.rounded(.down)
        let native = window.screen.coordinateSpace.convert(
            CGPoint(x: x, y: y), to: window.screen.fixedCoordinateSpace)
        nativeX = native.x
        nativeY = native.y
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
    var nativePoint: CGPoint { CGPoint(x: nativeX, y: nativeY) }
    var finite: Bool { [x, y, nativeX, nativeY].allSatisfy(\.isFinite) }
}

/// Screen-space rectangle; the reader compares its device-coordinate edges at screen scale.
struct GyroReachRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = min(rect.origin.x, rect.origin.x + rect.size.width)
        y = min(rect.origin.y, rect.origin.y + rect.size.height)
        width = rect.size.width
        height = rect.size.height
    }

    var rect: CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    func contains(_ point: GyroReachPoint, margin: Double = 0) -> Bool {
        point.x >= x - margin && point.x < x + width + margin
            && point.y >= y - margin && point.y < y + height + margin
    }

    var finite: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

/// One gyro control as the reader must see it: identity, painted and expanded frames, and
/// a reach point 2pt inside the expanded lower edge.
struct GyroReachControl: Codable, Equatable {
    let identifier: String?
    let label: String?
    let button: Bool
    let axFrame: GyroReachRect
    let textFrame: GyroReachRect?
    let expandedFrame: GyroReachRect
    let reachPoint: GyroReachPoint
}

/// The owner observation snapshot: the coordinator and presentation state the reader waits
/// on. The coordinator is the observation; no callbacks are fabricated.
struct GyroReachOutcome: Codable, Equatable {
    let calibrationPoseCount: Int
    let calibrationInProgress: Bool
    let mountCalibrationSaved: Bool
    let logsPresented: Bool
    let logsCount: Int
    let presentedClass: String?
}

/// The app-published reach receipt. The accepted bridge carries it to the reader container;
/// the app never reads a receipt back.
struct GyroReachReceipt: Codable {
    let schema: Int
    let nonce: String
    let sourceSeal: String
    let bundleID: String
    let simulatorID: String
    let processID: Int32
    let sequence: UInt64
    let observedAt: Double
    let mode: String
    let foreground: Bool
    let keyWindow: Bool
    let rootMounted: Bool
    let rootFillsScene: Bool
    let sceneID: String
    let windowIdentity: String
    let windowFrame: GyroReachRect
    let screenFrame: GyroReachRect
    let screenScale: Double
    let orientation: Int
    let controls: [GyroReachControl]
    let outsidePoint: GyroReachPoint?
    let neighborPoint: GyroReachPoint?
    let outcome: GyroReachOutcome
    let ownerObservations: [String]
}

/// Publishes the gyro reach receipt on a fixed timer, mirroring the accepted observer
/// pattern: the only receipt writer in the app and never a receipt reader. It creates no
/// screen, window or control state and sends no input; the phase content is the test's.
@MainActor
final class GyroReachObserver: NSObject {
    struct Publication {
        var mode = ""
        var controls: [GyroReachControl] = []
        var outsidePoint: GyroReachPoint?
        var neighborPoint: GyroReachPoint?
    }

    /// False in a normal suite run without the focused native input envelope.
    private(set) var active = false
    var publication = Publication()
    var ownerObservations: [String] = []
    private(set) var writeFailure: String?

    private let window: UIWindow
    private let host: UIHostingController<AnyView>
    private let coordinator: GyroCaptureCoordinator
    private var nonce = ""
    private var sourceSeal = ""
    private var simulatorID = ""
    private var receiptURL: URL?
    private var timer: Timer?
    private var sequence: UInt64 = 0

    init(window: UIWindow, host: UIHostingController<AnyView>, coordinator: GyroCaptureCoordinator)
        throws
    {
        self.window = window
        self.host = host
        self.coordinator = coordinator
        super.init()
        let env = ProcessInfo.processInfo.environment
        guard env["OPENCINE_NATIVE_UI_MODE"] != nil else { return }
        guard env["OPENCINE_NATIVE_UI_MODE"] == "gyro-hosted-native-input",
            let nonce = env["OPENCINE_NATIVE_UI_NONCE"], UUID(uuidString: nonce) != nil,
            let sourceSeal = env["OPENCINE_NATIVE_UI_SOURCE_SEAL"], sourceSeal.count == 64,
            let bundleID = env["OPENCINE_NATIVE_UI_BUNDLE_ID"],
            bundleID == Bundle.main.bundleIdentifier,
            let simulatorID = env["SIMULATOR_UDID"], UUID(uuidString: simulatorID) != nil
        else {
            throw GyroReachGeometry.Failure(reason: "The native input envelope is incomplete.")
        }
        self.nonce = nonce
        self.sourceSeal = sourceSeal
        self.simulatorID = simulatorID
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SIMULATED-native-cancel-" + nonce, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        receiptURL = directory.appendingPathComponent("app-receipt.json")
        active = true
        let timer = Timer(
            timeInterval: 0.05, target: self, selector: #selector(observe),
            userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        observe()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func observe() {
        guard let receiptURL else { return }
        sequence += 1
        let scene = window.windowScene
        let publication = publication
        let receipt = GyroReachReceipt(
            schema: 1, nonce: nonce, sourceSeal: sourceSeal,
            bundleID: Bundle.main.bundleIdentifier ?? "",
            simulatorID: simulatorID, processID: ProcessInfo.processInfo.processIdentifier,
            sequence: sequence, observedAt: Date().timeIntervalSince1970,
            mode: publication.mode,
            foreground: scene?.activationState == .foregroundActive
                && UIApplication.shared.applicationState == .active,
            keyWindow: window.isKeyWindow && !window.isHidden,
            rootMounted: host.view.window === window,
            rootFillsScene: window.frame == scene?.coordinateSpace.bounds
                && host.view.frame == window.bounds,
            sceneID: scene?.session.persistentIdentifier ?? "",
            windowIdentity: String(describing: ObjectIdentifier(window)),
            windowFrame: GyroReachRect(
                window.convert(window.bounds, to: window.screen.coordinateSpace)),
            screenFrame: GyroReachRect(window.screen.bounds),
            screenScale: Double(window.screen.scale),
            orientation: scene?.interfaceOrientation.rawValue ?? 0,
            controls: publication.controls,
            outsidePoint: publication.outsidePoint,
            neighborPoint: publication.neighborPoint,
            outcome: GyroReachOutcome(
                calibrationPoseCount: coordinator.calibrationPoseCount,
                calibrationInProgress: coordinator.calibrationInProgress,
                mountCalibrationSaved: coordinator.mountCalibration != nil,
                logsPresented: coordinator.logsPresented,
                logsCount: coordinator.logs.count,
                presentedClass: host.presentedViewController.map {
                    String(describing: type(of: $0))
                }), ownerObservations: ownerObservations)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        } catch {
            writeFailure = String(describing: error)
        }
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
