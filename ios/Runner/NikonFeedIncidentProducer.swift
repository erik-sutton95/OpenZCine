import Foundation
import OpenCineAppKit
import OpenCineMedia

/// Local observations for one canonical held connection, not a decoder or stream owner.
final class NikonFeedIncidentProducer: @unchecked Sendable {
    final class Preview: @unchecked Sendable {
        fileprivate weak var producer: NikonFeedIncidentProducer?
        fileprivate init(_ producer: NikonFeedIncidentProducer) { self.producer = producer }
        func received() { producer?.note(self, stage: 0) }
        func submitted() { producer?.note(self, stage: 1) }
        func decoded() { producer?.note(self, stage: 2) }
        func published() { producer?.note(self, stage: 3) }
    }

    private let source: FeedIncidentSessionSource
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var closed = false
    private var preview: Preview?
    private var counts = [0, 0, 0, 0]
    private var stamps: [TimeInterval?] = [nil, nil, nil, nil]
    private var previous: (at: TimeInterval, counts: [Int])?

    init(source: FeedIncidentSessionSource,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source
        self.clock = clock
    }

    /// Capture once when the existing preview owner starts; prior callbacks keep their old value.
    func beginPreview() -> Preview {
        lock.withLock {
            let next = Preview(self)
            if !closed {
                preview = next
                stamps = [nil, nil, nil, nil]
            }
            return next
        }
    }

    private func note(_ captured: Preview, stage: Int) {
        lock.withLock {
            guard !closed, preview === captured else { return }
            counts[stage] += 1
            stamps[stage] = clock()
        }
    }

    func snapshot(lifecycle: FeedIncidentLifecycle, now: TimeInterval, wall: Date = Date())
        -> FeedIncidentSnapshot {
        lock.withLock {
            var life = lifecycle
            // A successful image return is observed output. Raster publication is not scanout.
            life.outputObservable = counts[2] > 0
            life.presentationExpected = false
            life.liveEstablished = stamps[3] != nil
            let elapsed = previous.map { now - $0.at } ?? 0
            func rate(_ index: Int) -> Double {
                guard let previous, elapsed > 0 else { return 0 }
                return Double(max(0, counts[index] - previous.counts[index])) / elapsed
            }
            func age(_ index: Int) -> TimeInterval? { stamps[index].map { max(0, now - $0) } }
            let sample = FeedIncidentSnapshot(monotonicNow: now, wallClock: wall,
                rates: .init(accessUnitHz: rate(0), decodeSubmitHz: rate(1), decodedOutputHz: rate(2)),
                ages: .init(accessUnitAge: age(0), decodedOutputAge: age(2)),
                decoder: .init(codec: "jpeg"), lifecycle: life)
            previous = (now, counts)
            return sample
        }
    }

    func publish(lifecycle: FeedIncidentLifecycle) {
        let now = clock()
        let sample = snapshot(lifecycle: lifecycle, now: now)
        lock.withLock { if !closed { source.ingestSnapshot(sample) } }
    }

    func breadcrumb(_ kind: FeedIncidentBreadcrumbKind, detail: String = "") {
        lock.withLock {
            if !closed { source.recordBreadcrumb(.init(monotonicAt: clock(), kind: kind, detail: detail)) }
        }
    }

    func unexpectedDisconnect() {
        lock.withLock { if !closed { source.noteUnexpectedDisconnect(now: clock()) } }
    }

    func end() {
        let shouldEnd = lock.withLock {
            guard !closed else { return false }
            closed = true
            preview = nil
            return true
        }
        if shouldEnd { source.endSession(now: clock()) }
    }
}
