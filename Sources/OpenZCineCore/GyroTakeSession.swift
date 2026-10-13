import Foundation

/// Foreground, camera-observation-driven take segmentation over a monotonic sensor clock.
///
/// Call every method on one platform-owned serial executor. Drain queued samples before polling
/// or finishing. Recording observations are approximate camera timing, never synchronization.
public struct GyroTakeSession: Sendable {
    /// Requested capture frequency on both platforms; measured frequency is reported separately.
    public static let requestedRate = 100.0
    /// Duration retained before an observed camera start and after an observed camera stop.
    public static let coverageSeconds = 2.0
    /// Maximum input batch and prebuffer size; shells also bound their asynchronous capture queues.
    public static let maximumBufferedSamples = 512
    /// No-sample interval that ends armed capture and marks any open take incomplete.
    public static let stallTimeout = 0.5

    /// Last accepted sensor timestamp, useful for platform health presentation.
    public private(set) var latestSampleTimestamp: Double?
    /// True after interruption, overflow, or an explicit finish; construct a new session to re-arm.
    public private(set) var isFinished = false
    /// Why capture ended, including failures while armed that produce no file updates.
    public private(set) var termination: GyroLogTermination?
    /// Whether any take is recording or collecting its postroll.
    public var hasOpenTake: Bool { !takes.isEmpty }
    /// Whether any take is recording or collecting its postroll, for platform status wires.
    public var hasActiveTakes: Bool { !takes.isEmpty }
    /// Whether any open take contains a sensor interval longer than 50 milliseconds.
    public var hasGapWarning: Bool {
        takes.contains { GyroStatistics.exceedsGapLimit($0.statistics.largestGap) }
    }

    private var prebuffer: [GyroSample] = []
    private var observedRecording: Bool?
    private var takes: [Take] = []
    private var armedAt: Double?

    /// Arms an empty logger. Sensor sampling can precede the first camera-state observation.
    public init() {}

    /// Accepts an ordered batch and returns bytes for every take it overlaps, followed by closures.
    /// Oversized batches terminate the session rather than silently dropping samples.
    public mutating func ingest(_ samples: [GyroSample]) -> [GyroLogUpdate] {
        guard !isFinished else { return [] }
        guard samples.count <= Self.maximumBufferedSamples else {
            return finish(reason: .bufferOverflow, at: latestSampleTimestamp ?? 0)
        }
        let accepted = acceptSamples(samples)
        var updates: [GyroLogUpdate] = []
        for index in takes.indices {
            let bytes = takes[index].append(accepted)
            if !bytes.isEmpty {
                updates.append(.appended(id: takes[index].descriptor.id, data: bytes))
            }
        }
        if let latestSampleTimestamp {
            updates += completePostroll(at: latestSampleTimestamp)
        }
        return updates
    }

    /// Observes authoritative camera state; duplicates do nothing and an initial true is partial.
    /// A fixed two-second-before-start origin admits sensor batches delivered after this event.
    public mutating func observeRecording(
        _ recording: Bool, at timestamp: Double, date: Date, cameraLabel: String
    ) -> [GyroLogUpdate] {
        guard !isFinished, timestamp.isFinite, timestamp >= 0 else { return [] }
        if armedAt == nil { armedAt = timestamp }
        guard observedRecording != recording else { return [] }
        let wasUnknown = observedRecording == nil
        observedRecording = recording
        var updates = completePostroll(at: timestamp)
        if !recording {
            for index in takes.indices where takes[index].endTimestamp == nil {
                takes[index].endTimestamp = timestamp + Self.coverageSeconds
            }
            return updates
        }
        let origin = max(0, timestamp - Self.coverageSeconds)
        let descriptor = GyroLogDescriptor(
            cameraLabel: cameraLabel, startDate: date,
            approximateStartOffset: timestamp - origin, isPartial: wasUnknown)
        var take = Take(descriptor: descriptor, origin: origin)
        updates.append(.opened(descriptor))
        updates.append(
            .appended(id: descriptor.id, data: GyroGCSVEncoder.header(descriptor: descriptor)))
        let bytes = take.append(prebuffer)
        if !bytes.isEmpty { updates.append(.appended(id: descriptor.id, data: bytes)) }
        takes.append(take)
        return updates
    }

