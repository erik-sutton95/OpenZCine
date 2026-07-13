import Testing

@testable import OpenZCineCore

@Test func discoveryFiltersDefaultPrivateIPv4Ranges() throws {
    #expect(CameraDiscovery.isPrivateIPv4("10.0.0.42"))
    #expect(CameraDiscovery.isPrivateIPv4("172.20.10.42"))
    #expect(CameraDiscovery.isPrivateIPv4("192.168.1.42"))

    #expect(!CameraDiscovery.isDefaultScanIPv4("10.0.0.42"))
    #expect(CameraDiscovery.isDefaultScanIPv4("172.20.10.42"))
    #expect(CameraDiscovery.isDefaultScanIPv4("192.168.1.42"))
    #expect(!CameraDiscovery.isPrivateIPv4("169.254.1.2"))
    #expect(!CameraDiscovery.isPrivateIPv4("8.8.8.8"))
}

@Test func discoveryBuildsFastSubnetHosts() throws {
    let hosts = CameraDiscovery.fastHosts(inSubnet: "192.168.7")

    #expect(hosts.prefix(4) == ["192.168.7.1", "192.168.7.2", "192.168.7.3", "192.168.7.4"])
    #expect(hosts.last == "192.168.7.254")
    #expect(hosts.count == 254)
}

@Test func discoveryBuildsAutomaticFallbackHostsAcrossTheSubnet() throws {
    let hosts = CameraDiscovery.automaticFallbackHosts(inSubnet: "192.168.7")

    #expect(
        hosts.prefix(5) == [
            "192.168.7.1", "192.168.7.2", "192.168.7.3", "192.168.7.4", "192.168.7.5",
        ])
    #expect(hosts.contains("192.168.7.163"))
    #expect(hosts.contains("192.168.7.254"))
    #expect(hosts == CameraDiscovery.fastHosts(inSubnet: "192.168.7"))
}

@Test func discoveryBuildsWifiScanHostsForCameraApAndPersonalHotspot() throws {
    let hosts = CameraDiscovery.automaticScanHosts(localAddresses: ["172.20.10.1"])

    #expect(hosts.first == "192.168.1.1")
    #expect(hosts.contains("172.20.10.15"))
    #expect(!hosts.contains("172.20.10.1"))
    #expect(Set(hosts).count == hosts.count)
}

@Test func discoveryDoesNotDuplicateCameraApHostWhenPhoneIsOnCameraSubnet() throws {
    let hosts = CameraDiscovery.automaticScanHosts(localAddresses: ["192.168.1.23"])

    #expect(hosts.filter { $0 == "192.168.1.1" }.count == 1)
    #expect(!hosts.contains("192.168.1.23"))
}

@Test func discoveryScansOnlySupportedLocalInterfaces() throws {
    #expect(CameraDiscovery.isSupportedScanInterface(name: "en0", address: "172.20.10.42"))
    #expect(CameraDiscovery.isSupportedScanInterface(name: "en1", address: "192.168.7.42"))
    #expect(CameraDiscovery.isSupportedScanInterface(name: "bridge100", address: "172.20.10.42"))

    #expect(!CameraDiscovery.isSupportedScanInterface(name: "en0", address: "10.0.0.42"))
}

@Test func discoveryDedupeSortsAndFiltersBonjourResults() throws {
    let cameras = CameraDiscovery.dedupeAndSort(
        [
            DiscoveredCamera(ip: "192.168.7.40", name: "late", source: .bonjour),
            DiscoveredCamera(ip: "192.168.7.2", name: "ZR", source: .bonjour),
            DiscoveredCamera(ip: "8.8.8.8", name: "public", source: .bonjour),
            DiscoveredCamera(ip: "192.168.7.2", name: "duplicate", source: .subnetProbe),
        ],
        includeTenDotSubnets: false
    )

    #expect(
        cameras == [
            DiscoveredCamera(ip: "192.168.7.2", name: "ZR", source: .bonjour),
            DiscoveredCamera(ip: "192.168.7.40", name: "late", source: .bonjour),
        ])
}

@Test func prioritizedScanHostsPutSavedAndAccessPointFirstWithoutDuplicates() {
    let split = CameraDiscovery.prioritizedScanHosts(
        priorityHosts: ["192.168.7.23", "192.168.1.1", " 192.168.7.23 "],
        localAddresses: ["192.168.7.10"]
    )
    // AP host leads, saved host follows once (normalized + deduped).
    #expect(split.priority == ["192.168.1.1", "192.168.7.23"])
    // The remaining sweep never repeats a priority host and keeps subnet order.
    #expect(!split.remaining.contains("192.168.1.1"))
    #expect(!split.remaining.contains("192.168.7.23"))
    #expect(split.remaining.contains("192.168.7.2"))
    #expect(!split.remaining.contains("192.168.7.10"))  // the phone itself
    #expect(
        Set(split.priority + split.remaining).count == split.priority.count + split.remaining.count
    )
}

@Test func prioritizedScanHostsNeverPrioritizeThePhoneItself() {
    let split = CameraDiscovery.prioritizedScanHosts(
        priorityHosts: ["192.168.7.10"],
        localAddresses: ["192.168.7.10"]
    )
    #expect(split.priority == ["192.168.1.1"])
}

@Test func automaticDiscoveryBacksOffToProtectSleepingCameras() {
    #expect(CameraDiscovery.automaticScanRetryInterval(emptyStreak: 1, foundCamera: false) == 0.85)
    #expect(CameraDiscovery.automaticScanRetryInterval(emptyStreak: 2, foundCamera: false) == 2)
    #expect(CameraDiscovery.automaticScanRetryInterval(emptyStreak: 3, foundCamera: false) == 5)
    #expect(CameraDiscovery.automaticScanRetryInterval(emptyStreak: 4, foundCamera: false) == 12)
    #expect(CameraDiscovery.automaticScanRetryInterval(emptyStreak: 5, foundCamera: false) == 30)
    #expect(CameraDiscovery.automaticScanRetryInterval(emptyStreak: 0, foundCamera: true) == 30)
}
