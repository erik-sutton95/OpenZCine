import Foundation
import OpenZCineCore

/// A stored take and its durable completion state; an open file is never shared or deleted.
struct GyroLogEntry: Identifiable, Sendable {
    let descriptor: GyroLogDescriptor
    let summary: GyroLogSummary?
    let active: Bool
    var id: UUID { descriptor.id }
}

/// Recovery preserves every available row even when an individual interrupted file cannot finish.
struct GyroLogRecoveryResult: Sendable {
    let entries: [GyroLogEntry]
    let warning: String?
}

protocol GyroLogStoring: Sendable {
    func load() async throws -> GyroLogRecoveryResult
    func apply(_ updates: [GyroLogUpdate], at time: Double) async throws -> [GyroLogEntry]
    func abort() async -> GyroLogRecoveryResult
    func share(_ id: UUID) async throws -> URL
    func delete(_ id: UUID) async throws -> [GyroLogEntry]
}

enum GyroStoreError: LocalizedError, Equatable {
    case active, missing
    var errorDescription: String? {
        switch self {
        case .active: "This gyro log is still recording."
        case .missing: "The gyro log could not be found."
        }
    }
}

/// Serial file ownership with a one-second durability cadence and atomic metadata publication.
actor GyroLogStore: GyroLogStoring {
    private let directory: URL
    private var entries: [GyroLogEntry] = []
    private var handles: [UUID: FileHandle] = [:]
    private var lastSync: Double = 0

    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? URL.applicationSupportDirectory
            .appendingPathComponent("GyroLogs", isDirectory: true)
    }

    func load() throws -> GyroLogRecoveryResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                let descriptor = try? JSONDecoder().decode(
                    GyroLogDescriptor.self,
                    from: Data(contentsOf: folder.appendingPathComponent("descriptor.json"))),
                descriptor.id == id
            else { return nil }
            let summary = try? JSONDecoder().decode(
                GyroLogSummary.self,
                from: Data(contentsOf: folder.appendingPathComponent("summary.json")))
            return GyroLogEntry(
                descriptor: descriptor, summary: summary, active: handles[id] != nil)
        }
        let warning = recoverInterruptedLogs()
        return GyroLogRecoveryResult(entries: sortedEntries, warning: warning)
    }

    func apply(_ updates: [GyroLogUpdate], at time: Double) throws -> [GyroLogEntry] {
        for update in updates {
            switch update {
            case .opened(let descriptor):
                let folder = folder(descriptor.id)
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                try JSONEncoder().encode(descriptor).write(
                    to: folder.appendingPathComponent("descriptor.json"), options: .atomic)
                let file = partial(descriptor.id)
                try Data().write(to: file, options: .withoutOverwriting)
                handles[descriptor.id] = try FileHandle(forWritingTo: file)
                entries.append(GyroLogEntry(descriptor: descriptor, summary: nil, active: true))
            case .appended(let id, let data):
                guard let handle = handles[id] else { throw GyroStoreError.missing }
                try handle.write(contentsOf: data)
            case .finished(let summary):
                try complete(summary)
            }
        }
        if time - lastSync >= 1 {
            for handle in handles.values { try handle.synchronize() }
            lastSync = time
        }
        return sortedEntries
    }

    func abort() -> GyroLogRecoveryResult {
        for handle in handles.values {
            try? handle.synchronize()
            try? handle.close()
        }
        handles.removeAll()
        entries = entries.map {
            GyroLogEntry(descriptor: $0.descriptor, summary: $0.summary, active: false)
        }
        let warning = recoverInterruptedLogs()
        return GyroLogRecoveryResult(entries: sortedEntries, warning: warning)
    }

    func share(_ id: UUID) throws -> URL {
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw GyroStoreError.missing
        }
        guard !entry.active else { throw GyroStoreError.active }
        guard entry.summary != nil else { throw GyroStoreError.missing }
        let source = finishedURL(entry.descriptor)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw GyroStoreError.missing
        }
        // A stable share copy can outlive deleting the library row while the system sheet is open.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GyroShare/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(entry.descriptor.filename)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    func delete(_ id: UUID) throws -> [GyroLogEntry] {
        guard !entries.contains(where: { $0.id == id && $0.active }) else {
            throw GyroStoreError.active
        }
        try FileManager.default.removeItem(at: folder(id))
        entries.removeAll { $0.id == id }
        return sortedEntries
    }

    private var sortedEntries: [GyroLogEntry] {
        entries.sorted { $0.descriptor.startDate > $1.descriptor.startDate }
    }
    private func folder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private func partial(_ id: UUID) -> URL {
        folder(id).appendingPathComponent("capture.gcsv.part")
    }
    private func finishedURL(_ descriptor: GyroLogDescriptor) -> URL {
        folder(descriptor.id).appendingPathComponent(descriptor.filename)
    }
    private func complete(_ summary: GyroLogSummary) throws {
        let id = summary.id
        if let handle = handles[id] {
            try handle.synchronize()
            try handle.close()
            handles.removeValue(forKey: id)
        }
        let target = finishedURL(summary.descriptor)
        if FileManager.default.fileExists(atPath: partial(id).path) {
            try FileManager.default.moveItem(at: partial(id), to: target)
        }
        try JSONEncoder().encode(summary).write(
            to: folder(id).appendingPathComponent("summary.json"), options: .atomic)
        entries.removeAll { $0.id == id }
        entries.append(
            GyroLogEntry(descriptor: summary.descriptor, summary: summary, active: false))
    }

    private func recoverInterruptedLogs() -> String? {
        var hadFailure = false
        for entry in entries where entry.summary == nil && !entry.active {
            let source =
                FileManager.default.fileExists(atPath: partial(entry.id).path)
                ? partial(entry.id) : finishedURL(entry.descriptor)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            do { try recover(entry, source: source) } catch {
                // A bad header or a failed write affects this take only. Keep saved logs usable,
                // including deletion to free space when recovery could not publish its metadata.
                hadFailure = true
            }
        }
        return hadFailure
            ? "Some interrupted gyro logs could not be recovered. Saved logs remain available."
            : nil
    }

    private func recover(_ entry: GyroLogEntry, source: URL) throws {
        let handle = try FileHandle(forUpdating: source)
        defer { try? handle.close() }
        var recovery = GyroGCSVRecovery()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try recovery.accept(data)
        }
        let summary = try recovery.finish(descriptor: entry.descriptor)
        try handle.truncate(atOffset: recovery.validByteCount)
        try handle.synchronize()
        try handle.close()
        try complete(summary)
    }
}
