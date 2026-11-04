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
    let estimatedDuration: Double?
    // Next command index -> earliest read start, in the same fixed epoch as offsets.
    // Untimed runs use periodic refreshes; an explicit schedule owns its reads.
    var maintenanceReadOffsets: [Int: Double]? = nil
}

/// Keeps fine setup units while selecting bounded command sizes for the requested timing.
/// Scheduling estimates cannot establish optical smoothness; rehearse the selected lens and span.
enum FocusRackPlanner {
    // The fine source trial used 94 increments over 24 seconds. This bounds the dense schedule
    // search; it is not a guarantee of optical smoothness on another lens.
    static let maximumFineSpacing = 24.0 / 93.0

    static func make(
        signedSteps: Int, duration: Double, delay: Double,
        quiet: Double, timings: [Int: FocusRackCommandTiming], timed: Bool, grouped: Bool,
        safetyReadBudget: Double = 0
    ) throws -> FocusRackMovementPlan {
        guard signedSteps != 0, signedSteps != .min, abs(signedSteps) <= 10_000,
            duration.isFinite, duration > 0, delay.isFinite, delay >= 0,
            quiet.isFinite, quiet >= 0, safetyReadBudget.isFinite, safetyReadBudget >= 0
        else { throw FocusRackError.invalidConfiguration }
        let sign = signedSteps < 0 ? -1 : 1
        let count = abs(signedSteps)
        if !timed {
            let quantum = grouped ? (count == 100 ? 10 : 12) : 1
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
                duration: estimate ?? 0, delay: delay,
                estimatedDuration: estimate)
        }
        return try measuredTimed(
            signedSteps: signedSteps, duration: duration, delay: delay, quiet: quiet,
            timings: timings, readBudget: max(0.1, safetyReadBudget))
    }

    private static let dispatchHeadroom = 0.002
    private static let freshnessMargin = 0.05

    // Timing is advisory. Only acknowledged command sizes may enter the frozen schedule.
    private static func measuredTimed(
        signedSteps: Int, duration: Double, delay: Double, quiet: Double,
        timings: [Int: FocusRackCommandTiming], readBudget: Double
    ) throws -> FocusRackMovementPlan {
        let count = abs(signedSteps)
        let measured = timings.keys.filter {
            (1...12).contains($0) && $0 <= count && timings[$0]?.count ?? 0 > 0
                && timings[$0]?.longest.isFinite == true && timings[$0]?.longest ?? 0 > 0
        }.sorted()
        guard !measured.isEmpty else { throw FocusRackError.calibrationRequired }
        if let exact = FocusRackJointPlanner.make(
            signedSteps: signedSteps, duration: duration, delay: delay, quiet: quiet,
            timings: timings, quanta: measured, readBudget: readBudget)
        {
            return movementPlan(exact, signedSteps: signedSteps, delay: delay)
        }
        var candidates: [[Int]] = []
        for base in measured {
            let choices = measured.filter { $0 <= base }.sorted(by: >)
            guard
                let chunks = measuredChunks(
                    count: count, choices: choices, timings: timings,
                    quiet: quiet, preferLargest: true)
            else { continue }
            if let exact = pacedSchedule(
                chunks: chunks, duration: duration, delay: delay, quiet: quiet,
                timings: timings, readBudget: readBudget)
            {
                return movementPlan(exact, signedSteps: signedSteps, delay: delay)
            }
            candidates.append(chunks)
        }
        if let fastest = measuredChunks(
            count: count, choices: measured, timings: timings, quiet: quiet, preferLargest: false)
        {
            if let exact = pacedSchedule(
                chunks: fastest, duration: duration, delay: delay, quiet: quiet,
                timings: timings, readBudget: readBudget)
            {
                return movementPlan(exact, signedSteps: signedSteps, delay: delay)
            }
            candidates.append(fastest)
        }
        guard !candidates.isEmpty else { throw FocusRackError.calibrationRequired }
        let schedules = candidates.compactMap {
            serialSchedule(
                chunks: $0, delay: delay, quiet: quiet, timings: timings,
                readBudget: readBudget)
        }
        guard
            let fastest = schedules.min(by: {
                if abs($0.duration - $1.duration) > 1e-9 { return $0.duration < $1.duration }
                return $0.preferred(to: $1)
            })
        else { throw FocusRackError.safetyReadUnavailable }
        return movementPlan(fastest, signedSteps: signedSteps, delay: delay)
    }

    // Exact reachability avoids inventing an unmeasured residual command. The cost path also
    // compares nonmonotonic lenses: the largest command need not have the best cost per unit.
    private static func measuredChunks(
        count: Int, choices: [Int], timings: [Int: FocusRackCommandTiming], quiet: Double,
        preferLargest: Bool
    ) -> [Int]? {
        var costs = Array(repeating: Double.infinity, count: count + 1)
        var previous = Array(repeating: 0, count: count + 1)
        costs[0] = 0
        for span in 1...count {
            for quantum in choices where quantum <= span && costs[span - quantum].isFinite {
                let candidate =
                    costs[span - quantum] + (timings[quantum]?.longest ?? .infinity)
                    + quiet + dispatchHeadroom
                if previous[span] == 0 || (!preferLargest && candidate < costs[span] - 1e-9) {
                    costs[span] = candidate
                    previous[span] = quantum
                }
            }
        }
        guard previous[count] > 0 else { return nil }
        var chunks: [Int] = []
        var remaining = count
        while remaining > 0 {
            let quantum = previous[remaining]
            chunks.append(quantum)
            remaining -= quantum
        }
        return chunks
    }

    private static func pacedSchedule(
        chunks: [Int], duration: Double, delay: Double, quiet: Double,
        timings: [Int: FocusRackCommandTiming], readBudget: Double
    ) -> FocusRackJointPlanner.Schedule? {
        guard chunks.count > 1, let final = chunks.last, let finalCost = timings[final]?.longest,
            duration <= Double(chunks.reduce(0, +)) * maximumFineSpacing + 2
        else { return nil }
        let span = chunks.dropLast().reduce(0, +)
        let minimum =
            chunks.dropLast().map {
                ((timings[$0]?.longest ?? .infinity) + quiet + dispatchHeadroom)
                    * Double(span) / Double($0)
            }.max() ?? 0
        var readCount = 0
        for _ in 0..<4 {
            let ordinary = duration - Double(readCount) * (readBudget + dispatchHeadroom)
            guard ordinary >= minimum + finalCost - 1e-9,
                let plan = serialSchedule(
                    chunks: chunks, delay: delay, quiet: quiet, timings: timings,
                    readBudget: readBudget, ordinaryDuration: ordinary, minimumReads: readCount)
            else { return nil }
            if abs(plan.duration - duration) < 1e-8 { return plan }
            readCount = plan.reads.count
        }
        return nil
    }

    // Dense overruns reserve refreshes only when needed. Every command must finish inside
    // its latest read's evidence lifetime, including after a slow serialized idle refresh.
    private static func serialSchedule(
        chunks: [Int], delay: Double, quiet: Double, timings: [Int: FocusRackCommandTiming],
        readBudget: Double, ordinaryDuration: Double? = nil, minimumReads: Int = 0
    ) -> FocusRackJointPlanner.Schedule? {
        var cursor = 0.0
        var safetyAt = -readBudget
        var offsets: [Double] = []
        var reads: [Int: Double] = [:]
        let span = chunks.dropLast().reduce(0, +)
        let finalCost = timings[chunks.last ?? 0]?.longest ?? 0
        let scale = ordinaryDuration.map { ($0 - finalCost) / Double(span) }
        var position = 0
        var readTime = 0.0
        for index in chunks.indices {
            guard let cost = timings[chunks[index]]?.longest else { return nil }
            if let scale { cursor = max(cursor, Double(position) * scale + readTime) }
            // Keep a refresh inside the previous evidence lifetime whenever the read budget
            // permits it. Slow idle reads may cross expiry; only new evidence admits movement.
            let canRefreshBeforeExpiry =
                2 * readBudget + cost + quiet + dispatchHeadroom
                < 2 - freshnessMargin
            let reserve =
                index + 1 < chunks.count && canRefreshBeforeExpiry
                ? quiet + dispatchHeadroom + readBudget : 0
            let requiredRead = chunks.count - index <= minimumReads - reads.count
            if requiredRead || cursor + cost + reserve >= safetyAt + 2 - freshnessMargin {
                reads[index] = delay + cursor
                safetyAt = cursor
                cursor += readBudget + dispatchHeadroom
                readTime += readBudget + dispatchHeadroom
            }
            guard cursor + cost < safetyAt + 2 - freshnessMargin else { return nil }
            offsets.append(delay + cursor)
            position += chunks[index]
            cursor += cost
            if index + 1 < chunks.count { cursor += quiet + dispatchHeadroom }
        }
        guard cursor.isFinite else { return nil }
        return .init(
            duration: cursor, chunks: chunks, offsets: offsets, reads: reads,
            slack: dispatchHeadroom)
    }

    private static func movementPlan(
        _ schedule: FocusRackJointPlanner.Schedule, signedSteps: Int, delay: Double
    ) -> FocusRackMovementPlan {
        let sign = signedSteps < 0 ? -1 : 1
        return .init(
            signedSteps: signedSteps, chunks: schedule.chunks.map { abs($0) * sign },
            offsets: schedule.offsets, duration: schedule.duration, delay: delay,
            estimatedDuration: schedule.duration,
            maintenanceReadOffsets: schedule.reads.isEmpty ? nil : schedule.reads)
    }
}
