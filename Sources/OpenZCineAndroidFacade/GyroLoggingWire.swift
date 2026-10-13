import Foundation
import OpenZCineCore

/// Owner-keyed Android bridge over the same per-take policy used by iOS.
public final class GyroLoggingWire: @unchecked Sendable {
    /// Process-local registry; every operation names its capture owner.
    public static let shared = GyroLoggingWire()
    private let lock = NSLock()
    private var sessions: [String: GyroTakeSession] = [:]
    private var recoveries: [String: GyroGCSVRecovery] = [:]

    /// Creates an isolated capture owner, without starting sensors or touching files.
    public func create() -> String {
        lock.withLock {
            let owner = UUID().uuidString
            sessions[owner] = GyroTakeSession()
            return owner
        }
    }

    /// Supplies mount choices for phones whose natural sensor axes match portrait iPhones.
    /// Other device frames remain unconfigured rather than exporting an incorrect alignment.
    public func mountPresets(naturalPortrait: Bool = true) -> String {
        let presets: [GyroMountPreset] =
            naturalPortrait ? GyroMountPreset.allCases : [.unconfigured]
        let choices = presets.map { preset in
            GyroMountChoice(
                id: preset.id, title: preset.title, group: preset.group,
                shortLabel: preset.shortLabel, detail: preset.detail,
                orientation: preset.orientation)
        }
        // SAFETY: all choices contain only enum-owned strings, which JSONEncoder can encode.
        guard let data = try? JSONEncoder().encode(choices),
            let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    /// Decodes bounded little-endian `[timestamp, x, y, z]` Double batches.
    public func ingest(owner: String, bytes: [UInt8]) -> String? {
        guard bytes.count.isMultiple(of: 32), bytes.count <= 512 * 32 else { return nil }
        var samples: [GyroSample] = []
        for offset in stride(from: 0, to: bytes.count, by: 32) {
            let values = stride(from: offset, to: offset + 32, by: 8).map { start in
                var bits: UInt64 = 0
                for index in 0..<8 { bits |= UInt64(bytes[start + index]) << (index * 8) }
                return Double(bitPattern: bits)
            }
            samples.append(
                GyroSample(timestamp: values[0], x: values[1], y: values[2], z: values[3]))
        }
        return update(owner: owner) { $0.ingest(samples) }
    }

    /// Supplies a camera observation, not a command target or capture timestamp.
    public func observe(
        owner: String, recording: Bool, timestamp: Double,
        dateSeconds: Double, cameraLabel: String,
        mountPreset: String = GyroMountPreset.unconfigured.rawValue
    ) -> String? {
        guard timestamp.isFinite, dateSeconds.isFinite,
            let mount = GyroMountPreset(rawValue: mountPreset)
        else { return nil }
        return update(owner: owner) {
            $0.observeRecording(
                recording, at: timestamp,
                date: Date(timeIntervalSince1970: dateSeconds), cameraLabel: cameraLabel,
                mountPreset: mount)
        }
    }

    /// Advances postroll and sensor-stall checks on the platform sensor timebase.
    public func poll(owner: String, timestamp: Double) -> String? {
        guard timestamp.isFinite else { return nil }
        return update(owner: owner) { $0.poll(at: timestamp) }
    }

    /// Finalizes available samples honestly without changing camera recording.
    public func finish(owner: String, reason: String, timestamp: Double) -> String? {
        guard let reason = GyroLogTermination(rawValue: reason), timestamp.isFinite else {
            return nil
        }
        return update(owner: owner) { $0.finish(reason: reason, at: timestamp) }
    }

    /// Retires an owner after its platform has processed finalization updates.
    public func close(owner: String) { _ = lock.withLock { sessions.removeValue(forKey: owner) } }

    /// Starts streaming validation of an abandoned platform-owned partial file.
    public func recoveryCreate() -> String {
        lock.withLock {
            let owner = UUID().uuidString
            recoveries[owner] = GyroGCSVRecovery()
            return owner
        }
    }

    /// Returns the complete valid prefix length, or nil for an invalid header.
    public func recoveryAccept(owner: String, bytes: [UInt8]) -> Int64? {
        guard bytes.count <= 65_536 else { return nil }
        return lock.withLock {
            guard var recovery = recoveries[owner] else { return nil }
            do { try recovery.accept(Data(bytes)) } catch { return nil }
            recoveries[owner] = recovery
            return Int64(clamping: recovery.validByteCount)
        }
    }

    /// Summarizes recovered samples and retires the recovery owner on every exit.
    public func recoveryFinish(owner: String, descriptorJSON: String) -> String? {
        lock.withLock {
            guard let recovery = recoveries.removeValue(forKey: owner),
                let bytes = descriptorJSON.data(using: .utf8)
            else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard let descriptor = try? decoder.decode(GyroLogDescriptor.self, from: bytes),
                let summary = try? recovery.finish(descriptor: descriptor),
                let data = try? Self.encoder().encode(summary)
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private func update(
        owner: String,
        operation: (inout GyroTakeSession) -> [GyroLogUpdate]
    ) -> String? {
        lock.withLock {
            guard var session = sessions[owner] else { return nil }
            let updates = operation(&session).map(GyroWireUpdate.init)
            sessions[owner] = session
            let reply = GyroWireReply(
                updates: updates, active: session.hasActiveTakes,
                gapWarning: session.hasGapWarning, finished: session.isFinished,
                termination: session.termination?.rawValue,
                hasSamples: session.latestSampleTimestamp != nil)
            guard let data = try? Self.encoder().encode(reply) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

private struct GyroMountChoice: Encodable {
    let id: String
    let title: String
    let group: String?
    let shortLabel: String
    let detail: String
    let orientation: String
}

private struct GyroWireReply: Encodable {
    let updates: [GyroWireUpdate]
    let active: Bool
    let gapWarning: Bool
    let finished: Bool
    let termination: String?
    let hasSamples: Bool
}

private struct GyroWireUpdate: Encodable {
    let kind: String
    let id: UUID
    var descriptor: GyroLogDescriptor?
    var data: String?
    var summary: GyroLogSummary?

    init(_ update: GyroLogUpdate) {
        switch update {
        case .opened(let value):
            kind = "opened"
            id = value.id
            descriptor = value
        case .appended(let owner, let bytes):
            kind = "appended"
            id = owner
            data = bytes.base64EncodedString()
        case .finished(let value):
            kind = "finished"
            id = value.id
            summary = value
        }
    }
}
