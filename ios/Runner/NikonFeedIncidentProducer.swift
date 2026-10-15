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
    private var rateSampler = FeedIncidentRateSampler()

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
                rateSampler.reset()
            }
            return next
        }
    }

    private func note(_ captured: Preview, stage: Int) {
        lock.withLock {
            guard !closed, source.isCurrent, preview === captured else { return }
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
            let rates = rateSampler.sample(
                now: now,
                counts: .init(
                    accessUnit: counts[0],
                    decodeSubmit: counts[1], decodedOutput: counts[2]))
            let sample = FeedIncidentSnapshot(monotonicNow: now, wallClock: wall,
                rates: rates,
                ages: .init(
                    accessUnitAge: FeedIncidentRateSampler.age(since: stamps[0], now: now),
                    decodedOutputAge: FeedIncidentRateSampler.age(since: stamps[2], now: now)),
                decoder: .init(codec: "jpeg"), lifecycle: life)
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
