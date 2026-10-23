import Foundation

/// Searches measured moves and read windows together, without moving command deadlines.
enum FocusRackJointPlanner {
    // Exclude sub-2ms slack that fails under observed host wake latency; runtime guards stay strict.
    private static let minimumDispatchHeadroom = 0.002

    struct Schedule {
        let duration: Double
        let chunks: [Int]
        let offsets: [Double]
        let reads: [Int: Double]
        let slack: Double
        var finest: Int { chunks.dropLast().map(abs).min() ?? abs(chunks[0]) }
        var largest: Int { chunks.map(abs).max() ?? 0 }
        var penalty: Int { chunks.reduce(0) { $0 + $1 * $1 } }

        func preferred(to other: Self) -> Bool {
            if finest != other.finest { return finest < other.finest }
            if largest != other.largest { return largest < other.largest }
            if abs(slack - other.slack) > 1e-9 { return slack > other.slack }
            return penalty < other.penalty
        }
    }

    private struct Node {
        let previous: Int
        let readCount: Int
        let quantum: Int
        let read: Double?
        let penalty: Int
        let slack: Double

        func preferred(to other: Self) -> Bool {
            slack > other.slack + 1e-9
                || (abs(slack - other.slack) <= 1e-9 && penalty < other.penalty)
        }
    }

    static func make(
        signedSteps: Int, duration: Double, delay: Double, quiet: Double,
        timings: [Int: FocusRackCommandTiming], quanta: [Int], readBudget: Double,
        ordinaryQuantum: Int? = nil
    ) -> Schedule? {
        guard signedSteps != .min, (2...10_000).contains(abs(signedSteps)),
            duration.isFinite, duration >= 2, delay.isFinite, delay >= 0,
            quiet.isFinite, quiet >= 0, readBudget.isFinite, readBudget > 0,
            readBudget < FocusRackPlanner.maximumFineSpacing,
            duration <= Double(abs(signedSteps)) * FocusRackPlanner.maximumFineSpacing + 2
        else { return nil }
        let count = abs(signedSteps)
        let measured = Set(quanta).filter {
            $0 > 0 && $0 < count && timings[$0]?.count ?? 0 > 0
                && timings[$0]?.longest.isFinite == true && timings[$0]?.longest ?? 0 >= 0
        }.sorted()
        var best: Schedule?
        for base in measured where ordinaryQuantum == nil || ordinaryQuantum == base {
            for final in measured {
                let search = Search(
                    count: count, base: base, final: final, duration: duration, quiet: quiet,
                    costs: timings.mapValues(\.longest), quanta: measured.filter { $0 >= base },
                    readBudget: readBudget)
                guard search.ordinaryFits(base),
                    let plan = search.solve(
                        sign: signedSteps < 0 ? -1 : 1, delay: delay),
                    plan.slack >= minimumDispatchHeadroom
                else { continue }
                if best.map({ plan.preferred(to: $0) }) ?? true { best = plan }
            }
            if let best, best.finest <= base { break }
        }
        return best
    }

    // Preserve the optically accepted 64-pulse ordinary family for the 3s target. Timing
    // growth can lengthen its fixed schedule, but cannot substitute 96-pulse ordinary moves.
    static func fineTarget(
        signedSteps: Int, duration: Double, delay: Double, quiet: Double,
        timings: [Int: FocusRackCommandTiming], quanta: [Int], readBudget: Double
    ) -> Schedule? {
        let measured = quanta.filter {
            $0 <= 8 && timings[$0]?.count ?? 0 > 0
                && timings[$0]?.longest.isFinite == true && timings[$0]?.longest ?? -1 >= 0
        }
        guard let base = measured.filter({ $0 <= 4 }).max(), abs(signedSteps) > base,
            readBudget > 0, readBudget < FocusRackPlanner.maximumFineSpacing
        else { return nil }
        if let exact = make(
            signedSteps: signedSteps, duration: duration, delay: delay, quiet: quiet,
            timings: timings, quanta: measured, readBudget: readBudget, ordinaryQuantum: base)
        {
            return exact
        }
        let costs = timings.mapValues(\.longest)
        let candidates = measured.filter { $0 < abs(signedSteps) }.reduce(into: Set<Double>()) {
            result, final in
            let search = Search(
                count: abs(signedSteps), base: base, final: final, duration: duration,
                quiet: quiet, costs: costs, quanta: measured, readBudget: readBudget)
            result.formUnion(search.targetDurations())
        }
        for candidate in candidates.sorted() where candidate >= duration {
            if let plan = make(
                signedSteps: signedSteps, duration: candidate, delay: delay, quiet: quiet,
                timings: timings, quanta: measured, readBudget: readBudget,
                ordinaryQuantum: base)
            {
                return plan
            }
        }
        return nil
    }

    private struct Search {
        let count: Int
        let base: Int
        let final: Int
        let duration: Double
        let quiet: Double
        let costs: [Int: Double]
        let quanta: [Int]
        let readBudget: Double
        var span: Int { count - final }
        var scale: Double { (duration - (costs[final] ?? duration)) / Double(span) }
        var cap: Double { FocusRackPlanner.maximumFineSpacing }
        // Reads start within [target-cap, target]. Even the next read's worst finish
        // precedes the previous read START + 2s. This also leaves a preflight-age reserve.
        var period: Double { 2 - cap - readBudget - 1e-6 }
        var requiredReads: Int { max(1, Int(ceil((duration + cap - 2 + 1e-6) / period))) }

