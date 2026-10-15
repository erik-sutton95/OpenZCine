import Testing
import UIKit

@testable import Runner

@MainActor @Suite(.serialized) struct SettingsSharedOwnerTests {
    @Test func camerasAndSettingsHonorTheForegroundWakePreference() {
        let storage = UserDefaults.standard
        let saved = storage.data(forKey: "operatorPreferences.v1")
        let previous = UIApplication.shared.isIdleTimerDisabled
        defer {
            if let saved { storage.set(saved, forKey: "operatorPreferences.v1") }
            else { storage.removeObject(forKey: "operatorPreferences.v1") }
            UIApplication.shared.isIdleTimerDisabled = previous
        }
        let model = NativeAppModel()
        #expect(!model.isMonitorPresented)
        model.preferences.keepScreenAwake = true
        model.syncScreenWakePolicy()
        #expect(UIApplication.shared.isIdleTimerDisabled,
            "The foreground preference also applies on cameras and settings")
    }
}


extension SettingsSharedOwnerTests {
    @Test func rootPhaseSeedsTheInitialForegroundAndRestoresTheCurrentPreference() {
        let storage = UserDefaults.standard
        let saved = storage.data(forKey: "operatorPreferences.v1")
        let priorIdle = UIApplication.shared.isIdleTimerDisabled
        defer {
            if let saved { storage.set(saved, forKey: "operatorPreferences.v1") }
            else { storage.removeObject(forKey: "operatorPreferences.v1") }
            UIApplication.shared.isIdleTimerDisabled = priorIdle
        }
        storage.removeObject(forKey: "operatorPreferences.v1")
        UIApplication.shared.isIdleTimerDisabled = false
        let model = NativeAppModel()
        #expect(model.preferences.keepScreenAwake)
        // The real root explicitly seeds its phase; ShellModel suppresses its initial true.
        model.syncScreenWakePolicy(sceneActive: true)
        #expect(UIApplication.shared.isIdleTimerDisabled)
        model.syncScreenWakePolicy(sceneActive: false)
        #expect(!UIApplication.shared.isIdleTimerDisabled)
        model.preferences.keepScreenAwake = false
        model.syncScreenWakePolicy(sceneActive: true)
        #expect(!UIApplication.shared.isIdleTimerDisabled)
        model.preferences.keepScreenAwake = true
        #expect(UIApplication.shared.isIdleTimerDisabled)
        model.syncScreenWakePolicy(sceneActive: false)
        #expect(!UIApplication.shared.isIdleTimerDisabled)
    }
}
