import Foundation
import Testing

@testable import OpenZCineCore

private func setup(
    host: String, path: CameraPath, name: String = "ZR_6002199"
) -> PTPIPSavedCameraRecord {
    PTPIPSavedCameraRecord(
        host: host, displayName: name, transport: "Wi-Fi", lastSeenAt: nil, path: path)
}

/// One router needs no qualifier — a distinction nothing is being distinguished from is noise.
@Test func aLoneRouterChipIsJustRouter() {
    let router = setup(host: "192.168.1.246", path: .infrastructure(networkName: nil))
    let accessPoint = setup(host: "192.168.1.1", path: .cameraAccessPoint(ssid: "NIKON_ZR_02199"))

    let group = [router, accessPoint]
    #expect(SavedCameraPathGroups.pathChipLabel(for: router, in: group) == "Wi-Fi")
    #expect(SavedCameraPathGroups.pathChipLabel(for: accessPoint, in: group) == "Camera AP")
}

/// Two of them, and the chips have to say which is which — but SHORT, because this is a chip row
/// on a phone and four addresses is a swipe to read.
@Test func repeatedWiFiSetupsAreNumbered() {
    let home = setup(host: "192.168.1.246", path: .infrastructure(networkName: nil))
    let portable = setup(host: "192.168.129.66", path: .infrastructure(networkName: nil))

    // Numbered by subnet, not by the group's recency order — otherwise connecting to one would
    // renumber the other under the operator.
    let group = [portable, home]
    #expect(SavedCameraPathGroups.pathChipLabel(for: home, in: group) == "Wi-Fi (1)")
    #expect(SavedCameraPathGroups.pathChipLabel(for: portable, in: group) == "Wi-Fi (2)")
    #expect(SavedCameraPathGroups.pathChipLabel(for: home, in: group.reversed()) == "Wi-Fi (1)")
}

/// The point of the number is that the operator can replace it with a word that means something.
@Test func anOperatorsOwnNameWinsOverEverything() {
    var studio = setup(host: "192.168.1.246", path: .infrastructure(networkName: nil))
    studio.setupName = "Studio"
    let van = setup(host: "192.168.129.66", path: .infrastructure(networkName: nil))

    let group = [studio, van]
    #expect(SavedCameraPathGroups.pathChipLabel(for: studio, in: group) == "Studio")
    // Its sibling keeps its number rather than being renumbered around the named one.
    #expect(SavedCameraPathGroups.pathChipLabel(for: van, in: group) == "Wi-Fi (2)")

    // A name on a LONE setup replaces the plain word too — naming is not only for duplicates.
    var cable = setup(host: "usb:0000", path: .usbC)
    cable.setupName = "Rig cable"
    #expect(SavedCameraPathGroups.pathChipLabel(for: cable, in: [cable]) == "Rig cable")
}

/// The network's own name stays out of the chip and answers "which network IS this" elsewhere —
/// a row subtitle, or the placeholder when renaming.
@Test func theNetworkNameIsAvailableWithoutCrowdingTheChip() {
    let studio = setup(host: "192.168.1.246", path: .infrastructure(networkName: "Studio"))
    #expect(SavedCameraPathGroups.networkQualifier(for: studio) == "Studio")
    #expect(SavedCameraPathGroups.pathChipLabel(for: studio, in: [studio]) == "Wi-Fi")
}

/// Only routers repeat. Nothing else should ever grow a qualifier, however the group is shaped.
@Test func noOtherKindIsEverQualified() {
    let usb = setup(host: "usb:0000", path: .usbC)
    let hotspot = setup(host: "172.20.10.8", path: .phoneHotspot)
    let routerA = setup(host: "192.168.1.246", path: .infrastructure(networkName: nil))
    let routerB = setup(host: "192.168.2.9", path: .infrastructure(networkName: nil))

    let group = [usb, hotspot, routerA, routerB]
    #expect(SavedCameraPathGroups.pathChipLabel(for: usb, in: group) == "USB-C")
    #expect(SavedCameraPathGroups.pathChipLabel(for: hotspot, in: group) == "Hotspot")
}

/// The qualifier is the thing the records are KEYED on, so a label can never claim a difference
/// the store does not make, or hide one it does.
@Test func theQualifierIsWhateverTheIdentityIs() {
    let named = setup(host: "192.168.1.246", path: .infrastructure(networkName: "Studio"))
    #expect(SavedCameraPathGroups.networkQualifier(for: named) == "Studio")

    let unnamed = setup(host: "192.168.129.66", path: .infrastructure(networkName: nil))
    #expect(SavedCameraPathGroups.networkQualifier(for: unnamed) == "192.168.129.x")

    // A blank name is not a name.
    let blank = setup(host: "192.168.1.246", path: .infrastructure(networkName: "   "))
    #expect(SavedCameraPathGroups.networkQualifier(for: blank) == "192.168.1.x")

    // A USB key is not an address and has no network to name.
    #expect(
        SavedCameraPathGroups.networkQualifier(for: setup(host: "usb:0000", path: .usbC)) == nil)
}
