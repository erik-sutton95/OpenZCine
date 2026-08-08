import Foundation
import Testing

@testable import OpenZCineCore

// MARK: - Patient schedule

@Test func directedProbeScheduleIsPatientForPowerSave() {
    let schedule = InfrastructureDiscovery.patientProbeSchedule()
    #expect(schedule.attempts == 3)
    #expect(schedule.timeoutMilliseconds == 2_000)
    // Blind sweep stays at the measured 1.5 s single-shot budget.
    #expect(InfrastructureDiscovery.blindSweepTimeoutMilliseconds == 1_500)
    #expect(InfrastructureDiscovery.localSweepPasses == 2)
}

@Test func patientProbeScheduleNeverReturnsZeroAttempts() {
    let schedule = InfrastructureDiscovery.patientProbeSchedule(
        attempts: 0, timeoutMilliseconds: 500)
    #expect(schedule.attempts == 1)
    #expect(schedule.timeoutMilliseconds == 500)
}

// MARK: - Directed hosts (current subnet only)

@Test func directedHostsStayOnLocalSubnetsAndDropSiblings() {
    let directed = InfrastructureDiscovery.directedHosts(
        candidates: [
            "192.168.1.246",  // home — keep
            "192.168.129.246",  // portable sibling — drop
            "usb:0000dead",  // not an address — drop
            "192.168.1.246",  // dupe
            "10.0.0.5",  // other local subnet if listed
        ],
        localSubnets: ["192.168.1", "10.0.0"],
        excluded: ["10.0.0.5"]
    )
    #expect(directed == ["192.168.1.246"])
}

@Test func directedHostsEmptyWhenNoOverlapWithLocalSubnets() {
    let directed = InfrastructureDiscovery.directedHosts(
        candidates: ["192.168.129.246"],
        localSubnets: ["192.168.1"]
    )
    #expect(directed.isEmpty)
}

// MARK: - Tally

@Test func sweepTallyCountsOpenRefusedTimeoutAndOccupied() {
    let tally = InfrastructureSweepTally.from(verdicts: [
        "192.168.1.1": .refused,
        "192.168.1.10": .timeout,
        "192.168.1.20": .timeout,
        "192.168.1.246": .open,
        "192.168.1.50": .noRoute,
        "192.168.1.60": .denied,
    ])
    #expect(tally.hostsProbed == 6)
    #expect(tally.openCount == 1)
    #expect(tally.refusedCount == 1)
    #expect(tally.timeoutCount == 2)
    #expect(tally.noRouteCount == 1)
    #expect(tally.deniedCount == 1)
    #expect(tally.openHosts == ["192.168.1.246"])
    #expect(tally.occupiedHosts.contains("192.168.1.1"))
    #expect(tally.occupiedHosts.contains("192.168.1.246"))
    #expect(tally.occupiedCount == 2)
}

// MARK: - classifyMiss

private let readyPreflight = InfrastructurePreflight.ready(interfaces: [
    LocalIPv4Interface(name: "en0", address: "192.168.1.146", netmask: "255.255.255.0")
])

@Test func classifyMissPrefersPreflightAndCameraAP() {
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: .localNetworkDenied,
            onCameraAccessPoint: false,
            tally: nil
        ) == .localNetworkDenied)
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: .noScannableInterface,
            onCameraAccessPoint: false,
            tally: nil
        ) == .noScannableInterface)
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: readyPreflight,
            onCameraAccessPoint: true,
            tally: nil
        ) == .onCameraAccessPoint)
}

@Test func classifyMissHostsVisibleButNoPTP() {
    let tally = InfrastructureSweepTally(
        openCount: 0,
        occupiedCount: 14,
        timeoutCount: 200,
        refusedCount: 14,
        hostsProbed: 253,
        occupiedHosts: ["192.168.1.1", "192.168.1.10"],
        openHosts: []
    )
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: readyPreflight,
            onCameraAccessPoint: false,
            tally: tally
        ) == .hostsVisibleNoPTP)
}

@Test func classifyMissNetworkUnreachableWhenNothingOccupied() {
    let tally = InfrastructureSweepTally(
        openCount: 0,
        occupiedCount: 0,
        timeoutCount: 250,
        hostsProbed: 253
    )
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: readyPreflight,
            onCameraAccessPoint: false,
            tally: tally
        ) == .networkUnreachable)
}

@Test func classifyMissDeniedWithNoOccupancyIsLocalNetwork() {
    let tally = InfrastructureSweepTally(
        openCount: 0,
        occupiedCount: 0,
        timeoutCount: 240,
        deniedCount: 10,
        hostsProbed: 253
    )
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: readyPreflight,
            onCameraAccessPoint: false,
            tally: tally
        ) == .localNetworkDenied)
}

@Test func classifyMissHeldByOtherDevice() {
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: readyPreflight,
            onCameraAccessPoint: false,
            tally: nil,
            heldHolderName: "Erik's iPad"
        ) == .heldByOtherDevice(holder: "Erik's iPad"))
}

