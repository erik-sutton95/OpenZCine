import Foundation
import OpenCineAppKit
import OpenZCineCore
import SwiftUI
import Testing
import UIKit
import XCTest

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
        let payload = #"{"path":"/"# + #"Users/alex/Library/Logs/x","contact":"alex@example.com"}"#
        let report = DiagnosticEventStore.renderReport(
            metadata: metadata,
            events: [],
            payloads: [(name: "diagnostic-1.json", data: Data(payload.utf8))]
        )
        #expect(report.contains("metrickit-diagnostic-1.json"))
        #expect(!report.contains("alex"))
        #expect(report.contains("/" + "Users/<redacted>"))
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

    @Test("Reports use this app's names, support address, adapter, redaction and source identity")
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
        // The SDK's session forwards through OpenCine's URL protocol, named for this app (A6-04).
        #expect(AppReliabilityURLProtocol.forwarder === ReliabilityDiagnostics.forwarder)
        let session = AppReliabilityURLProtocol.makeSDKSession()
        let protocols = (session.configuration.protocolClasses ?? []).map(ObjectIdentifier.init)
        #expect(protocols == [ObjectIdentifier(AppReliabilityURLProtocol.self)])
        // Nikon keeps no network readable (A6-10); Android redacts the same table identically.
        for ssid in ["NIKON_Z_8_12345678", "OsmoPocket3-A1B2", "EdgeRouter-5G", "CafeWiFi"] {
            #expect(host.redact("ssid=\(ssid)") == "ssid=<redacted>")
        }
        // The build stamps its source identity (A6-07).
        #expect(host.sourceRevision != "unknown")
        let identity = Bundle.main.object(forInfoDictionaryKey: "OPCBuildIdentity") as? String
        #expect(identity?.hasPrefix("ios-") == true)
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

/// SIMULATED launch over the shipping app root. The clock never uses wall time; callbacks
/// adapt a temporary consent domain rather than changing the operator's saved choice.
@MainActor final class StartupCompositionTests: XCTestCase {
    @MainActor private final class Clock {
        var now: Duration = .zero
        var waiting: [(Duration, CheckedContinuation<Void, any Error>)] = []
        func sleep(_ duration: Duration) async throws {
            try await withCheckedThrowingContinuation { waiting.append((now + duration, $0)) }
        }
        func advance(_ duration: Duration) {
            now += duration
            let ready = waiting.filter { $0.0 <= now }
            waiting.removeAll { $0.0 <= now }
            for (_, continuation) in ready { continuation.resume() }
        }
        func release() {
            let old = waiting
            waiting = []
            for (_, continuation) in old { continuation.resume() }
        }
    }