        func targetDurations() -> Set<Double> {
            let finalCost = costs[final] ?? 0
            let headroom = minimumDispatchHeadroom + 1e-8
            let baseScale = ((costs[base] ?? 0) + quiet + headroom) / Double(base)
            let lower = max(baseScale, (duration - finalCost) / Double(span))
            let upper = min(
                cap / Double(base), (Double(count) * cap + 2 - finalCost) / Double(span))
            guard lower <= upper else { return [] }
            var candidates: Set<Double> = [
                Double(span) * lower + finalCost, Double(span) * upper + finalCost,
            ]
            for quantum in quanta where quantum >= base {
                let scale = max(
                    lower, ((costs[quantum] ?? 0) + quiet + readBudget + headroom) / Double(quantum)
                )
                let bridgeUpper = min(upper, cap / Double(quantum))
                if scale <= bridgeUpper {
                    candidates.insert(Double(span) * scale + finalCost)
                    candidates.insert(Double(span) * bridgeUpper + finalCost)
                }
            }
            candidates.formUnion(
                readBoundaryDurations(lower: lower, upper: upper, headroom: headroom))
            return candidates
        }

        private func readBoundaryDurations(lower: Double, upper: Double, headroom: Double) -> Set<
            Double
        > {
            let finalCost = costs[final] ?? 0
            var boundaries: Set<Double> = []
            let readCount = max(
                1, Int(ceil((Double(span) * upper + finalCost + cap - 2 + 1e-6) / period)))
            // Keep eight nearby read boundaries per final, rather than enumerating every
            // position/read pair. Full schedule validation still decides each candidate.
            for read in 1...readCount {
                let numerator = Double(read) * period - cap + readBudget + headroom
                let nearest = min(span, Int(floor(numerator / lower)))
                guard nearest >= 1 else { continue }
                for position in max(1, nearest - 8)...nearest {
                    let scale = numerator / Double(position)
                    if scale >= lower && scale <= upper {
                        boundaries.insert(Double(span) * scale + finalCost)
                    }
                }
            }
            return Set(boundaries.sorted().prefix(8))
        }

        func ordinaryFits(_ quantum: Int) -> Bool {
            guard let cost = costs[quantum], scale > 0 else { return false }
            let gap = Double(quantum) * scale
            return cost + quiet <= gap + 1e-9 && gap <= cap + 1e-9
        }

        func solve(sign: Int, delay: Double) -> Schedule? {
            guard span > 0, scale > 0 else { return nil }
            var paths = Array(repeating: [Int: Node](), count: span + 1)
            paths[0][0] = .init(
                previous: 0, readCount: 0, quantum: 0, read: nil, penalty: 0, slack: .infinity)
            for position in 0..<span {
                for (used, node) in paths[position].sorted(by: { $0.key < $1.key }) {
                    for quantum in quanta where position + quantum <= span && ordinaryFits(quantum)
                    {
                        extend(
                            position: position, used: used, node: node, quantum: quantum,
                            paths: &paths)
                    }
                }
            }
            guard paths[span][requiredReads] != nil else { return nil }
            return reconstruct(paths, sign: sign, delay: delay)
        }

        private func extend(
            position: Int, used: Int, node: Node, quantum: Int,
            paths: inout [[Int: Node]]
        ) {
            let next = position + quantum
            let start = Double(position) * scale
            let end = Double(next) * scale
            let settled = start + (costs[quantum] ?? duration) + quiet
            let target = Double(used + 1) * period
            // Larger commands are bridges for reads, rather than filling ordinary fine gaps.
            if quantum == base && (used == requiredReads || end <= target + 1e-9) {
                store(
                    next: next, used: used, node: node, position: position, quantum: quantum,
                    read: nil, slack: end - settled, paths: &paths)
            }
            guard used < requiredReads else { return }
            let read = max(settled, target - cap)
            guard read <= target + 1e-9, read + readBudget <= end + 1e-9 else { return }
            store(
                next: next, used: used + 1, node: node, position: position, quantum: quantum,
                read: read, slack: end - read - readBudget, paths: &paths)
        }

        private func store(
            next: Int, used: Int, node: Node, position: Int, quantum: Int,
            read: Double?, slack: Double, paths: inout [[Int: Node]]
        ) {
            let candidate = Node(
                previous: position, readCount: used - (read == nil ? 0 : 1), quantum: quantum,
                read: read, penalty: node.penalty + quantum * quantum,
                slack: min(node.slack, slack))
            if paths[next][used].map({ candidate.preferred(to: $0) }) ?? true {
                paths[next][used] = candidate
            }
        }

        private func reconstruct(_ paths: [[Int: Node]], sign: Int, delay: Double) -> Schedule? {
            var position = span
            var used = requiredReads
            var reversed: [Node] = []
            while position > 0 {
                guard let node = paths[position][used] else { return nil }
                reversed.append(node)
                position = node.previous
                used = node.readCount
            }
            let nodes = reversed.reversed()
            var chunks: [Int] = []
            var offsets: [Double] = []
            var reads: [Int: Double] = [:]
            for node in nodes {
                offsets.append(delay + Double(node.previous) * scale)
                chunks.append(sign * node.quantum)
                if let read = node.read { reads[chunks.count] = delay + read }
            }
            offsets.append(delay + Double(span) * scale)
            chunks.append(sign * final)
            return .init(
                duration: duration, chunks: chunks, offsets: offsets, reads: reads,
                slack: paths[span][requiredReads]?.slack ?? 0)
        }
    }
}