    /// Completes postrolls and detects stalls even before the first take or sensor sample.
    /// The first valid poll or recording observation anchors the initial no-sample deadline.
    public mutating func poll(at timestamp: Double) -> [GyroLogUpdate] {
        guard !isFinished, timestamp.isFinite, timestamp >= 0 else { return [] }
        if armedAt == nil { armedAt = timestamp }
        let reference = latestSampleTimestamp ?? armedAt ?? timestamp
        if timestamp - reference >= Self.stallTimeout {
            return finish(reason: .sensorStalled, at: timestamp)
        }
        return completePostroll(at: timestamp)
    }

    /// Finalizes every open take without changing camera recording and clears the armed prebuffer.
    public mutating func finish(reason: GyroLogTermination, at _: Double) -> [GyroLogUpdate] {
        guard !isFinished else { return [] }
        isFinished = true
        termination = reason
        let updates = takes.map {
            GyroLogUpdate.finished($0.summary(reason: reason))
        }
        takes.removeAll()
        prebuffer.removeAll()
        return updates
    }

    private mutating func acceptSamples(_ samples: [GyroSample]) -> [GyroSample] {
        var accepted: [GyroSample] = []
        for sample in samples {
            guard sample.isFinite, sample.timestamp >= 0,
                latestSampleTimestamp.map({ sample.timestamp > $0 }) ?? true
            else {
                for index in takes.indices { takes[index].statistics.rejected += 1 }
                continue
            }
            latestSampleTimestamp = sample.timestamp
            accepted.append(sample)
            prebuffer.append(sample)
        }
        if let latestSampleTimestamp {
            prebuffer.removeAll { $0.timestamp < latestSampleTimestamp - Self.coverageSeconds }
        }
        if prebuffer.count > Self.maximumBufferedSamples {
            prebuffer.removeFirst(prebuffer.count - Self.maximumBufferedSamples)
        }
        return accepted
    }

    private mutating func completePostroll(at timestamp: Double) -> [GyroLogUpdate] {
        var updates: [GyroLogUpdate] = []
        takes.removeAll { take in
            guard let end = take.endTimestamp, timestamp >= end else { return false }
            updates.append(.finished(take.summary(reason: .normal)))
            return true
        }
        return updates
    }

    private struct Take: Sendable {
        let descriptor: GyroLogDescriptor
        let origin: Double
        var statistics = GyroStatistics()
        var endTimestamp: Double?
        var lastMicroseconds: Double?

        func summary(reason: GyroLogTermination) -> GyroLogSummary {
            let missingStart =
                statistics.first.map { GyroStatistics.exceedsGapLimit($0 - origin) }
                ?? true
            let missingEnd =
                endTimestamp.map { end in
                    statistics.last.map { GyroStatistics.exceedsGapLimit(end - $0) } ?? true
                } ?? false
            return statistics.summary(
                descriptor, reason: reason, incompleteCoverage: missingStart || missingEnd,
                origin: origin)
        }

        mutating func append(_ samples: [GyroSample]) -> Data {
            var bytes = Data()
            for sample in samples {
                guard sample.timestamp >= origin,
                    endTimestamp.map({ sample.timestamp <= $0 }) ?? true
                else { continue }
                let micros = ((sample.timestamp - origin) * 1_000_000).rounded()
                guard lastMicroseconds.map({ micros > $0 }) ?? true,
                    let row = try? GyroGCSVEncoder.row(sample, origin: origin)
                else {
                    statistics.rejected += 1
                    continue
                }
                bytes.append(row)
                statistics.accept(sample.timestamp)
                lastMicroseconds = micros
            }
            return bytes
        }
    }
}
