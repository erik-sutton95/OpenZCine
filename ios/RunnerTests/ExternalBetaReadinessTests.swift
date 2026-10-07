import Foundation
import OpenCineAppKit
import OpenZCineCore
import Testing

@testable import Runner

@Suite("External beta diagnostics")
struct ExternalBetaDiagnosticsTests {
    private let metadata = DiagnosticReportMetadata(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        appVersion: "0.2.0",
        buildNumber: "200",
        deviceClass: "iPhone",
        osName: "iOS",
        osVersion: "18.0"
    )

    @Test("Support destinations keep the account-backed feature form and the privacy policy")
    func supportDestinations() {
        #expect(SupportLinkCatalog.support.absoluteString == "https://openzcine.app/support/")
        #expect(SupportLinkCatalog.privacy.absoluteString == "https://openzcine.app/privacy/")
        #expect(
            SupportLinkCatalog.featureRequest.absoluteString.contains(
                "category=ideas-feature-requests"))
    }

    @Test("Camera AP destinations preserve the selected route behind one consent prompt")
    func cameraAccessPointDestinations() {
        #expect(SettingsInternetDestination.support.webURL == SupportLinkCatalog.support)
        #expect(
            SettingsInternetDestination.featureRequest.webURL == SupportLinkCatalog.featureRequest
        )

        for destination in SettingsInternetDestination.allCases {
            #expect(destination.confirmationMessage.contains(destination.title))
            #expect(destination.confirmationMessage.contains("disconnect from the camera"))
            #expect(destination.confirmationMessage.contains("cellular"))
            #expect(destination.confirmationMessage.contains("internet-connected Wi-Fi"))
        }
    }

    @Test("External pages reconnect only after the accepted browser handoff backgrounds the app")
    func externalBrowserReturnPolicy() {
        #expect(
            !ExternalInternetLinkReturnPolicy.shouldReconnect(
                handoffActive: true,
                sawBackground: false
            )
        )
        #expect(
            ExternalInternetLinkReturnPolicy.shouldReconnect(
                handoffActive: true,
                sawBackground: true
            )
        )
        #expect(
            !ExternalInternetLinkReturnPolicy.shouldReconnect(
                handoffActive: false,
                sawBackground: true
            )
        )
    }

    @Test("Event-channel diagnostics ignore expected cancellation and stale sessions")
    func eventChannelDiagnosticPolicy() {
        #expect(
            EventChannelDiagnosticPolicy.shouldRecordUnexpectedEnd(
                isCancelled: false,
                ownsSession: true
            ))
        #expect(
            !EventChannelDiagnosticPolicy.shouldRecordUnexpectedEnd(
                isCancelled: true,
                ownsSession: true
            ))
        #expect(
            !EventChannelDiagnosticPolicy.shouldRecordUnexpectedEnd(
                isCancelled: false,
                ownsSession: false
            ))
    }

    @Test("Internet route progress survives Settings and ignores stale completion")
    @MainActor
    func internetRouteProgress() {
        let model = NativeAppModel()

        model.beginInternetDestinationPreparation("Support")
        #expect(model.internetDestinationPreparationTitle == "Support")

        model.beginInternetDestinationPreparation("Report a Problem")
        model.finishInternetDestinationPreparation("Support")
        #expect(model.internetDestinationPreparationTitle == "Report a Problem")

        model.finishInternetDestinationPreparation("Report a Problem")
        #expect(model.internetDestinationPreparationTitle == nil)
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
        #expect(report.contains("Connect attempt trace"))
        #expect(report.contains("No MetricKit payloads"))
        // No VPN probe on this app yet: the report must not claim the tunnel is off.
        #expect(report.contains("vpn: unknown"))
    }

    @Test("The report passes through the shared privacy redactor")
    func renderedReportRedactsPersonalText() {
        let payload = #"{"path":"/Users/alex/Library/Logs/x","contact":"alex@example.com"}"#
        let report = DiagnosticEventStore.renderReport(
            metadata: metadata,
            events: [],
            payloads: [(name: "diagnostic-1.json", data: Data(payload.utf8))]
        )
        #expect(report.contains("metrickit-diagnostic-1.json"))
        #expect(!report.contains("alex"))
        #expect(report.contains("/Users/<redacted>"))
        #expect(report.contains("<email>"))
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
        await store.recordConnectTrace(
            "event=connect.gate body=z6iii inferred=three ops=unknown fallback=none pairing=attempt"
        )
        let url = try await store.makeReport(metadata: metadata)
        let report = try String(contentsOf: url, encoding: .utf8)
        #expect(report.contains("connection.connected"))
        #expect(report.hasPrefix("OpenZCine diagnostic report\n"))
        #expect(report.contains("app: 0.2.0 (200)"))
        #expect(report.contains("os: iOS 18.0"))
        #expect(report.contains("body=z6iii"))
        #expect(report.contains("Connect attempt trace"))
        // The problem report's technical details read the same files at once.
        let details = store.manualReport(metadata: metadata)
        #expect(details.contains("connection.connected"))
        #expect(details.contains("Connect attempt trace"))
        #expect(details.contains("body=z6iii"))
    }

    @Test("Reports use this app's names and support address, held back only by the live session")
    func reliabilityHolder() {
        let host = ReliabilityDiagnostics.host
        #expect(host.product == "OpenZCine")
        #expect(host.listingName == "OpenZCine")
        #expect(
            host.release(version: "0.2.0", build: "200") == "com.opencapture.openzcine@0.2.0+200")
        #expect(host.supportEmail == "support@opencapture.org")
        // Tests run a development build: reinstalls must not read as watchdog kills.
        #expect(host.environment == "development")
        #expect(!host.tracksWatchdogTerminations)
        // A Z body serves 192.168.1.x, a common home network, so no address prefix gates reports.
        #expect(ReliabilityDiagnostics.gate.cameraIPv4Prefix == nil)
        #expect(ReliabilityDiagnostics.reporting.gate === ReliabilityDiagnostics.gate)
        #expect(ReliabilityDiagnostics.reporting.consent === ReliabilityDiagnostics.consent)
        #expect(ReliabilityReportingConsent.defaultsKey == "opc.reliabilityReporting.optIn")
    }

    @Test("USB handshake stages round-trip through the closed diagnostic vocabulary")
    func usbHandshakeStagesAreClosedEvents() {
        let stages: [USBHandshakeDiagnostic] = [
            .sessionOpen, .deviceInfo, .openSession, .appMode, .identify,
        ]
        for stage in stages {
            #expect(AppDiagnosticEvent(rawValue: stage.rawValue) != nil)
        }
        #expect(
            stages.map(\.rawValue) == [
                "usb.session.open",
                "usb.handshake.device-info",
                "usb.handshake.open-session",
                "usb.handshake.app-mode",
                "usb.handshake.identify",
            ])
    }
}
