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
