import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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

    @Test("Support destinations retain account-backed GitHub forms and use the report relay")
    func supportDestinations() {
        #expect(SupportLinkCatalog.support.absoluteString == "https://openzcine.app/support/")
        #expect(
            SupportLinkCatalog.featureRequest.absoluteString.contains(
                "category=ideas-feature-requests"))
        #expect(
            SupportLinkCatalog.githubBugReport.absoluteString
                == "https://github.com/erik-sutton95/OpenZCine/issues/new?template=bug_report.yml")
        #expect(SupportLinkCatalog.githubBugReport.host == "github.com")
        #expect(
            SupportLinkCatalog.bugReportEndpoint.absoluteString
                == "https://reports.openzcine.app/v1/bug-reports")
        #expect(SupportLinkCatalog.bugReportEndpoint.scheme == "https")
        #expect(!SupportLinkCatalog.bugReportEndpoint.absoluteString.contains("github.com"))
        #expect(
            SupportLinkCatalog.bugReportAttachmentsEndpoint.absoluteString
                == "https://reports.openzcine.app/v2/bug-reports"
        )
    }

    @Test("Camera AP destinations preserve the selected route behind one consent prompt")
    func cameraAccessPointDestinations() {
        #expect(SettingsInternetDestination.reportProblem.opensInAppReport)
        #expect(SettingsInternetDestination.reportProblem.webURL == nil)
        #expect(SettingsInternetDestination.support.webURL == SupportLinkCatalog.support)
        #expect(
            SettingsInternetDestination.featureRequest.webURL == SupportLinkCatalog.featureRequest
        )
        #expect(SettingsInternetDestination.demoValue("report") == .reportProblem)

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

    @Test("GitHub report handoff dismisses the chooser only after a browser accepts it")
    func githubReportHandoff() {
        var dismissalCount = 0

        BugReportGitHubHandoff.dismissAfterAcceptedBrowserOpen(false) {
            dismissalCount += 1
        }
        #expect(dismissalCount == 0)

        BugReportGitHubHandoff.dismissAfterAcceptedBrowserOpen(true) {
            dismissalCount += 1
        }
        #expect(dismissalCount == 1)
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
        #expect(body.count <= BugReportPayload.maximumJSONBodyBytes)
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

    @Test("Anonymous activity logs retain only closed event values and no device-name text")
    func anonymousActivityLogSnapshot() {
        let events = [
            DiagnosticBreadcrumb(
                timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                event: AppDiagnosticEvent.connectionConnected.rawValue
            ),
            DiagnosticBreadcrumb(
                timestamp: Date(timeIntervalSince1970: 1_700_000_002),
                event: "Bob’s iPhone"
            ),
            DiagnosticBreadcrumb(
                timestamp: Date(timeIntervalSince1970: 1_700_000_003),
                event: AppDiagnosticEvent.liveViewStarted.rawValue
            ),
        ]

        let snapshot = DiagnosticEventStore.anonymousActivityLog(events: events)

        #expect(snapshot == ["connection.connected", "live-view.started"])
        #expect(!snapshot.joined(separator: " ").contains("Bob"))
        #expect(snapshot.allSatisfy { AppDiagnosticEvent(rawValue: $0) != nil })
    }

    @Test("Screenshot sanitizer re-renders a metadata-bearing image as a clean bounded PNG")
    func screenshotSanitizer() throws {
        let source = try pngWithDescription("Bob’s iPhone")
        let screenshot = try BugReportScreenshot(
            pngData: BugReportScreenshotSanitizer.sanitizedPNG(from: source)
        )

        #expect(screenshot.pngData.count <= BugReportAttachmentLimits.maximumScreenshotBytes)
        #expect(!String(decoding: screenshot.pngData, as: UTF8.self).contains("Bob’s iPhone"))

        let privacyMetadataChunkTypes: Set<String> = ["eXIf", "iTXt", "tEXt", "tIME", "zTXt"]
        let sanitizedChunkTypes = try pngChunkTypes(in: screenshot.pngData)
        #expect(sanitizedChunkTypes.isDisjoint(with: privacyMetadataChunkTypes))
    }

    @Test("Attachment reports use a fixed-length v2 multipart body with generic screenshot names")
    func attachmentRelayRequestContract() throws {
        let report = try validDraft().attachmentPayload(
            baseContext: context,
            activityLog: [AppDiagnosticEvent.connectionConnected.rawValue]
        )
        let screenshot = try BugReportScreenshot(
            pngData: BugReportScreenshotSanitizer.sanitizedPNG(
                from: try pngWithDescription("Bob’s iPhone")
            )
        )
        let submission = try BugReportSubmission(report: report, screenshots: [screenshot])
        let key = try #require(UUID(uuidString: "D7F1D858-ACFA-4AC2-9EA7-4D9E6A4CB7B6"))
        let request = try URLSessionBugReportSubmitter.makeMultipartRequest(
            submission,
            idempotencyKey: key,
            boundary: "OpenZCine-Test-Boundary"
        )

        #expect(request.url == SupportLinkCatalog.bugReportAttachmentsEndpoint)
        #expect(request.httpMethod == "POST")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
                == "multipart/form-data; boundary=OpenZCine-Test-Boundary"
        )
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)

        let body = try #require(request.httpBody)
        #expect(request.value(forHTTPHeaderField: "Content-Length") == String(body.count))
        #expect(body.count <= BugReportAttachmentLimits.maximumV2MultipartBodyBytes)
        let renderedBody = String(decoding: body, as: UTF8.self)
        #expect(renderedBody.contains("name=\"report\""))
        #expect(renderedBody.contains("filename=\"screenshot-1.png\""))
        #expect(!renderedBody.contains("Bob’s iPhone"))
        #expect(renderedBody.contains("connection.connected"))
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

        let oversizedDetails = String(repeating: "🧪", count: 3_500)
        #expect(oversizedDetails.count <= 4_000)
        #expect(Data(oversizedDetails.utf8).count > BugReportPayload.maximumJSONBodyBytes)
        draft = validDraft()
        draft.whatHappened = oversizedDetails
        #expect(throws: BugReportValidationError.bodyTooLarge) {
            try draft.payload(baseContext: context)
        }
        #expect(
            BugReportValidationError.bodyTooLarge.errorDescription
                == "This report is too large. Shorten what happened or the reproduction steps and try again."
        )
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
    @Test("Form explains when a camera Wi-Fi handoff cannot find internet")
    func formCameraAccessPointRouteFailure() {
        let form = BugReportFormModel(
            baseContext: context,
            submitter: TestBugReportSubmitter(result: .failure(.unavailable))
        )

        form.recordInternetRouteFailure()

        #expect(
            form.errorMessage
                == "OpenZCine couldn't reach the internet after leaving the camera's Wi-Fi. Check cellular or another Wi-Fi network and try again."
        )
        #expect(!form.isSubmitting)
    }

    @MainActor
    @Test("Form blocks an oversized aggregate JSON body before contacting the relay")
    func formAggregateSizeValidation() async throws {
        let submitter = RetryRecordingBugReportSubmitter()
        let form = BugReportFormModel(
            baseContext: context,
            submitter: submitter
        )
        form.draft = validDraft()
        await form.submit()
        let firstKey = try #require((await submitter.receivedKeys()).first)

        var draft = validDraft()
        draft.whatHappened = String(repeating: "🧪", count: 3_500)
        form.draft = draft

        await form.submit()

        #expect(form.receipt == nil)
        #expect(
            form.errorMessage
                == "This report is too large. Shorten what happened or the reproduction steps and try again."
        )
        let keysAfterOversizedDraft = await submitter.receivedKeys()
        #expect(keysAfterOversizedDraft.count == 1)

        form.draft = validDraft()
        await form.submit()

        let keys = await submitter.receivedKeys()
        #expect(keys.count == 2)
        #expect(keys.last == firstKey)
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

    @MainActor
    @Test("Retries retain attachment idempotency while attachment choices rotate it")
    func attachmentIdempotency() async throws {
        let submitter = AttachmentRecordingBugReportSubmitter()
        let form = BugReportFormModel(
            baseContext: context,
            submitter: submitter,
            activityLogProvider: TestActivityLogProvider(
                events: [AppDiagnosticEvent.connectionConnected.rawValue]
            )
        )
        form.draft = validDraft()
        form.includeActivityLog = true

        await form.submit()
        await form.submit()

        form.includeActivityLog = false
        await form.submit()

        form.includeScreenshots = true
        form.addScreenshotData(try pngWithDescription("Bob’s iPhone"))
        await form.submit()

        let keys = await submitter.receivedKeys()
        let submissions = await submitter.receivedSubmissions()
        #expect(keys.count == 4)
        #expect(keys[0] == keys[1])
        #expect(keys[1] != keys[2])
        #expect(keys[2] != keys[3])
        #expect(submissions.map(\.report.schemaVersion) == [2, 2, 1, 2])
        #expect(submissions[0].report.activityLog == ["connection.connected"])
        #expect(submissions[3].screenshots.count == 1)
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

    private func pngWithDescription(_ description: String) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw TestImageError.unavailable
        }
        let bitmapInfo =
            CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let context = CGContext(
                data: nil,
                width: 80,
                height: 40,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        else {
            throw TestImageError.unavailable
        }
        context.setFillColor(red: 0.15, green: 0.5, blue: 0.85, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        guard let image = context.makeImage() else { throw TestImageError.unavailable }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw TestImageError.unavailable
        }
        let metadata: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description]
        ]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestImageError.unavailable }
        return output as Data
    }

    private func pngChunkTypes(in data: Data) throws -> Set<String> {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard data.starts(with: signature) else { throw TestImageError.invalidPNG }

        var chunkTypes = Set<String>()
        var offset = signature.count
        while offset < data.count {
            guard data.count - offset >= 12 else { throw TestImageError.invalidPNG }

            let payloadLength = (0..<4).reduce(0) { partialResult, index in
                (partialResult << 8) | Int(data[offset + index])
            }
            let typeStart = offset + 4
            let payloadStart = offset + 8
            let nextChunkOffset = payloadStart + payloadLength + 4
            guard
                nextChunkOffset <= data.count,
                let chunkType = String(data: data[typeStart..<payloadStart], encoding: .ascii)
            else {
                throw TestImageError.invalidPNG
            }

            chunkTypes.insert(chunkType)
            offset = nextChunkOffset
        }
        return chunkTypes
    }
}

private enum TestImageError: Error {
    case unavailable
    case invalidPNG
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

private struct TestActivityLogProvider: BugReportActivityLogProviding {
    let events: [String]

    func activityLog() async -> [String] {
        events
    }
}

private actor AttachmentRecordingBugReportSubmitter: BugReportSubmitting {
    private var keys: [UUID] = []
    private var submissions: [BugReportSubmission] = []

    func submit(
        _ report: BugReportPayload,
        idempotencyKey: UUID
    ) async throws -> BugReportSubmissionReceipt {
        try await submit(BugReportSubmission(report: report), idempotencyKey: idempotencyKey)
    }

    func submit(
        _ submission: BugReportSubmission,
        idempotencyKey: UUID
    ) async throws -> BugReportSubmissionReceipt {
        keys.append(idempotencyKey)
        submissions.append(submission)
        return .empty
    }

    func receivedKeys() -> [UUID] {
        keys
    }

    func receivedSubmissions() -> [BugReportSubmission] {
        submissions
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
