import Foundation
import MonitorPresentation
import MonitorUI
import OpenCineHostedAccessibility
import OpenZCineCore
import SwiftUI
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

/// A2-26, A2-27: Z's Licenses and NOTICE pages are the repository files shipped in the app
/// bundle; privacy and terms are Z's own text, readable without leaving the camera network.
extension SettingsSharedOwnerTests {
    @Test func legalPagesAreBundledAndReadableOffline() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func text(_ path: String) throws -> String {
            try String(contentsOf: repository.appending(path: path), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (copy, canonical) in [
            ("NOTICE", "NOTICE"), ("LICENSE", "LICENSE"),
            ("THIRD-PARTY-NOTICES", "THIRD-PARTY-NOTICES.md"),
        ] {
            let bundled = try #require(
                Bundle.main.url(forResource: copy, withExtension: "txt", subdirectory: "Legal"))
            #expect(
                try Data(contentsOf: bundled)
                    == Data(contentsOf: repository.appending(path: canonical)),
                "Legal/\(copy).txt is the repository file, staged at build time")
        }
        let legal = MonitorLegalDocuments.z
        let platform = try #require(MonitorPlatformLegalNotices.text)
        #expect(legal.notice == .text(try text("NOTICE")))
        #expect(
            legal.licenses
                == .text(
                    [try text("LICENSE"), try text("THIRD-PARTY-NOTICES.md"), platform]
                        .joined(separator: "\n\n")))
        guard case .text(let privacy) = legal.privacy, case .text(let terms) = legal.terms else {
            Issue.record("Privacy and terms are bundled text, not web pages: \(legal)")
            return
        }
        #expect(privacy.hasPrefix("OpenZCine "))
        #expect(privacy.contains("Sentry") && privacy.contains("Automatic error reports are optional"))
        #expect(privacy.hasSuffix(SupportLinkCatalog.privacy.absoluteString))
        #expect(terms.hasPrefix("OpenZCine is free software under the Apache License 2.0."))
        #expect(terms.hasSuffix(SupportLinkCatalog.terms.absoluteString))
        #expect(!(privacy + terms).contains("\u{2014}"), "Operator copy never uses the em dash")
    }

    /// A2-27: Reporting Privacy from the report sheet and the first-launch consent opens the
    /// bundled page in the shared legal screen, never a web page that needs the internet.
    @Test func reportingPrivacyIsTheBundledPageInTheSharedLegalScreen() async throws {
        guard case .text(let privacy) = MonitorLegalDocuments.z.privacy else {
            Issue.record("Privacy is bundled text")
            return
        }
        let host = UIHostingController(rootView: ReliabilityDiagnostics.privacyPage(close: {}))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var label: String?
        for _ in 0..<200 where label == nil {
            host.view.layoutIfNeeded()
            label = HostedAccessibility.elements(in: host.view)
                .first { HostedAccessibility.identifier($0) == "legal.document.privacy" }?
                .accessibilityLabel
            if label == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(label == privacy)
    }
}

/// A2-35: Z composes the typed settings domains. It offers no HDR panel and no originals
/// caching, so those rows are absent values, not rows hidden behind empty help strings.
extension SettingsSharedOwnerTests {
    @Test func settingsLeaveAbsentDomainsOutAndKeepTheSharedRows() async throws {
        let model = NativeAppModel()
        let original = model.preferences
        model.preferences = OperatorPreferences.defaults
        defer { model.preferences = original }
        var rows: [MonitorSettingsTab: [String]] = [:]
        for tab in [MonitorSettingsTab.controls, .display, .storage, .system] {
            model.operatorSettingsTab = tab
            let host = UIHostingController(
                rootView: AnyView(OperatorSettingsPanel().environment(model)))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 2_000))
            window.rootViewController = host
            window.isHidden = false
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            var tabs: [String] = []
            var titles: [String] = []
            var settled = 0
            for _ in 0..<200 {
                let previous = titles
                host.view.layoutIfNeeded()
                let elements = HostedAccessibility.elements(in: host.view)
                tabs = []
                titles = []
                for element in elements {
                    guard let id = HostedAccessibility.identifier(element) else { continue }
                    if id.hasPrefix("monitor.settings.tab."), !tabs.contains(id) { tabs.append(id) }
                    if id == "monitor.settings.row.title" || id == "monitor.settings.card.title" {
                        titles.append(element.accessibilityLabel ?? "")
                    }
                }
                settled = !tabs.isEmpty && !titles.isEmpty && titles == previous ? settled + 1 : 0
                if settled >= 3 { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(tabs == MonitorSettingsTab.allCases.map { "monitor.settings.tab.\($0.id)" })
            rows[tab] = titles
        }
        #expect(
            ["Record confirmation", "Haptics", "Keep screen awake", "Bluetooth Remote Shutter"]
                .allSatisfy { rows[.controls]?.contains($0) == true }, "\(rows[.controls] ?? [])")
        #expect(rows[.display]?.contains("HDR display") == false, "\(rows[.display] ?? [])")
        #expect(
            rows[.storage]?.contains("Full Resolution Caching") == false, "\(rows[.storage] ?? [])")
        #expect(rows[.storage]?.contains("Clear Cache") == true, "\(rows[.storage] ?? [])")
        #expect(
            rows[.system]?.contains("Automatic error reports") == true, "\(rows[.system] ?? [])")
    }
}
