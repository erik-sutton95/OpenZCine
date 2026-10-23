import Foundation

/// Per-quantum evidence belongs to the current session and is never persisted with marks/templates.
struct FocusRackCommandTiming: Sendable {
    var longest = 0.0
    var total = 0.0
    var count = 0

    var average: Double { count == 0 ? 0 : total / Double(count) }

    mutating func record(_ duration: Double) {
        longest = max(longest, duration)
        total += duration
        count += 1
    }
}

/// Chunks retain the original mark unit: a 64-pulse command completes four 16-pulse units.
struct FocusRackMovementPlan: Sendable {
    let signedSteps: Int
    let chunks: [Int]
    let offsets: [Double]
    let duration: Double
    let delay: Double
    let minimumDuration: Double
    let maximumDuration: Double?
    let estimatedDuration: Double?
    // Next command index -> earliest read start, in the same fixed epoch as offsets.
    // nil retains the legacy periodic-refresh policy; an explicit schedule owns its reads.
    var maintenanceReadOffsets: [Int: Double]? = nil
}

/// Keeps fine setup units while selecting bounded command sizes for the requested timing.
/// Scheduling estimates cannot establish optical smoothness; rehearse the selected lens and span.
enum FocusRackPlanner {
    static let calibrationQuanta = [2, 3, 4, 6, 8]
    // The fine source trial used 94 increments over 24 seconds. This conservative spacing envelope
    // rejects sparse long moves; it is not a guarantee of optical smoothness on another lens.
    static let maximumFineSpacing = 24.0 / 93.0

    // Every stage must deliver its actual quantum inside the bounded mark-to-mark move.
    static func supportsCalibration(span: Int) -> Bool {
        span <= 10_000 && calibrationQuanta.allSatisfy { $0 <= span }
    }

    static func make(
        signedSteps: Int, duration: Double, delay: Double, easing: FocusRackEasing,
        quiet: Double, timings: [Int: FocusRackCommandTiming], adaptive: Bool,
        timed: Bool, grouped: Bool, profile: FocusRackProfile = .adaptive,
        safetyReadBudget: Double = 0,
        calibrationQuantum: Int? = nil
    ) throws -> FocusRackMovementPlan {
        guard signedSteps != 0, signedSteps != .min, abs(signedSteps) <= 10_000,
            duration.isFinite, duration > 0, delay.isFinite, delay >= 0,
            quiet.isFinite, quiet >= 0, safetyReadBudget.isFinite, safetyReadBudget >= 0
        else { throw FocusRackError.invalidConfiguration }
        let sign = signedSteps < 0 ? -1 : 1
        let count = abs(signedSteps)
        if let calibrationQuantum {
            guard !timed, grouped, profile == .calibratedFineExperiment,
                supportsCalibration(span: count),
                calibrationQuanta.contains(calibrationQuantum)
            else { throw FocusRackError.invalidConfiguration }
        }
        if !timed {
            let quantum =
                calibrationQuantum
                ?? (adaptive && grouped
                    ? (profile != .adaptive && count == 100 ? 10 : 12) : 1)
            var chunks = Array(repeating: sign * quantum, count: count / quantum)
            if count % quantum != 0 { chunks.append(sign * (count % quantum)) }
            let known = chunks.allSatisfy { timings[abs($0)]?.count ?? 0 > 0 }
            let estimate =
                known
                ? chunks.reduce(0.0) { $0 + (timings[abs($1)]?.average ?? 0) }
                    + quiet * Double(chunks.count - 1) : nil
            return .init(
                signedSteps: signedSteps, chunks: chunks,
                offsets: Array(repeating: delay, count: chunks.count),
                duration: estimate ?? 0, delay: delay, minimumDuration: 0,
                maximumDuration: nil, estimatedDuration: estimate)
        }
        if adaptive, grouped, count > 1 {
            let quanta: [Int]
            if profile == .calibratedFineExperiment, easing == .linear {
                quanta = [1] + calibrationQuanta + [10]
            } else if profile == .tenBy160Experiment, count == 100, duration == 1, easing == .linear
            {
                guard timings[10]?.count ?? 0 > 0 else {
                    throw FocusRackError.calibrationRequired
                }
                quanta = [10]
            } else {
                quanta = [1, 2, 3, 4, 5, 9, 12]
            }
            return try adaptiveTimed(
                signedSteps: signedSteps, duration: duration, delay: delay, easing: easing,
                quiet: quiet, timings: timings, quanta: quanta, safetyReadBudget: safetyReadBudget,
                requireMeasured: profile == .calibratedFineExperiment
                    && easing == .linear,
                preserveFineFamily: profile == .calibratedFineExperiment && duration == 3
                    && easing == .linear)
        }
        let cost = timings[1]?.longest ?? 0
        let trajectory = try FocusRackTrajectory(
            signedSteps: signedSteps, duration: duration, delay: delay, easing: easing,
            commandInterval: quiet + cost, finalCommandDuration: cost)
        return .init(
            signedSteps: signedSteps, chunks: Array(repeating: sign, count: count),
            offsets: trajectory.offsets, duration: duration, delay: delay,
            minimumDuration: trajectory.minimumDuration, maximumDuration: nil,
            estimatedDuration: nil)
    }

    private struct TimedCandidate {
        let chunks: [Int]
        let fractions: [Double]
        let finalCost: Double
        let minimum: Double
        let maximum: Double
    }

