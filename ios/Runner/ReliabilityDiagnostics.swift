import Foundation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import OpenCineSentryApple
import SafariServices
import SwiftUI
import UIKit

/// The app's reliability and problem reports: OpenCine's reporting runtime with this app's names,
/// destination, camera network and OpenCine's Sentry adapter, wired as Pocket and Insta wire
/// theirs. With no DSN in the build (`SENTRY_DSN` in Frameio.xcconfig) both stay unavailable and
/// nothing is sent. Nikon keeps no network readable: the neutral redactor removes every SSID.
enum ReliabilityDiagnostics {
    static let host = DiagnosticsHost(
        product: "OpenZCine", listingName: "OpenZCine",
        releasePackage: "com.opencapture.openzcine",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        environment: environment,
        sourceRevision: Bundle.main.object(forInfoDictionaryKey: "OPCSourceRevision") as? String
            ?? "unknown",
        supportEmail: supportEmail,
        redact: { PrivacyRedactor.redact($0, isSafeNetwork: { _ in false }) })
    static let supportEmail = "support@opencapture.org"
    static let consent = ReliabilityReportingConsent()
    static let dsn = ReliabilityReportingDSN {
        [
            Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String,
            Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String,
            ProcessInfo.processInfo.environment["SENTRY_DSN"],
        ]
    }
    /// A Z body serves 192.168.1.x, the most common home network, so no address prefix marks the
    /// camera path: the model's camera path lease alone holds reports back (`NativeAppRoot`).
    static let gate = ReliabilityReportingGate(cameraIPv4Prefix: nil)
    /// Canonical live connection observations use the current run origin; no injection is installed.
    static let origin: FeedIncidentOrigin = {
        #if DEBUG
            let verification = ReliabilityReportingVerification.mode != nil
        #else
            let verification = false
        #endif
        return FeedIncidentOrigin(
            derivesTestSource: false, verification: verification,
            buildIdentity: Bundle.main.object(forInfoDictionaryKey: "OPCBuildIdentity") as? String,
            injectionActivated: { false })
    }()
    static let reporting = ReliabilityReporting(
        host: host, consent: consent, dsn: dsn, gate: gate, origin: origin,
        sink: SentryReliabilitySink(
            host: host, consent: consent, urlProtocol: AppReliabilityURLProtocol.self))
    /// The SDK transport's forwarding session over this runtime (`AppReliabilityURLProtocol`).
    static let forwarder = ReliabilityReportingForwarder(reporting: reporting)
    #if DEBUG
        static let verification = ReliabilityReportingVerification(
            sentry: reporting, isActive: { UIApplication.shared.applicationState == .active })
    #endif
    static let incidents = FeedIncidentRuntime(
        reporting: reporting,
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("OpenZCine/Diagnostics/incidents", isDirectory: true))
    @MainActor static let problemReporting = ProblemReporting(
        host: host, gate: gate, dsnProvider: dsn.configured,
        isForeground: { UIApplication.shared.applicationState == .active })

    /// Only store builds report `production`; Xcode and ad hoc release installs are `local`.
    private static var environment: String {
        #if DEBUG
            ReliabilityEnvironment.apple(
                debug: true, verification: ReliabilityReportingVerification.mode != nil
            ).rawValue
        #else
            ReliabilityEnvironment.apple(debug: false, verification: false).rawValue
        #endif
    }
}

/// The Sentry SDK's URL protocol over this app's reporting runtime.
final class AppReliabilityURLProtocol: ReliabilityReportingURLProtocol, @unchecked Sendable {
    override class var forwarder: ReliabilityReportingForwarder { ReliabilityDiagnostics.forwarder }
}

/// The shared report form on this app's reporting, support address, accent and privacy page.
struct ProblemReportView: View {
    var body: some View {
        ProblemReportSheet(
            reporting: ReliabilityDiagnostics.problemReporting,
            isAvailable: ReliabilityDiagnostics.reporting.isAvailable,
            supportEmail: ReliabilityDiagnostics.supportEmail, accent: MonitorTheme.accent,
            technicalDetails: { AppDiagnostics.shared.manualReport() },
            privacy: { close in PrivacyPolicyPage(close: close) })
    }
}

/// The shared first-launch ask for automatic reports, in this app's name.
struct ReliabilityConsentPrompt: View {
    let onChoice: (Bool) -> Void

    var body: some View {
        ReliabilityConsentSheet(
            productName: "OpenZCine", accent: MonitorTheme.accent,
            onAccent: MonitorTheme.onAccent, onChoice: onChoice,
            privacy: { close in PrivacyPolicyPage(close: close) })
    }
}

/// The published privacy policy in an in-app Safari sheet (this app keeps no bundled copy).
private struct PrivacyPolicyPage: UIViewControllerRepresentable {
    let close: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let page = SFSafariViewController(url: SupportLinkCatalog.privacy)
        page.delegate = context.coordinator
        return page
    }

    func updateUIViewController(_ page: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(close: close) }

    @MainActor final class Coordinator: NSObject, @preconcurrency SFSafariViewControllerDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { close() }
    }
}
