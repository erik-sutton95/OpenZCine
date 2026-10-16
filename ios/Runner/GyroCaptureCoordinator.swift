import Foundation
import Observation
import OpenZCineCore
import UIKit

/// Owns a foreground phone-motion session independently of monitor overlays and the log browser.
@MainActor @Observable final class GyroCaptureCoordinator {
    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.preferenceKey)
            if !enabled { stop(reason: .disabled) }
            if enabled && !oldValue {
                if loaded {
                    latestRecordingMount = mountPreset
                    latestRecordingCalibration = mountCalibration
                }
                failure = nil
                reconcile()
            }
        }
    }
    var mountPreset: GyroMountPreset {
        didSet {
            defaults.set(mountPreset.rawValue, forKey: Self.mountPreferenceKey)
            clearSavedCalibration()
            cancelMountCalibration()
        }
    }
    private(set) var mountCalibration: GyroMountCalibration?
    private(set) var calibrationInProgress = false
    private(set) var calibrationPoseCount = 0
    private(set) var calibrationMessage: String?
    private(set) var calibrationCameraAvailable = false
    private(set) var calibrationCameraHasReading = false
    private(set) var calibrationCameraRecording: Bool?
    private(set) var logs: [GyroLogEntry] = []
    private(set) var failure: String?
    private(set) var storageWarning: String?
    var logsPresented = false
    var mountPresented = false
    private(set) var motionRunning = false
    private(set) var hasGapWarning = false
    private(set) var eligible = false
    private(set) var reportedRecording: Bool?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let driver: any GyroMotionDriving
    @ObservationIgnored private let store: any GyroLogStoring
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private let automaticProcessing: Bool
    @ObservationIgnored private var session = GyroTakeSession()
    @ObservationIgnored private var buffer = GyroSampleBuffer()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var observations:
        [(Bool, Double, Date, String, GyroMountPreset, GyroMountCalibration?)] = []
    @ObservationIgnored private var stopping: GyroLogTermination?
    @ObservationIgnored private var cameraLabel = "Nikon camera"
    @ObservationIgnored private var latestRecording: Bool?
    @ObservationIgnored private var latestRecordingMount: GyroMountPreset = .unconfigured
    @ObservationIgnored private var latestRecordingCalibration: GyroMountCalibration?
    @ObservationIgnored private var calibrationSession = GyroMountCalibrationSession()
    @ObservationIgnored private var calibrationGravityToken: UUID?
    @ObservationIgnored private var calibrationSourceID: Int?
    @ObservationIgnored private var calibrationCamera: (down: GyroVector3, timestamp: Double)?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var processing = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    static let preferenceKey = "gyroLoggingEnabled.v1"
    static let mountPreferenceKey = "gyroMountPreset.v1"
    static let calibrationPreferenceKey = "gyroMountCalibration.v1"

    init(
        defaults: UserDefaults = .standard,
        driver: (any GyroMotionDriving)? = nil,
        store: any GyroLogStoring = GyroLogStore(),
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        automaticProcessing: Bool = true
    ) {
        self.defaults = defaults
        self.driver = driver ?? PhoneMotionDriver.shared
        self.store = store
        self.now = now
        self.automaticProcessing = automaticProcessing
        enabled = defaults.bool(forKey: Self.preferenceKey)
        mountPreset =
            defaults.string(forKey: Self.mountPreferenceKey)
            .flatMap(GyroMountPreset.init(rawValue:)) ?? .unconfigured
        mountCalibration = defaults.data(forKey: Self.calibrationPreferenceKey).flatMap {
            try? JSONDecoder().decode(GyroMountCalibration.self, from: $0)
        }
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                let recovered = try await store.load()
                logs = recovered.entries
                storageWarning = recovered.warning
            } catch {
                failure = "Gyro logs could not be opened: \(error.localizedDescription)"
            }
            loaded = true
            reconcile()
        }
    }

    var statusText: String {
        if failure != nil { return "GYRO ERROR" }
        if !enabled { return "Gyro logging off" }
        if !eligible { return "Waiting for camera" }
        if logs.contains(where: \.active) {
            if hasGapWarning { return "GYRO GAP" }
            return reportedRecording == true ? "GYRO REC" : "GYRO SAVING"
        }
        return motionRunning && session.latestSampleTimestamp != nil
            ? "GYRO ARMED" : "Starting gyro logger"
    }
    var statusIsFailure: Bool { failure != nil }
    var mountName: String { mountCalibration == nil ? mountPreset.shortLabel : "Calibrated" }
    var canBeginMountCalibration: Bool {
        calibrationCameraAvailable && calibrationCameraRecording == false
    }
    var canCaptureMountCalibration: Bool {
        calibrationInProgress && canBeginMountCalibration && calibrationCameraHasReading
    }

    func openLogs() { logsPresented = true }
    func openMount() { mountPresented = true }

    func waitUntilLoaded() async { await loading?.value }

    func configure(
        eligible: Bool, cameraLabel: String, recording: Bool?, calibrationSourceID: Int? = nil
    ) {
        self.cameraLabel = cameraLabel
        self.eligible = eligible
        if self.calibrationSourceID != calibrationSourceID {
            invalidateMountCalibration(message: "Camera source changed. Start calibration again.")
            self.calibrationSourceID = calibrationSourceID
        }
        calibrationCameraAvailable = calibrationSourceID != nil
        calibrationCameraRecording = recording
        if recording == true, calibrationInProgress {
            invalidateMountCalibration(
                message: "Recording started. Start calibration again after stopping.")
            self.calibrationSourceID = calibrationSourceID
            calibrationCameraAvailable = calibrationSourceID != nil
            calibrationCameraRecording = recording
        }
        if latestRecording != recording {
            latestRecordingMount = mountPreset
            latestRecordingCalibration = mountCalibration
        }
        latestRecording = recording
        guard eligible else {
            stop(reason: .disconnected)
            return
        }
        reconcile()
        if let recording { observeRecording(recording) }
    }

    func observeRecording(_ recording: Bool) {
        if latestRecording != recording {
            latestRecordingMount = mountPreset
            latestRecordingCalibration = mountCalibration
        }
        latestRecording = recording
        guard motionRunning, stopping == nil, reportedRecording != recording else { return }
        guard observations.count < GyroTakeSession.maximumBufferedSamples else {
            failure = "Gyro capture stopped because recording events could not be saved in time."
            stop(reason: .bufferOverflow)
            return
        }
        reportedRecording = recording
        observations.append(
            (
                recording, now(), Date(), cameraLabel, latestRecordingMount,
                latestRecordingCalibration
            ))
    }

    func stop(reason: GyroLogTermination) {
        if reason == .backgrounded || reason == .disconnected {
            invalidateMountCalibration(message: "Camera connection ended. Start calibration again.")
            eligible = false
            latestRecording = nil
        }
        if reason == .interrupted { latestRecording = false }
        guard motionRunning, stopping == nil else { return }
        driver.stopGyro()
        stopping = reason
        if reason == .backgrounded {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save gyro log") {
                [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func reconcile() {
        guard enabled, eligible, loaded, failure == nil, worker == nil, !motionRunning else {
            return
        }
        session = GyroTakeSession()
        buffer = GyroSampleBuffer()
        observations.removeAll()
        reportedRecording = nil
        stopping = nil
        hasGapWarning = false
        _ = session.poll(at: now())
        do { try driver.startGyro(into: buffer) } catch {
            failure = error.localizedDescription
            return
        }
        motionRunning = true
        if let latestRecording { observeRecording(latestRecording) }
        guard automaticProcessing else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while motionRunning {
                await processPending()
                if motionRunning { try? await Task.sleep(for: .milliseconds(100)) }
            }
            worker = nil
            reconcile()
        }
    }

    /// Drains samples before state changes or finalization so pending callback batches are retained.
    func processPending() async {
        guard motionRunning, !processing else { return }
        processing = true
        defer {
            processing = false
            if !motionRunning {
                endBackgroundTask()
                if !automaticProcessing { reconcile() }
            }
        }
        let time = now()
        let batch = buffer.drain()
        var updates: [GyroLogUpdate] = []
        var remaining = batch.samples[...]
        // Interleave camera observations with their sensor-time prefixes. Ingesting a whole
        // delayed batch first would prune pre-roll that belongs to an earlier REC observation.
        for (recording, timestamp, date, label, mount, calibration) in observations {
            let boundary = remaining.firstIndex { $0.timestamp > timestamp } ?? remaining.endIndex
            updates += session.ingest(Array(remaining[..<boundary]))
            updates += session.observeRecording(
                recording, at: timestamp, date: date, cameraLabel: label, mountPreset: mount,
                mountCalibration: calibration)
            remaining = remaining[boundary...]
        }
        updates += session.ingest(Array(remaining))
        observations.removeAll(keepingCapacity: true)
        if let reason = stopping ?? batch.failure {
            updates += session.finish(reason: reason, at: time)
            if batch.failure != nil && stopping == nil {
                failure = "Gyro capture stopped because sensor samples were lost."
            }
            stopping = nil
        } else {
            updates += session.poll(at: time)
        }
        // A stalled armed session has no open file, so the core can finish without an update.
        if session.isFinished {
            motionRunning = false
            driver.stopGyro()
            if session.termination == .sensorStalled {
                failure = "Gyro capture stopped because the sensor stopped reporting."
            }
        }
        hasGapWarning = session.hasGapWarning
        do { logs = try await store.apply(updates, at: time) } catch {
            motionRunning = false
            driver.stopGyro()
            failure = "Gyro log could not be saved: \(error.localizedDescription)"
            // The file may contain only part of this batch. Recover bytes actually written,
            // never publish the session's in-memory sample count as a successful disk write.
            let recovered = await store.abort()
            logs = recovered.entries
            storageWarning = recovered.warning
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Uses only a raw, current-session camera header, never the display's filtered level.
    func receiveCalibrationCamera(_ down: GyroVector3?, at timestamp: Double, sourceID: Int) {
        guard sourceID == calibrationSourceID else { return }
        calibrationCamera = down.map { ($0, timestamp) }
        calibrationCameraHasReading = down != nil
    }

    func beginMountCalibration() {
        guard canBeginMountCalibration else {
            calibrationMessage = "Connect a camera with live view and stop recording to calibrate."
            return
        }
        cancelMountCalibration()
        calibrationMessage = nil
        calibrationInProgress = true
        do {
            calibrationGravityToken = try driver.startGravity { [weak self] down, timestamp in
                self?.receiveCalibrationPhone(down, at: timestamp)
            }
        } catch {
            cancelMountCalibration()
            calibrationMessage = error.localizedDescription
        }
    }

    func receiveCalibrationPhone(_ down: GyroVector3, at timestamp: Double) {
        guard calibrationInProgress, let camera = calibrationCamera else { return }
        calibrationSession.add(
            phoneDown: down, phoneTimestamp: timestamp,
            cameraDown: camera.down, cameraTimestamp: camera.timestamp)
    }

    func captureMountCalibration() {
        guard canCaptureMountCalibration else {
            calibrationMessage = "Wait for fresh camera level readings with recording stopped."
            return
        }
        do {
            let result = try calibrationSession.capture(at: now())
            calibrationPoseCount = calibrationSession.poseCount
            calibrationMessage = nil
            if let result {
                let data = try JSONEncoder().encode(result)
                defaults.set(data, forKey: Self.calibrationPreferenceKey)
                mountCalibration = result
                cancelMountCalibration()
            }
        } catch {
            calibrationPoseCount = calibrationSession.poseCount
            calibrationMessage = error.localizedDescription
        }
    }

    func cancelMountCalibration() {
        if let token = calibrationGravityToken { driver.stopGravity(token) }
        calibrationGravityToken = nil
        calibrationSession.reset()
        calibrationPoseCount = 0
        calibrationInProgress = false
        calibrationMessage = nil
    }

    func clearMountCalibration() {
        mountPreset = .unconfigured
        calibrationMessage = nil
    }

    private func clearSavedCalibration() {
        mountCalibration = nil
        defaults.removeObject(forKey: Self.calibrationPreferenceKey)
    }

    func invalidateMountCalibration(message: String? = nil) {
        let wasCalibrating = calibrationInProgress
        cancelMountCalibration()
        calibrationCamera = nil
        calibrationCameraHasReading = false
        calibrationSourceID = nil
        calibrationCameraAvailable = false
        calibrationCameraRecording = nil
        if wasCalibrating { calibrationMessage = message }
    }

    func share(_ entry: GyroLogEntry) async -> URL? {
        do { return try await store.share(entry.id) } catch {
            failure = "Gyro log could not be shared: \(error.localizedDescription)"
            return nil
        }
    }

    func delete(_ entry: GyroLogEntry) async {
        do { logs = try await store.delete(entry.id) } catch {
            failure = "Gyro log could not be deleted: \(error.localizedDescription)"
        }
    }
}
