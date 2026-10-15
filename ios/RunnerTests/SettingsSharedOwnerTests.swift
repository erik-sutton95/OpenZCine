import Foundation
import MonitorPresentation
import MonitorUI
import Testing
import UIKit

@testable import Runner

@MainActor @Suite(.serialized) struct SettingsSharedOwnerTests {
    @Test func camerasAndSettingsHonorTheForegroundWakePreference() {
        let storage = UserDefaults.standard
        let commonKeys = ["OpenZCine.KeepScreenAwake", "OpenZCine.RecordConfirmation", "OpenZCine.HapticsEnabled"]
        let commonSaved = commonKeys.map { storage.object(forKey: $0) }
        let saved = storage.data(forKey: "operatorPreferences.v1")
        let previous = UIApplication.shared.isIdleTimerDisabled
        defer {
            for (key, value) in zip(commonKeys, commonSaved) {
                if let value { storage.set(value, forKey: key) }
                else { storage.removeObject(forKey: key) }
            }
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
        let commonKeys = ["OpenZCine.KeepScreenAwake", "OpenZCine.RecordConfirmation", "OpenZCine.HapticsEnabled"]
        let commonSaved = commonKeys.map { storage.object(forKey: $0) }
        let saved = storage.data(forKey: "operatorPreferences.v1")
        let priorIdle = UIApplication.shared.isIdleTimerDisabled
        defer {
            for (key, value) in zip(commonKeys, commonSaved) {
                if let value { storage.set(value, forKey: key) }
                else { storage.removeObject(forKey: key) }
            }
            if let saved { storage.set(saved, forKey: "operatorPreferences.v1") }
            else { storage.removeObject(forKey: "operatorPreferences.v1") }
            UIApplication.shared.isIdleTimerDisabled = priorIdle
        }
        storage.removeObject(forKey: "operatorPreferences.v1")
        for key in commonKeys { storage.removeObject(forKey: key) }
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

/// A2-26: Z's Licenses and NOTICE pages are the repository files shipped in the app bundle;
/// privacy and terms stay the web pages behind the settings internet hop.
extension SettingsSharedOwnerTests {
    @Test func legalPagesAreTheBundledRepositoryFilesAndTheWebPages() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func text(_ path: String) throws -> String {
            try String(contentsOf: repository.appending(path: path), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (copy, canonical) in [("NOTICE", "NOTICE"), ("LICENSE", "LICENSE"),
            ("THIRD-PARTY-NOTICES", "THIRD-PARTY-NOTICES.md")] {
            let bundled = try #require(Bundle.main.url(forResource: copy, withExtension: "txt", subdirectory: "Legal"))
            #expect(try Data(contentsOf: bundled) == Data(contentsOf: repository.appending(path: canonical)),
                "Legal/\(copy).txt is the repository file, staged at build time")
        }
        let legal = MonitorLegalDocuments.z
        let platform = try #require(MonitorPlatformLegalNotices.text)
        #expect(legal.notice == .text(try text("NOTICE")))
        #expect(legal.licenses == .text([try text("LICENSE"), try text("THIRD-PARTY-NOTICES.md"), platform]
            .joined(separator: "\n\n")))
        #expect(legal.privacy == .link(SupportLinkCatalog.privacy))
        #expect(legal.terms == .link(SupportLinkCatalog.terms))
    }
}
