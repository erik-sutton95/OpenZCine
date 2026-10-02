import MonitorUI
import OpenZCineCore
import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AppDiagnostics.shared.start()
        // The camera transports live in OpenCineNikon; their milestones land in this app's
        // connection log and diagnostics journal, wired before any transport exists.
        PTPIPTransport.connectionLog = { logConnection($0) }
        USBCameraDeviceBrowser.shared.onEvent = { event in
            switch event {
            case .authorizationGranted: AppDiagnostics.shared.record(.usbAuthorizationGranted)
            case .authorizationDenied: AppDiagnostics.shared.record(.usbAuthorizationDenied)
            case .cameraAttached: AppDiagnostics.shared.record(.usbCameraAttached)
            case .cameraDetached: AppDiagnostics.shared.record(.usbCameraDetached)
            }
        }
        // Shared OpenCine screens read the brand accent; assign it before any view is built.
        MonitorTheme.accentRGB = BrandColors.accentRGB
        MonitorTheme.prepareResources()
        if #unavailable(iOS 13.0) {
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.insetsLayoutMarginsFromSafeArea = false

            let hostingController = UIHostingController(rootView: NativeAppRoot())
            hostingController.view.backgroundColor = .clear
            hostingController.view.insetsLayoutMarginsFromSafeArea = false
            hostingController.view.layoutMargins = .zero

            window.rootViewController = hostingController
            window.makeKeyAndVisible()
            self.window = window
        }
        return true
    }
}