    private func settle(_ host: UIHostingController<AnyView>, _ done: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            host.view.layoutIfNeeded()
            if done() { return true }
            await Task.yield()
        }
        return done()
    }

    private func identifiers(_ object: NSObject, seen: inout Set<ObjectIdentifier>) -> Set<String> {
        guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
        var result = Set<String>()
        let getter = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: getter),
            let value = object.perform(getter)?.takeUnretainedValue() as? String
        {
            result.insert(value)
        }
        for element in object.accessibilityElements as? [NSObject] ?? [] {
            result.formUnion(identifiers(element, seen: &seen))
        }
        let count = object.accessibilityElementCount()
        if count > 0 && count < 512 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject {
                    result.formUnion(identifiers(child, seen: &seen))
                }
            }
        }
        if let view = object as? UIView {
            for child in view.subviews { result.formUnion(identifiers(child, seen: &seen)) }
        }
        return result
    }

    func testActualRootRunsSharedLaunchAndConsentWithTheExistingHostActions() async throws {
        let clock = Clock()
        let domain = "startup.hosted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let consent = ReliabilityReportingConsent(defaults: defaults)
        var ticks = 0
        var choices: [Bool] = []
        let startup = MonitorAppStartup(
            reports: .init(
                isAvailable: { true }, hasDecision: { consent.hasDecision },
                setConsent: {
                    choices.append($0)
                    consent.setOptedIn($0)
                }, tick: { ticks += 1 }),
            sleep: { try await clock.sleep($0) })
        let host = UIHostingController(
            rootView: AnyView(
                NativeAppRoot(startup: startup).transaction { $0.disablesAnimations = true }))
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            startup.retire()
            clock.release()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let started = await settle(host) { clock.waiting.count == 2 }
        XCTAssertTrue(started, "Actual root must mount the shared startup task")
        var seen = Set<ObjectIdentifier>()
        XCTAssertTrue(identifiers(host.view, seen: &seen).contains("monitor-launch-splash"))
        clock.advance(.milliseconds(2_249))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(startup.consentOffer)
        clock.advance(.milliseconds(1))
        let offered = await settle(host) { startup.consentOffer != nil }
        XCTAssertTrue(offered, "Actual root must offer consent at the original fade start")
        let offer = try XCTUnwrap(startup.consentOffer)
        let presented = await settle(host) {
            guard let sheet = host.presentedViewController else { return false }
            var seen = Set<ObjectIdentifier>()
            return identifiers(sheet.view, seen: &seen).contains("reliability.consent.decline")
        }
        XCTAssertTrue(presented, "The actual root must present its existing consent sheet")
        offer.choose(false)
        let dismissing = await settle(host) {
            host.presentedViewController == nil
                || host.presentedViewController?.isBeingDismissed == true
        }
        XCTAssertTrue(
            dismissing, "The existing choice callback must dismiss the actual consent sheet")
        XCTAssertEqual(choices, [false])
        XCTAssertTrue(ReliabilityReportingConsent(defaults: defaults).hasDecision)
        XCTAssertFalse(consent.isOptedIn)
        host.rootView = AnyView(Color.clear)
        let retired = await settle(host) { startup.isRetired }
        XCTAssertTrue(retired, "Removing the actual root must retire its shared callbacks")
        let count = ticks
        clock.release()
        offer.choose(true)
        startup.sceneChanged()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(ticks, count)
        XCTAssertEqual(choices, [false])
    }
}

/// SIMULATED render baseline from the original Branding source captured before extraction.
/// The app's actual assets, font and backdrop render on both sides of the shared seam.
@MainActor final class StartupAppearanceTests: XCTestCase {
    func testSharedSplashMatchesOriginalRenderedBrandContentInEveryLayout() throws {
        for (size, compact) in [
            (CGSize(width: 874, height: 402), false),
            (CGSize(width: 402, height: 874), false),
            (CGSize(width: 300, height: 300), true),
            (CGSize(width: 402, height: 874), true),
        ] {
            let original = ImageRenderer(
                content: OriginalStartupSplash(compact: compact)
                    .frame(width: size.width, height: size.height).environment(\.colorScheme, .dark)
            )
            let shared = ImageRenderer(
                content: LaunchSplashContent(compact: compact)
                    .frame(width: size.width, height: size.height).environment(\.colorScheme, .dark)
            )
            original.scale = 1
            shared.scale = 1
            let before = try XCTUnwrap(original.uiImage)
            let after = try XCTUnwrap(shared.uiImage)
            let beforePixels = try XCTUnwrap(before.cgImage?.dataProvider?.data)
            let afterPixels = try XCTUnwrap(after.cgImage?.dataProvider?.data)
            XCTAssertEqual(before.size, after.size)
            XCTAssertTrue(
                (beforePixels as Data) == (afterPixels as Data),
                "Shared launch must preserve original pixels at \(size), compact=\(compact)")
            for (name, image) in [("original", before), ("shared", after)] {
                let attachment = XCTAttachment(image: image)
                attachment.name =
                    "launch-\(name)-\(Int(size.width))x\(Int(size.height))-compact-\(compact)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}

private struct OriginalStartupSplash: View {
    var compact: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height
            let logoSize = min(proxy.size.width * (landscape ? 0.16 : 0.28), compact ? 72 : 96)

            ZStack {
                BrandBackdrop()

                if landscape {
                    HStack(spacing: max(32, proxy.size.width * 0.06)) {
                        AppLogoMark(size: logoSize)
                        OpenZCineWordmark(fontSize: compact ? 28 : 34)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, max(32, proxy.size.width * 0.08))
                } else {
                    VStack(spacing: 24) {
                        AppLogoMark(size: logoSize)
                        OpenZCineWordmark(fontSize: 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
