import SwiftUI
import UIKit

@main
struct OpenZCineApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            NativeAppRoot()
        }
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard scene is UIWindowScene else { return }
        configureWindowMargins(in: scene)
        AppDiagnostics.shared.record(.sceneConnected)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        configureWindowMargins(in: scene)
    }

    private func configureWindowMargins(in scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene,
            let window = windowScene.windows.first(where: \.isKeyWindow)
        else { return }
        window.insetsLayoutMarginsFromSafeArea = false
        guard let view = window.rootViewController?.viewIfLoaded else { return }
        view.backgroundColor = .clear
        view.insetsLayoutMarginsFromSafeArea = false
        view.layoutMargins = .zero
    }
}
