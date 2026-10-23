import Testing

@testable import OpenZCineCore

private let observedPhoneCosts: [Int: Double] = [
    1: 0.21372308325953782, 2: 0.12446125014685094, 3: 0.11696191667579114,
    4: 0.12687424989417195, 6: 0.08870562491938472, 8: 0.10687066667014733,
    10: 0.09154454153031111,
]

private func qualityTargetPlan(_ steps: Int, duration: Double) throws -> FocusRackMovementPlan {
    let timings = observedPhoneCosts.mapValues { seconds in
        var timing = FocusRackCommandTiming()
        timing.record(seconds)
        return timing
    }
    return try FocusRackPlanner.make(
        signedSteps: steps, duration: duration, delay: 0, easing: .linear, quiet: 0,
        timings: timings, adaptive: true, timed: true, grouped: true,
        profile: .calibratedFineExperiment, safetyReadBudget: 0.1)
}

@Test(arguments: [110, -110])
func rackSmallEstimatedOverrunRemainsRunnable(steps: Int) throws {
    let plan = try qualityTargetPlan(steps, duration: 1)
    #expect(plan.chunks.reduce(0, +) == steps)
    #expect(plan.chunks.map(abs) == Array(repeating: 10, count: 11))
    #expect(plan.duration >= 1.0069899568334222)
    #expect(plan.duration < 1.05)
    #expect(plan.estimatedDuration == plan.duration)
}

@Test(arguments: [100, -100, 110, -110])
func rackThreeSecondTargetPreservesFineMovesWhenPhoneCostsGrow(steps: Int) throws {
    let plan = try qualityTargetPlan(steps, duration: 3)
    let reads = try #require(plan.maintenanceReadOffsets)
    #expect(plan.chunks.reduce(0, +) == steps)
    #expect(plan.duration >= 3)
    #expect(plan.duration < 4)
    #expect(plan.estimatedDuration == plan.duration)
    for index in plan.chunks.indices.dropLast() {
        let quantum = abs(plan.chunks[index])
        #expect(quantum <= 8)
        if reads[index + 1] == nil { #expect(quantum <= 4) }
        let due = plan.offsets[index]
        let finish = due + (observedPhoneCosts[quantum] ?? .infinity)
        let next = plan.offsets[index + 1]
        #expect(finish + 0.002 <= next + 1e-9)
        if let read = reads[index + 1] {
            #expect(read >= finish - 1e-9)
            #expect(read + 0.1 + 0.002 <= next + 1e-9)
        }
    }
}

@Test func rackShortTargetReservesHeadroomForItsSelectedFamily() throws {
    let costs = [4: 0.070, 8: 0.079, 10: 0.101]
    let timings = costs.mapValues { seconds in
        var timing = FocusRackCommandTiming()
        timing.record(seconds)
        return timing
    }
    let plan = try FocusRackPlanner.make(
        signedSteps: 100, duration: 1, delay: 0, easing: .linear, quiet: 0,
        timings: timings, adaptive: true, timed: true, grouped: true,
        profile: .calibratedFineExperiment, safetyReadBudget: 0.1)
    for index in plan.chunks.indices.dropLast() {
        let cost = try #require(costs[abs(plan.chunks[index])])
        #expect(plan.offsets[index + 1] - plan.offsets[index] >= cost + 0.002 - 1e-9)
    }
}

@Test func rackThreeSecondLargeSpanSearchIsBoundedForFeasibleAndImpossibleCosts() throws {
    let started = ContinuousClock.now
    let plan = try qualityTargetPlan(10_000, duration: 3)
    #expect(plan.chunks.reduce(0, +) == 10_000)
    #expect(plan.chunks.map(abs).max() ?? 0 <= 8)
    var impossible = FocusRackCommandTiming()
    impossible.record(0.3)
    #expect(
        FocusRackJointPlanner.fineTarget(
            signedSteps: 10_000, duration: 3, delay: 0, quiet: 0,
            timings: [4: impossible], quanta: [4], readBudget: 0.1) == nil)
    // Loose bound for parallel debug CI. The old exhaustive boundary scan multiplied
    // every possible position by every read and final before trying any schedule.
    #expect(started.duration(to: .now) < .seconds(10))
}
