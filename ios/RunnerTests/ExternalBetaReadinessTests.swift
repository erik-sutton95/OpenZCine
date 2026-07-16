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

    @Test("Support destinations retain account-backed feature discussions and use the report relay")
    func supportDestinations() {
        #expect(SupportLinkCatalog.support.absoluteString == "https://openzcine.app/support/")
        #expect(
            SupportLinkCatalog.featureRequest.absoluteString.contains(
                "category=ideas-feature-requests"))
        #expect(
            SupportLinkCatalog.bugReportEndpoint.absoluteString
                == "https://reports.openzcine.app/v1/bug-reports")
        #expect(SupportLinkCatalog.bugReportEndpoint.scheme == "https")
        #expect(!SupportLinkCatalog.bugReportEndpoint.absoluteString.contains("github.com"))
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

@Suite("Anonymous bug reports")
struct AnonymousBugReportTests {
    private let context = BugReportContext(
        platform: "ios",
        appVersion: "0.2.0",
        buildNumber: "200",
        osVersion: "18.0",
        deviceClass: .phone,
        connection: .unknown
    )

    @Test("Relay request uses the v1 schema, exact headers, and only safe automatic context")
    func relayRequestContract() throws {
        let payload = try validDraft().payload(baseContext: context)
        let key = try #require(UUID(uuidString: "D7F1D858-ACFA-4AC2-9EA7-4D9E6A4CB7B6"))
        let request = try URLSessionBugReportSubmitter.makeRequest(payload, idempotencyKey: key)

        #expect(request.url == SupportLinkCatalog.bugReportEndpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)

        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let root = try #require(object as? [String: Any])
        #expect(root["schemaVersion"] as? Int == 1)
        #expect(root["summary"] as? String == "Live view stopped")
        #expect(
            root["whatHappened"] as? String == "The monitor stopped updating after reconnecting.")
        #expect(root["stepsToReproduce"] as? String == "1. Connect\n2. Disconnect\n3. Reconnect")
        #expect(root["frequency"] as? String == "sometimes")

