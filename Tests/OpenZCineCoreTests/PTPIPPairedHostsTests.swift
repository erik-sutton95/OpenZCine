import Testing

@testable import OpenZCineCore

@Test func pairedHostsNormalizeAndRejectEmptyHosts() {
    #expect(PTPIPPairedHosts.normalizedHost("  172.20.10.15  ") == "172.20.10.15")
    #expect(PTPIPPairedHosts.normalizedHost(" ZR-CAMERA.LOCAL ") == "zr-camera.local")
    #expect(PTPIPPairedHosts.normalizedHost("   ") == nil)
}

@Test func pairedHostsAddDeduplicateAndPreserveOrder() {
    let hosts = PTPIPPairedHosts.adding(
        "172.20.10.15",
        to: [" 192.168.1.1 ", "172.20.10.15", "192.168.1.1"]
    )

    #expect(hosts == ["192.168.1.1", "172.20.10.15"])
}

@Test func pairedHostsContainAndRemoveCanonicalHosts() {
    let hosts = [" 192.168.1.1 ", "172.20.10.15"]

    #expect(PTPIPPairedHosts.contains("192.168.1.1", in: hosts))
    #expect(!PTPIPPairedHosts.contains("10.0.0.5", in: hosts))
    #expect(PTPIPPairedHosts.removing("192.168.1.1", from: hosts) == ["172.20.10.15"])
}
