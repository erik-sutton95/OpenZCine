import Foundation

/// Paces the between-frames control polls by what one poll actually COSTS on this link.
///
/// Every poll (a `GetEventEx`, a property read) is a PTP round trip on the same channel that
/// carries the live-view feed, so the next frame fetch queues behind it. On the camera's own
/// access point a round trip is a fraction of a frame period and the pipeline absorbs it
/// invisibly; through a set router the same poll can cost one or two whole frame slots — and a
/// fixed every-N-frames cadence turns into a visible, periodic hitch ("the feed stutters every
/// few frames" from set, router path only). Cadence therefore scales with the measured round
/// trip: it trades event/readout latency, invisible at these magnitudes, for frame delivery —
/// the thing actually being looked at.
public enum LiveViewPollPacing {
    /// Baseline frames between `GetEventEx` polls on a fast link.
    public static let baseEventPollStride = 4

    /// Frames between `GetEventEx` polls given the last measured command round trip.
    /// `nil` (nothing measured yet) keeps the baseline.
    public static func eventPollStride(
        roundTripMilliseconds: Double?,
        framePeriodMilliseconds: Double
    ) -> Int {
        baseEventPollStride
            * strideMultiplier(
                roundTripMilliseconds: roundTripMilliseconds,
                framePeriodMilliseconds: framePeriodMilliseconds)
    }

    /// Multiplier for the announced-property queue's IDLE round-robin stride.
    ///
    /// Announced changes — the operator's own hand on the body — deliberately keep their fast
    /// cadence regardless of link cost: one bounded read is worth a frame slot even on a slow
    /// link. Only the background round-robin, which nobody is waiting on, spreads out.
    public static func idlePollStrideMultiplier(
        roundTripMilliseconds: Double?,
        framePeriodMilliseconds: Double
    ) -> Int {
        strideMultiplier(
            roundTripMilliseconds: roundTripMilliseconds,
            framePeriodMilliseconds: framePeriodMilliseconds)
    }

    /// How many baseline strides one poll is worth, from the poll's cost as a fraction of the
    /// frame period. Below half a frame the pipeline absorbs it (decode overlaps the fetch);
    /// past that each step roughly halves how often the feed pays a whole-slot stall.
    private static func strideMultiplier(
        roundTripMilliseconds: Double?,
        framePeriodMilliseconds: Double
    ) -> Int {
        guard let roundTrip = roundTripMilliseconds, framePeriodMilliseconds > 0 else { return 1 }
        let ratio = roundTrip / framePeriodMilliseconds
        switch ratio {
        case ..<0.5: return 1
        case ..<1.0: return 2
        case ..<2.0: return 3
        default: return 5
        }
    }
}