    private static func adaptiveTimed(
        signedSteps: Int, duration: Double, delay: Double, easing: FocusRackEasing,
        quiet: Double, timings: [Int: FocusRackCommandTiming], quanta: [Int],
        safetyReadBudget: Double, requireMeasured: Bool, preserveFineFamily: Bool
    ) throws -> FocusRackMovementPlan {
        let count = abs(signedSteps)
        let sign = signedSteps < 0 ? -1 : 1
        // Unmeasured sizes use the session's worst observed command as an estimate, not a
        // measurement of that size. Every completed command updates its own budget; late runs halt.
        let fallback = timings.values.map(\.longest).max() ?? 0
        // Long pulls reserve a qualified read window. Short pulls are checked against their
        // actual post-preflight evidence age before activation, without a future idle read.
        let planningReadBudget =
            requireMeasured && duration >= 2 ? max(0.1, safetyReadBudget) : safetyReadBudget
        let maintenance = duration >= 2 ? planningReadBudget : 0
        let candidates = quanta.compactMap { quantum -> TimedCandidate? in
            var chunks = Array(repeating: sign * quantum, count: count / quantum)
            if count % quantum != 0 { chunks.append(sign * (count % quantum)) }
            guard chunks.count > 1 else { return nil }
            if requireMeasured,
                !chunks.allSatisfy({ timings[abs($0)]?.count ?? 0 > 0 })
            {
                return nil
            }
            let costs = chunks.map { timings[abs($0)]?.longest ?? fallback }
            var position = 0
            let span = count - abs(chunks[chunks.count - 1])
            let fractions = chunks.map { chunk in
                let fraction = easing.timeFraction(forPosition: Double(position) / Double(span))
                position += abs(chunk)
                return fraction
            }
            let gaps = zip(fractions, fractions.dropFirst()).map { $1 - $0 }
            let finalCost = costs[costs.count - 1]
            let minimum = zip(costs, gaps).map { ($0 + quiet + maintenance) / $1 }.max() ?? 0
            // Coarse commands must not be stretched into sparse schedules: earlier source
            // recordings showed stepping there. Keep the same start-gap cap at every size.
            let maximum = gaps.map { maximumFineSpacing / $0 }.min() ?? 0
            return .init(
                chunks: chunks, fractions: fractions, finalCost: finalCost,
                minimum: minimum + finalCost, maximum: maximum + finalCost)
        }
        let viable = candidates.filter {
            focusRackMinimumForDisplay($0.minimum) <= focusRackMaximumForDisplay($0.maximum) + 1e-9
        }
        if requireMeasured, duration >= 2, planningReadBudget > 0 {
            let preservesThreeSecondFamily = preserveFineFamily && count > 4
            let joint =
                preservesThreeSecondFamily
                ? FocusRackJointPlanner.fineTarget(
                    signedSteps: signedSteps, duration: duration, delay: delay, quiet: quiet,
                    timings: timings, quanta: quanta, readBudget: planningReadBudget)
                : FocusRackJointPlanner.make(
                    signedSteps: signedSteps, duration: duration, delay: delay, quiet: quiet,
                    timings: timings, quanta: quanta, readBudget: planningReadBudget)
            if let joint {
                return .init(
                    signedSteps: signedSteps, chunks: joint.chunks, offsets: joint.offsets,
                    duration: joint.duration, delay: delay,
                    minimumDuration: min(
                        viable.map(\.minimum).min() ?? joint.duration, joint.duration),
                    maximumDuration: max(
                        viable.map(\.maximum).max() ?? joint.duration, joint.duration),
                    estimatedDuration: joint.duration, maintenanceReadOffsets: joint.reads)
            }
            if preservesThreeSecondFamily { throw FocusRackError.noSmoothTiming }
        }
        guard let minimum = viable.map(\.minimum).min(), let maximum = viable.map(\.maximum).max()
        else { throw FocusRackError.noSmoothTiming }
        var executionDuration = duration
        if duration + 1e-9 < minimum {
            guard requireMeasured, let fastest = viable.min(by: { $0.minimum < $1.minimum })
            else { throw FocusRackError.durationTooShort(minimum: minimum) }
            // Duration is an operator target. Retain the fastest measured family and leave
            // dispatch headroom rather than disabling it for a few milliseconds of growth.
            executionDuration = fastest.minimum + 0.002 * Double(fastest.chunks.count - 1)
            if duration < 2, executionDuration >= 2 {
                return try adaptiveTimed(
                    signedSteps: signedSteps, duration: executionDuration, delay: delay,
                    easing: easing, quiet: quiet, timings: timings, quanta: quanta,
                    safetyReadBudget: max(0.1, safetyReadBudget), requireMeasured: requireMeasured,
                    preserveFineFamily: preserveFineFamily)
            }
        }
        guard duration <= maximum + 1e-9 else {
            throw FocusRackError.durationTooLong(maximum: maximum)
        }
        // Ascending quantum selects the finest cadence that actually fits this request.
        guard
            let selected = viable.first(where: {
                executionDuration + 1e-9 >= $0.minimum && executionDuration <= $0.maximum + 1e-9
                    && (executionDuration <= duration
                        || executionDuration + 1e-9 >= $0.minimum + 0.002
                            * Double($0.chunks.count - 1))
            })
        else { throw FocusRackError.noSmoothTiming }
        return .init(
            signedSteps: signedSteps, chunks: selected.chunks,
            offsets: selected.fractions.map {
                delay + $0 * (executionDuration - selected.finalCost)
            },
            duration: executionDuration, delay: delay, minimumDuration: minimum,
            maximumDuration: maximum,
            estimatedDuration: executionDuration)
    }

}
