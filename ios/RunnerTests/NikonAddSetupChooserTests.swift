import OpenCineAppKit
import OpenCineCore
import OpenZCineCore
import Testing

@testable import Runner

/// Add setup on Z is OpenCine's shared chooser (the one Pocket shows): the Nikon host supplies
/// its routes and their live action words, never its own sheet or copy.
@MainActor
@Suite("Nikon Add setup uses the shared chooser")
struct NikonAddSetupChooserTests {
    static let camera = SavedCamera(
        id: "zr", integration: IntegrationID("org.opencapture.nikon"), advertisedName: "ZR_6002199",
        model: "Nikon ZR", routes: [])

    @Test func nikonRoutesShowInTheSharedChooser() {
        let kinds: [CameraPath.Kind] = [.usbC, .cameraAccessPoint, .infrastructure, .phoneHotspot]
        let chooser = StationNetworkSetupRules.setupChooser(
            context: .camera(Self.camera),
            routes: kinds.map {
                StationSetupRoute(
                    NikonSavedRecordsV0.routeKind($0),
                    actionTitle: NikonSetupOptions.actionTitle(for: $0, reachable: false))
            })
        #expect(chooser.title == "How should this camera connect?")
        #expect(chooser.options.map(\.id) == ["wifi", "phoneHotspot", "cameraAccessPoint", "usb"])
        #expect(
            chooser.options.map(\.actionTitle) == [
                "Find on this network", "Wait for camera", "Join camera Wi-Fi",
                "Connect when plugged in",
            ])
    }

    @Test func reachableRoutesConnectNow() {
        #expect(NikonSetupOptions.actionTitle(for: .usbC, reachable: true) == "Connect now")
        #expect(
            NikonSetupOptions.actionTitle(for: .infrastructure, reachable: true) == "Connect now")
        #expect(
            NikonSetupOptions.actionTitle(for: .hdmiCapture, reachable: false) == "Use HDMI capture"
        )
    }
}