        let encodedContext = try #require(root["context"] as? [String: Any])
        #expect(
            Set(encodedContext.keys)
                == Set([
                    "platform", "appVersion", "buildNumber", "osVersion", "deviceClass",
                    "connection",
                ])
        )
        #expect(encodedContext["platform"] as? String == "ios")
        #expect(encodedContext["appVersion"] as? String == "0.2.0")
        #expect(encodedContext["buildNumber"] as? String == "200")
        #expect(encodedContext["osVersion"] as? String == "18.0")
        #expect(encodedContext["deviceClass"] as? String == "phone")
        #expect(encodedContext["connection"] as? String == "usb")

        let encoded = String(decoding: body, as: UTF8.self).lowercased()
        for prohibitedKey in [
            "serial", "model", "ssid", "ipaddress", "cameraid", "diagnostic", "metrickit",
            "attachment", "screenshot", "media", "identifier",
        ] {
            #expect(!encoded.contains(prohibitedKey))
        }
    }

    @Test("Draft validation rejects blank and overlong fields without creating a payload")
    func draftValidation() {
        var draft = validDraft()
        draft.summary = " \n "
        #expect(throws: BugReportValidationError.summaryRequired) {
            try draft.payload(baseContext: context)
        }

        draft = validDraft()
        draft.summary = String(repeating: "s", count: 121)
        #expect(throws: BugReportValidationError.summaryTooLong) {
            try draft.payload(baseContext: context)
        }

        draft = validDraft()
        draft.whatHappened = "\t"
        #expect(throws: BugReportValidationError.whatHappenedRequired) {
            try draft.payload(baseContext: context)
        }

        draft = validDraft()
        draft.whatHappened = String(repeating: "w", count: 4_001)
        #expect(throws: BugReportValidationError.whatHappenedTooLong) {
            try draft.payload(baseContext: context)
        }

        draft = validDraft()
        draft.stepsToReproduce = String(repeating: "r", count: 4_001)
        #expect(throws: BugReportValidationError.stepsTooLong) {
            try draft.payload(baseContext: context)
        }
    }

    @Test("Nested worker response exposes the optional public issue link")
    func nestedWorkerReceipt() {
        let data = Data(
            "{\"issue\":{\"number\":123,\"url\":\"https://github.com/erik-sutton95/OpenZCine/issues/123\"}}"
                .utf8)
        let receipt = URLSessionBugReportSubmitter.decodeReceipt(data)

        #expect(receipt.issueNumber == 123)
        #expect(
            receipt.issueURL?.absoluteString
                == "https://github.com/erik-sutton95/OpenZCine/issues/123")
    }

    @MainActor
    @Test("Form sends through an injected submitter and shows a success receipt")
    func formSuccess() async {
        let receipt = BugReportSubmissionReceipt(
            issueNumber: 123,
            issueURL: URL(string: "https://github.com/erik-sutton95/OpenZCine/issues/123")
        )
        let form = BugReportFormModel(
            baseContext: context,
            submitter: TestBugReportSubmitter(result: .success(receipt))
        )
        form.draft = validDraft()

        await form.submit()

        #expect(form.receipt == receipt)
        #expect(!form.isSubmitting)
        #expect(form.errorMessage == nil)
    }

    @MainActor
    @Test("Form preserves its draft and maps rate limits to a concise retry message")
    func formRateLimitFailure() async {
        let form = BugReportFormModel(
            baseContext: context,
            submitter: TestBugReportSubmitter(result: .failure(.rateLimited(retryAfter: 45)))
        )
        form.draft = validDraft()

        await form.submit()

        #expect(form.draft == validDraft())
        #expect(form.errorMessage == "Too many reports were sent. Try again in about 45 seconds.")
        #expect(!form.isSubmitting)
        #expect(URLSessionBugReportSubmitter.retryAfterSeconds("45") == 45)
        #expect(URLSessionBugReportSubmitter.retryAfterSeconds("0") == nil)
        #expect(URLSessionBugReportSubmitter.retryAfterSeconds("not-a-number") == nil)
        #expect(
            URLSessionBugReportSubmitter.submissionError(
                statusCode: 429,
                retryAfterHeader: "45"
            ) == .rateLimited(retryAfter: 45)
        )
        #expect(
            URLSessionBugReportSubmitter.submissionError(
                statusCode: 503,
                retryAfterHeader: "45"
            ) == .unavailable
        )
    }

    @MainActor
    @Test("A retry retains its idempotency key until the person starts another report")
    func retryRetainsIdempotencyKey() async throws {
        let submitter = RetryRecordingBugReportSubmitter()
        let form = BugReportFormModel(baseContext: context, submitter: submitter)
        form.draft = validDraft()

        await form.submit()
        await form.submit()

        let retryKeys = await submitter.receivedKeys()
        #expect(retryKeys.count == 2)
        let firstRetryKey = try #require(retryKeys.first)
        let secondRetryKey = try #require(retryKeys.last)
        #expect(firstRetryKey == secondRetryKey)

        form.startAnotherReport()
        form.draft = validDraft()
        await form.submit()

        let allKeys = await submitter.receivedKeys()
        #expect(allKeys.count == 3)
        let newReportKey = try #require(allKeys.last)
        #expect(newReportKey != secondRetryKey)

        let changedSubmitter = RetryRecordingBugReportSubmitter()
        let changedForm = BugReportFormModel(baseContext: context, submitter: changedSubmitter)
        changedForm.draft = validDraft()
        await changedForm.submit()
        changedForm.draft.summary = "Live view stopped after switching lenses"
        await changedForm.submit()

        let changedPayloadKeys = await changedSubmitter.receivedKeys()
        #expect(changedPayloadKeys.count == 2)
        let firstChangedPayloadKey = try #require(changedPayloadKeys.first)
        let secondChangedPayloadKey = try #require(changedPayloadKeys.last)
        #expect(firstChangedPayloadKey != secondChangedPayloadKey)
    }

    private func validDraft() -> BugReportDraft {
        BugReportDraft(
            summary: "Live view stopped",
            whatHappened: "The monitor stopped updating after reconnecting.",
            stepsToReproduce: "1. Connect\n2. Disconnect\n3. Reconnect",
            frequency: .sometimes,
            connection: .usb
        )
    }
}

private struct TestBugReportSubmitter: BugReportSubmitting {
    let result: Result<BugReportSubmissionReceipt, BugReportSubmissionError>

    func submit(
        _: BugReportPayload,
        idempotencyKey _: UUID
    ) async throws -> BugReportSubmissionReceipt {
        try result.get()
    }
}

private actor RetryRecordingBugReportSubmitter: BugReportSubmitting {
    private var keys: [UUID] = []

    func submit(
        _: BugReportPayload,
        idempotencyKey: UUID
    ) async throws -> BugReportSubmissionReceipt {
        keys.append(idempotencyKey)
        if keys.count == 1 {
            throw BugReportSubmissionError.unavailable
        }
        return .empty
    }

    func receivedKeys() -> [UUID] {
        keys
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
