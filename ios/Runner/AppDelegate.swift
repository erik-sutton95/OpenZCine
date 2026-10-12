import MonitorUI
import OpenZCineCore
import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AppDiagnostics.shared.start()
        ReliabilityDiagnostics.incidents.install()
        #if DEBUG
            ReliabilityDiagnostics.verification.prepareIfRequested()
        #endif
        ReliabilityDiagnostics.reporting.install()
        #if DEBUG
            ReliabilityDiagnostics.verification.runIfRequested()
        #endif
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
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = SceneDelegate.self
        }
        return configuration
    }
}