@Test func classifyMissFallsBackToCameraNotFound() {
    let tally = InfrastructureSweepTally(
        openCount: 1,
        occupiedCount: 1,
        hostsProbed: 10,
        openHosts: ["192.168.1.9"]
    )
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: readyPreflight,
            onCameraAccessPoint: false,
            tally: tally
        ) == .cameraNotFound)
}

// MARK: - Operator copy

@Test func operatorCopyNamesTheOneThingToDo() {
    let isolation = InfrastructureDiscovery.operatorCopy(for: .hostsVisibleNoPTP)
    #expect(isolation.contains("Connect to computer"))

    let denied = InfrastructureDiscovery.operatorCopy(for: .localNetworkDenied)
    #expect(denied.contains("Local Network"))

    let onAP = InfrastructureDiscovery.operatorCopy(
        for: .onCameraAccessPoint, cameraName: "ZR_6001234")
    #expect(onAP.contains("ZR_6001234"))
    #expect(onAP.contains("own Wi"))
}

/// The popup is read by somebody holding a camera, not by somebody reading a packet capture.
/// Dotted subnets, arrow-chained menu paths and port numbers all shipped here once.
@Test func operatorCopyStaysShortAndUntechnical() {
    for reason: InfrastructureMissReason in [
        .localNetworkDenied, .noScannableInterface, .onCameraAccessPoint,
        .networkUnreachable, .hostsVisibleNoPTP, .cameraNotFound,
        .heldByOtherDevice(holder: "Erik's iPad"),
    ] {
        let copy = InfrastructureDiscovery.operatorCopy(for: reason, cameraName: "ZR_6001234")
        #expect(copy.count <= 130, "too long for a popup: \(copy)")
        #expect(!copy.contains("→"), "menu arrows are jargon: \(copy)")
        #expect(!copy.contains("15740"), "port numbers are jargon: \(copy)")
        #expect(!copy.contains(".x"), "dotted subnets are jargon: \(copy)")
    }
}

// MARK: - Typed verdicts

/// Verdicts travelled as strings between the transport, two sweeps and this tally, and had already
/// drifted: a `"reset"` nobody emitted was counted as occupancy, while running out of file
/// descriptors counted as `other` — evidence about this phone, read as evidence about the network.
@Test func onlyAnAnswerProvesSomebodyHoldsTheAddress() {
    for verdict in HostProbeVerdict.allCases {
        let tally = InfrastructureSweepTally.from(verdicts: ["10.0.0.2": verdict])
        #expect(tally.hostsProbed == 1)
        #expect(tally.occupiedCount == (verdict.isOccupied ? 1 : 0), "\(verdict)")
        #expect(tally.openCount == (verdict == .open ? 1 : 0), "\(verdict)")
    }
    #expect(HostProbeVerdict.refused.isOccupied)
    // A dial the OS refused us, and a dial that ran this device out of descriptors, say nothing
    // whatever about the host. Neither may count as reaching it.
    #expect(!HostProbeVerdict.denied.isOccupied)
    #expect(!HostProbeVerdict.unreachableOther.isOccupied)
    #expect(!HostProbeVerdict.unreachableOther.isSilence)
}

/// The verdict the app owed an operator on a 6 GHz/MLO network: the phone and the camera held
/// addresses on one subnet from one DHCP server, and no packet passed between them. Every host
/// went silent, and the app said "still searching" for days.
@Test func aSilentSubnetIsReportedAsUnreachableNotAsCameraNotFound() {
    let silent = InfrastructureSweepTally.from(
        verdicts: Dictionary(
            uniqueKeysWithValues: (2...200).map { ("192.168.1.\($0)", HostProbeVerdict.timeout) }))
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: .ready(interfaces: []), onCameraAccessPoint: false, tally: silent)
            == .networkUnreachable)

    // The same subnet with the router answering is a LIVE network holding no camera — a
    // different sentence, and a different thing to go and do.
    var live = silent
    live.refusedCount = 1
    live.occupiedCount = 1
    live.occupiedHosts = ["192.168.1.1"]
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: .ready(interfaces: []), onCameraAccessPoint: false, tally: live)
            == .hostsVisibleNoPTP)

    // No sweep at all must never be dressed up as one. This is what a hand-built tally with
    // `hostsProbed` taken from the occupied count did, and it made `networkUnreachable`
    // unreachable — the one diagnosis that fitted.
    #expect(
        InfrastructureDiscovery.classifyMiss(
            preflight: .ready(interfaces: []), onCameraAccessPoint: false, tally: nil)
            == .cameraNotFound)
}

/// A body that wakes on the second pass must not be forgotten because the first pass missed it.
@Test func passesUnionRatherThanOverwriteEachOther() {
    let first = InfrastructureSweepTally.from(verdicts: [
        "10.0.0.2": .timeout, "10.0.0.3": .refused,
    ])
    let second = InfrastructureSweepTally.from(verdicts: ["10.0.0.2": .open, "10.0.0.3": .refused])
    let merged = first.merging(second)

    #expect(merged.hostsProbed == 2)
    #expect(merged.openHosts == ["10.0.0.2"])
    #expect(merged.occupiedHosts == ["10.0.0.2", "10.0.0.3"])
}
