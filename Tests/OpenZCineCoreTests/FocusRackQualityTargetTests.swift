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
func rackThreeSecondTargetUsesTheFinestMeasuredFamilyThatFits(steps: Int) throws {
    let plan = try qualityTargetPlan(steps, duration: 3)
    let reads = try #require(plan.maintenanceReadOffsets)
    #expect(plan.chunks.reduce(0, +) == steps)
    #expect(plan.duration >= 3)
    #expect(plan.duration == 3)
    #expect(plan.estimatedDuration == plan.duration)
    for index in plan.chunks.indices.dropLast() {
        let quantum = abs(plan.chunks[index])
        #expect(quantum <= 8)
        if reads[index + 1] == nil { #expect(quantum <= 6) }
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

private func genericPlan(
    _ steps: Int, duration: Double = 3, costs: [Int: Double], readBudget: Double = 0.1
) throws -> FocusRackMovementPlan {
    let timings = costs.mapValues { seconds in
        var timing = FocusRackCommandTiming()
        timing.record(seconds)
        return timing
    }
    return try FocusRackPlanner.make(
        signedSteps: steps, duration: duration, delay: 0, easing: .linear, quiet: 0,
        timings: timings, adaptive: true, timed: true, grouped: true,
        profile: .calibratedFineExperiment, safetyReadBudget: readBudget)
}

private func expectFrozenSafety(
    _ plan: FocusRackMovementPlan, costs: [Int: Double], readBudget: Double = 0.1
) throws {
    var safetyAt = plan.delay - readBudget
    let reads = plan.maintenanceReadOffsets ?? [:]
    for index in plan.chunks.indices {
        let due = plan.offsets[index]
        let cost = try #require(costs[abs(plan.chunks[index])])
        if let read = reads[index] {
            if index > 0 {
                let previousCost = try #require(costs[abs(plan.chunks[index - 1])])
                #expect(read >= plan.offsets[index - 1] + previousCost - 1e-9)
            }
            #expect(read + readBudget < safetyAt + 2)
            #expect(read + readBudget + 0.002 <= due + 1e-9)
            safetyAt = read
        }
        #expect(due + cost < safetyAt + 2)
        if index + 1 < plan.chunks.count {
            #expect(due + cost + 0.002 <= plan.offsets[index + 1] + 1e-9)
        } else {
            #expect(abs(due + cost - plan.delay - plan.duration) < 1e-9)
        }
    }
}

@Test(arguments: [150, -150])
func rackFreshLensOnlySixteenPulseEvidenceDoesNotReserveAReadInEveryGap(steps: Int) throws {
    let costs = [1: 0.08580086300025869]
    let plan = try genericPlan(steps, costs: costs)
    #expect(plan.chunks.count == 150)
    #expect(plan.chunks.reduce(0, +) == steps)
    #expect(plan.duration > 13)
    #expect(plan.duration < 15)
    #expect((plan.maintenanceReadOffsets?.count ?? 0) < 10)
    try expectFrozenSafety(plan, costs: costs)
}

@Test(arguments: [150, -150])
func rackNewMeasuredSizesEnableTheRequestedDurationForAnotherLens(steps: Int) throws {
    let costs = [1: 0.08580086300025869, 2: 0.08, 4: 0.07, 8: 0.08]
    let plan = try genericPlan(steps, costs: costs)
    #expect(plan.duration == 3)
    #expect(plan.chunks.reduce(0, +) == steps)
    #expect(plan.chunks.count < 60)
    #expect(plan.chunks.allSatisfy { costs[abs($0)] != nil })
    try expectFrozenSafety(plan, costs: costs)
}

@Test func rackFastestOverrunUsesMeasuredCostPerUnitRatherThanLargestCommand() throws {
    let costs = [1: 0.01, 8: 0.2]
    let plan = try genericPlan(150, duration: 0.1, costs: costs)
    #expect(plan.chunks.allSatisfy { $0 == 1 })
    #expect(plan.duration < 2)
    try expectFrozenSafety(plan, costs: costs)
}

@Test func rackMeasuredResidualsAndSafeMaximumSizeAreAvailableAtEveryTarget() throws {
    let costs = [2: 0.06, 12: 0.08]
    let plan = try genericPlan(106, duration: 0.01, costs: costs)
    #expect(plan.chunks.reduce(0, +) == 106)
    #expect(plan.chunks.contains(12))
    #expect(plan.chunks.allSatisfy { costs[$0] != nil })
    try expectFrozenSafety(plan, costs: costs)
    #expect(throws: FocusRackError.calibrationRequired) {
        try genericPlan(107, costs: costs)
    }
}

@Test func rackExactThreeSecondsHasNoSpecialFamilyOrOverrunPolicy() throws {
    let costs = [1: 0.08580086300025869]
    let plans = try [2.99, 3.0, 3.01].map { try genericPlan(150, duration: $0, costs: costs) }
    #expect(plans.allSatisfy { $0.chunks == plans[0].chunks })
    #expect(plans.allSatisfy { abs($0.duration - plans[0].duration) < 1e-9 })
    #expect(plans.allSatisfy { $0.maintenanceReadOffsets == plans[0].maintenanceReadOffsets })
}

@Test func rackShortTargetOverrunAcrossTwoSecondsStillPlansSafetyRefreshes() throws {
    let costs = [1: 0.08580086300025869]
    let plan = try genericPlan(150, duration: 1, costs: costs)
    #expect(plan.duration > 2)
    #expect(plan.maintenanceReadOffsets?.isEmpty == false)
    try expectFrozenSafety(plan, costs: costs)
}

@Test func rackSingleMeasuredCommandKeepsDurationAdvisory() throws {
    let costs = [1: 0.08580086300025869]
    let plan = try genericPlan(-1, costs: costs)
    #expect(plan.chunks == [-1])
    #expect(plan.duration == costs[1])
    try expectFrozenSafety(plan, costs: costs)
}

@Test func rackLargeSpanGenericPlanningIsBounded() throws {
    let started = ContinuousClock.now
    let plan = try qualityTargetPlan(10_000, duration: 3)
    #expect(plan.chunks.reduce(0, +) == 10_000)
    #expect(plan.chunks.allSatisfy { observedPhoneCosts[abs($0)] != nil })
    try expectFrozenSafety(plan, costs: observedPhoneCosts)
    let slow = try genericPlan(10_000, costs: [4: 0.3])
    #expect(slow.chunks.count == 2_500)
    try expectFrozenSafety(slow, costs: [4: 0.3])
    #expect(started.duration(to: .now) < .seconds(10))
}

@Test func rackPacedReadReservationDoesNotOscillateNearTheEvidenceBoundary() throws {
    let costs = [8: 0.05]
    let plan = try genericPlan(96, duration: 1.94, costs: costs)
    #expect(abs(plan.duration - 1.94) < 1e-9)
    #expect(plan.chunks == Array(repeating: 8, count: 12))
    #expect(plan.maintenanceReadOffsets?.count == 1)
    try expectFrozenSafety(plan, costs: costs)
}

@Test func rackGenericPlanningRejectsUnmeasuredOrOutOfRangeTimingEvidence() throws {
    var valid = FocusRackCommandTiming()
    valid.record(0.05)
    var invalid = valid
    invalid.longest = .nan
    var unmeasured = valid
    unmeasured.count = 0
    let plan = try FocusRackPlanner.make(
        signedSteps: 70, duration: 3, delay: 0, easing: .linear, quiet: 0,
        timings: [0: valid, 1: invalid, 2: valid, 4: unmeasured, 13: valid], adaptive: true,
        timed: true, grouped: true, profile: .calibratedFineExperiment, safetyReadBudget: 0.1)
    #expect(plan.chunks == Array(repeating: 2, count: 35))
    #expect(throws: FocusRackError.calibrationRequired) {
        try FocusRackPlanner.make(
            signedSteps: 70, duration: 3, delay: 0, easing: .linear, quiet: 0,
            timings: [0: valid, 1: invalid, 4: unmeasured, 13: valid], adaptive: true,
            timed: true, grouped: true, profile: .calibratedFineExperiment, safetyReadBudget: 0.1)
    }
}
