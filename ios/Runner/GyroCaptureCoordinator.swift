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
                if loaded { latestRecordingMount = mountPreset }
                failure = nil
                reconcile()
            }
        }
    }
    var mountPreset: GyroMountPreset {
        didSet { defaults.set(mountPreset.rawValue, forKey: Self.mountPreferenceKey) }
    }
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
    @ObservationIgnored private var observations: [(Bool, Double, Date, String, GyroMountPreset)] =
        []
    @ObservationIgnored private var stopping: GyroLogTermination?
    @ObservationIgnored private var cameraLabel = "Nikon camera"
    @ObservationIgnored private var latestRecording: Bool?
    @ObservationIgnored private var latestRecordingMount: GyroMountPreset = .unconfigured
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var processing = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    static let preferenceKey = "gyroLoggingEnabled.v1"
    static let mountPreferenceKey = "gyroMountPreset.v1"

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

    func openLogs() { logsPresented = true }
    func openMount() { mountPresented = true }

    func waitUntilLoaded() async { await loading?.value }

    func configure(eligible: Bool, cameraLabel: String, recording: Bool?) {
        self.cameraLabel = cameraLabel
        self.eligible = eligible
        if latestRecording != recording { latestRecordingMount = mountPreset }
        latestRecording = recording
        guard eligible else {
            stop(reason: .disconnected)
            return
        }
        reconcile()
        if let recording { observeRecording(recording) }
    }

    func observeRecording(_ recording: Bool) {
        if latestRecording != recording { latestRecordingMount = mountPreset }
        latestRecording = recording
        guard motionRunning, stopping == nil, reportedRecording != recording else { return }
        guard observations.count < GyroTakeSession.maximumBufferedSamples else {
            failure = "Gyro capture stopped because recording events could not be saved in time."
            stop(reason: .bufferOverflow)
            return
        }
        reportedRecording = recording
        observations.append((recording, now(), Date(), cameraLabel, latestRecordingMount))
    }

    func stop(reason: GyroLogTermination) {
        if reason == .backgrounded || reason == .disconnected {
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
        for (recording, timestamp, date, label, mount) in observations {
            let boundary = remaining.firstIndex { $0.timestamp > timestamp } ?? remaining.endIndex
            updates += session.ingest(Array(remaining[..<boundary]))
            updates += session.observeRecording(
                recording, at: timestamp, date: date, cameraLabel: label, mountPreset: mount)
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
