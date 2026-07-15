import Foundation
import Testing

@testable import Runner

@Suite("External beta diagnostics")
struct ExternalBetaDiagnosticsTests {
    private let metadata = DiagnosticReportMetadata(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        appVersion: "0.2.0",
        buildNumber: "200",
        deviceClass: "iPhone",
        operatingSystem: "iOS 18.0"
    )

    @MainActor
    @Test("Support destinations use the live forms and safe platform prefill")
    func supportDestinations() throws {
        #expect(SupportLinkCatalog.support.absoluteString == "https://openzcine.app/support/")
        #expect(
            SupportLinkCatalog.featureRequest.absoluteString.contains(
                "category=ideas-feature-requests"))

        let reportURL = SupportLinkCatalog.bugReport(metadata: metadata)
        let components = try #require(
            URLComponents(url: reportURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            })
        #expect(query["template"] == "bug_report.yml")
        #expect(query["title"] == "[iOS] ")
        #expect(query["platform"] == metadata.platformSummary)
        #expect(!reportURL.absoluteString.contains("serial"))
        #expect(!reportURL.absoluteString.contains("ssid"))
    }

    @Test("Diagnostic report contains closed events and an explicit privacy warning")
    func renderedReport() {
        let report = DiagnosticEventStore.renderReport(
            metadata: metadata,
            events: [
                DiagnosticBreadcrumb(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                    event: AppDiagnosticEvent.liveViewStarted.rawValue)
            ],
            payloads: []
        )
        #expect(report.contains("live-view.started"))
        #expect(report.contains("Review this file before sharing it publicly."))
        #expect(report.contains("Wi-Fi details"))
        #expect(report.contains("No MetricKit payloads"))
    }

    @Test("Event compaction keeps the newest complete records")
    func eventCompaction() {
        let lines = (0..<40).map { "event-\($0)" }.joined(separator: "\n") + "\n"
        let compacted = DiagnosticEventStore.compactedEventData(Data(lines.utf8), limit: 100)
        let result = String(decoding: compacted, as: UTF8.self)
        #expect(result.hasSuffix("event-39\n"))
        #expect(!result.contains("event-0\n"))
        #expect(compacted.count <= 50)
    }

    @Test("File-backed store writes an exportable report")
    func fileBackedReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticEventStore(rootDirectory: root)
        await store.record(.connectionConnected, at: metadata.generatedAt)
        let url = try await store.makeReport(metadata: metadata)
        let report = try String(contentsOf: url, encoding: .utf8)
        #expect(report.contains("connection.connected"))
        #expect(report.contains("OpenZCine 0.2.0 (build 200)"))
    }
}

@Suite("First live-view guide")
struct LiveViewGuideTests {
    @Test("Guide steps progress through camera, assist, and system controls")
    func stepOrder() {
        #expect(LiveViewGuideStep.allCases == [.cameraControls, .viewAssist, .systemControls])
        #expect(LiveViewGuideStep.cameraControls.next == .viewAssist)
        #expect(LiveViewGuideStep.viewAssist.next == .systemControls)
        #expect(LiveViewGuideStep.systemControls.next == nil)
        #expect(LiveViewGuideStep.demoValue("camera") == .cameraControls)
        #expect(LiveViewGuideStep.demoValue("assist") == .viewAssist)
        #expect(LiveViewGuideStep.demoValue("system") == .systemControls)
    }

    @MainActor
    @Test("Model presents once, completes, and can reset the guide")
    func modelPersistence() throws {
        let suiteName = "LiveViewGuideTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LiveViewGuideStore(defaults: defaults)
        let model = NativeAppModel(liveViewGuideStore: store)

        model.presentLiveViewGuideIfNeeded()
        #expect(model.liveViewGuideStep == .cameraControls)
        model.advanceLiveViewGuide()
        #expect(model.liveViewGuideStep == .viewAssist)
        model.advanceLiveViewGuide()
        model.advanceLiveViewGuide()
        #expect(model.liveViewGuideStep == nil)
        #expect(!store.shouldPresent)

        model.replayLiveViewGuide()
        #expect(store.shouldPresent)
        model.presentLiveViewGuideIfNeeded()
        model.skipLiveViewGuide()
        #expect(model.liveViewGuideStep == nil)
        #expect(!store.shouldPresent)
    }
}
