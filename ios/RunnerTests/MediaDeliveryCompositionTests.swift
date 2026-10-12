import AVFoundation
import CoreVideo
import MonitorPresentation
import MonitorUI
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

@testable import Runner

/// SIMULATED native composition. These actions do not run an exporter or a network hop.
final class MediaDeliveryCompositionTests: XCTestCase {
    @MainActor
    func testActualPopupPreservesNativeOptionsRequestAndDismissal() async throws {
        let model = NativeAppModel()
        let movie = try await supportedMovie(in: model.mediaClipStore)
        defer { restore(movie) }
        XCTAssertTrue(model.isClipDownloaded(movie.clip))
        let uncached = MediaClip(
            cameraID: movie.clip.cameraID, filename: "SIMULATED-UNCACHED.MOV", handle: 2,
            storageID: 65_537, sizeBytes: movie.clip.sizeBytes, captureDate: "")
        XCTAssertFalse(model.isClipDownloaded(uncached))

        for size in geometries {
            var requests: [MediaDeliveryBeginRequest] = []
            var closes = 0
            let host = UIHostingController(
                rootView: AnyView(
                    MediaDeliveryPopup(
                        clip: movie.clip, maxCardHeight: size.height - 48,
                        onBeginDelivery: { requests.append($0) }, onClose: { closes += 1 }
                    ).environment(model).padding(20)))
            let (window, originalKeyWindow) = try mount(host, size: size)
            defer { retire(window, restoring: originalKeyWindow) }
            try await activate(identifier: "monitor.share.destination.nativeShare", in: host)
            let back = try await element(identifier: "monitor.share.back", in: host, button: true)
            XCTAssertTrue(contained(back, in: window))
            let format = try await element(label: "MP4", in: host, button: true, scroll: true)
            XCTAssertTrue(format.accessibilityActivate())
            XCTAssertTrue(
                HostedAccessibility.elements(in: host.view).contains {
                    $0.accessibilityLabel == "Include metadata"
                })
            let save = try await element(label: "Save to Photos", in: host, button: true)
            XCTAssertTrue(save.accessibilityActivate())
            let begin = try await element(identifier: "monitor.share.begin", in: host, button: true)
            XCTAssertTrue(contained(begin, in: window))
            capture(
                host, "SIMULATED-actual-delivery-options-\(Int(size.width))x\(Int(size.height))")
            XCTAssertTrue(begin.accessibilityActivate())
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.clips.map(\.id), [movie.clip.id])
            XCTAssertEqual(request.destination, .nativeShare)
            XCTAssertEqual(request.configuration.exportFormat, .mp4)
            XCTAssertTrue(request.configuration.includeMetadata)
            XCTAssertEqual(request.configuration.bakeLUT, model.currentLUTCube() != nil)
            XCTAssertEqual(request.postExportAction, .saveToPhotos)
            XCTAssertEqual(closes, 1)

            host.rootView = AnyView(
                MediaDeliveryPopup(
                    clip: uncached, preferredDestination: .nativeShare,
                    maxCardHeight: size.height - 48,
                    onBeginDelivery: { requests.append($0) }, onClose: { closes += 1 }
                ).environment(model).padding(20))
            let refused = try await element(
                identifier: "monitor.share.begin", in: host, button: true)
            XCTAssertTrue(refused.accessibilityTraits.contains(.notEnabled))
            XCTAssertEqual(requests.count, 1)
            try await activate(identifier: "monitor.share.back", in: host)
            _ = try await element(
                identifier: "monitor.share.destination.nativeShare", in: host, button: true)
            try await activate(identifier: "monitor.share.close", in: host)
            XCTAssertEqual(closes, 2)
            XCTAssertEqual(requests.count, 1)
            capture(host, "SIMULATED-actual-delivery-return-\(Int(size.width))x\(Int(size.height))")
        }
    }

    @MainActor
    func testActualExpandedAndCommonCompactKeepIndependentProgressActions() async throws {
        let states = [
            MediaDeliveryOverlayState(
                destination: .nativeShare, totalClips: 1, clipIndex: 1, clipFraction: 0),
            MediaDeliveryOverlayState(
                destination: .nativeShare, totalClips: 2, clipIndex: 2, clipFraction: 0),
            MediaDeliveryOverlayState(
                destination: .nativeShare, totalClips: 1, clipIndex: 1, clipFraction: 0.5),
            MediaDeliveryOverlayState(
                destination: .nativeShare, totalClips: 1, clipIndex: 1, clipFraction: 1),
            MediaDeliveryOverlayState(
                destination: .nativeShare, totalClips: 2, clipIndex: 2, clipFraction: 0.75,
                postExportAction: .saveToPhotos, phase: .awaitingPhotosAccess),
            MediaDeliveryOverlayState(
                destination: .nativeShare, totalClips: 2, clipIndex: 2, clipFraction: 0.75,
                postExportAction: .saveToPhotos, phase: .savingToPhotos),
            MediaDeliveryOverlayState(
                destination: .frameio, totalClips: 1, clipIndex: 1, clipFraction: 0.4,
                isSwitchingNetworks: true),
        ]
        for size in geometries {
            var cancels = 0
            var expands = 0
            var collapses = 0
            let host = UIHostingController(rootView: AnyView(Color.clear))
            let (window, originalKeyWindow) = try mount(host, size: size)
            defer { retire(window, restoring: originalKeyWindow) }
            for (index, state) in states.enumerated() {
                host.rootView = AnyView(
                    MediaDeliveryOverlay(state: state, onCancel: { cancels += 1 }).padding(20))
                _ = try await element(label: state.statusLine, in: host)
                let cancel = try await element(label: "Cancel", in: host, button: true)
                XCTAssertTrue(contained(cancel, in: window))
                XCTAssertTrue(cancel.accessibilityActivate())
                XCTAssertEqual(cancels, index + 1)
                capture(
                    host,
                    "SIMULATED-actual-expanded-phase\(index)-\(Int(size.width))x\(Int(size.height))"
                )
            }

            // A known zero overall fraction with showsProgress=true is a supplied UI fact.
            // Actual app preparing state hides its bar; this common-only case checks the default.
            let zero = MonitorMediaDeliveryProgressValue(
                status: "SIMULATED known zero", fraction: 0, preparing: false)
            host.rootView = AnyView(
                MonitorMediaDeliveryProgress(
                    value: zero, onCancel: { cancels += 1 }, onExpand: { expands += 1 },
                    destinationIcon: { EmptyView() }
                ).frame(maxWidth: 420).padding(20))
            let expand = try await element(
                identifier: "monitor.share.progress.expand", in: host, button: true)
            XCTAssertTrue(contained(expand, in: window))
            capture(host, "SIMULATED-common-compact-zero-\(Int(size.width))x\(Int(size.height))")
            XCTAssertTrue(expand.accessibilityActivate())
            XCTAssertEqual(expands, 1)
            XCTAssertEqual(cancels, states.count)

            host.rootView = AnyView(
                MonitorMediaDeliveryProgressPanel(
                    value: zero,
                    details: .init(filename: "SIMULATED.MOV", destination: "SIMULATED destination"),
                    onCancel: { cancels += 1 }, onCollapse: { collapses += 1 },
                    destinationIcon: { EmptyView() }
                ).frame(maxWidth: 420).padding(20))
            _ = try await element(label: "SIMULATED.MOV", in: host)
            _ = try await element(label: "Destination: SIMULATED destination", in: host)
            capture(
                host, "SIMULATED-common-expanded-details-\(Int(size.width))x\(Int(size.height))")
            try await activate(identifier: "monitor.share.progress.collapse", in: host)
            XCTAssertEqual(collapses, 1)
            XCTAssertEqual(cancels, states.count)
            try await activate(label: "Cancel", in: host)
            XCTAssertEqual(cancels, states.count + 1)

            host.rootView = AnyView(
                MonitorMediaDeliveryProgressPanel(value: zero, destinationIcon: { EmptyView() })
                    .frame(maxWidth: 420).padding(20))
            _ = try await element(label: zero.status, in: host)
            let labels = Set(
                HostedAccessibility.elements(in: host.view).compactMap(\.accessibilityLabel))
            XCTAssertFalse(labels.contains("SIMULATED.MOV"))
            XCTAssertFalse(labels.contains("Destination: SIMULATED destination"))
            XCTAssertFalse(labels.contains("Collapse"))
            XCTAssertFalse(labels.contains("Cancel"))
            capture(
                host,
                "SIMULATED-common-expanded-absent-details-\(Int(size.width))x\(Int(size.height))")
        }
    }

    private var geometries: [CGSize] {
        [CGSize(width: 402, height: 874), CGSize(width: 874, height: 402)]
    }

    @MainActor
    private func mount(_ host: UIViewController, size: CGSize) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = UIColor(MonitorTheme.background)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.size, size)
        return (window, originalKeyWindow)
    }

    @MainActor
    private func retire(_ window: UIWindow, restoring originalKeyWindow: UIWindow?) {
        window.isHidden = true
        window.rootViewController = nil
        originalKeyWindow?.makeKeyAndVisible()
    }

    @MainActor
    private func capture(_ host: UIViewController, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func contained(_ object: NSObject, in window: UIWindow) -> Bool {
        let frame = object.accessibilityFrame
        return frame.width > 0 && frame.height > 0 && window.bounds.contains(frame)
    }

    @MainActor
    private func activate(
        label: String? = nil, identifier: String? = nil, in host: UIViewController
    ) async throws {
        let current = try await element(
            label: label, identifier: identifier, in: host, button: true)
        XCTAssertTrue(current.accessibilityActivate())
    }

    @MainActor
    private func element(
        label: String? = nil, identifier: String? = nil, in host: UIViewController,
        button: Bool = false, scroll: Bool = false
    ) async throws -> NSObject {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            host.view.layoutIfNeeded()
            await Task.yield()
            let matches = HostedAccessibility.elements(in: host.view).filter { object in
                (label == nil || object.accessibilityLabel == label)
                    && (identifier == nil || publicIdentifier(of: object) == identifier)
                    && (!button || object.accessibilityTraits.contains(.button))
                    && object.accessibilityFrame.width > 0 && object.accessibilityFrame.height > 0
                    && object.isAccessibilityElement
            }
            if matches.count == 1, let object = matches.first, let window = host.view.window {
                if contained(object, in: window) {
                    if let identifier {
                        let attachment = XCTAttachment(
                            string:
                                "SIMULATED matched requested identifier \(identifier); returned public identifier \(publicIdentifier(of: object) ?? "unknown")"
                        )
                        attachment.name = "SIMULATED-delivery-matched-public-identifier"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                    return object
                }
                if scroll,
                    let viewport = HostedAccessibility.elements(in: host.view)
                        .compactMap({ $0 as? UIScrollView })
                        .first(where: {
                            $0.contentSize.height > $0.bounds.height && !$0.isHidden
                        })
                {
                    viewport.scrollRectToVisible(
                        viewport.convert(object.accessibilityFrame, from: nil), animated: false)
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        captureFailure(label: label, identifier: identifier, button: button, in: host)
        XCTFail(
            "SIMULATED delivery native control unavailable or ambiguous: \(label ?? identifier ?? "unknown")"
        )
        throw NSError(domain: "MediaDeliveryCompositionTests", code: 1)
    }

    /// Reads the public UIKit string getter without requiring framework nodes' formal conformance.
    @MainActor
    private func publicIdentifier(of object: NSObject) -> String? {
        let getter = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: getter) else { return nil }
        return object.perform(getter)?.takeUnretainedValue() as? String
    }

    @MainActor
    private func captureFailure(
        label: String?, identifier: String?, button: Bool, in host: UIViewController
    ) {
        let started = ProcessInfo.processInfo.systemUptime
        let window = host.view.window
        let identifierGetter = NSSelectorFromString("accessibilityIdentifier")
        var candidates = 0
        let rows: [[String: Any]] = HostedAccessibility.elements(in: host.view).map { object in
            let supportsIdentifierGetter = object.responds(to: identifierGetter)
            let identification = object as? UIAccessibilityIdentification
            let actualIdentifier = publicIdentifier(of: object)
            let frame = object.accessibilityFrame
            let labelMatches = label == nil || object.accessibilityLabel == label
            let identifierMatches = identifier == nil || actualIdentifier == identifier
            let buttonMatches = !button || object.accessibilityTraits.contains(.button)
            let positiveFrame = frame.width > 0 && frame.height > 0
            let exposedElement = object.isAccessibilityElement
            let matches =
                labelMatches && identifierMatches && buttonMatches
                && positiveFrame && exposedElement
            if matches { candidates += 1 }
            var rejected: [String] = []
            if !labelMatches { rejected.append("label") }
            if !identifierMatches { rejected.append("identifier") }
            if !buttonMatches { rejected.append("buttonTrait") }
            if !positiveFrame { rejected.append("positiveFrame") }
            if !exposedElement { rejected.append("isAccessibilityElement") }
            let inWindow = window.map { contained(object, in: $0) }
            if inWindow == false { rejected.append("windowContainment") }
            return [
                "class": NSStringFromClass(type(of: object)),
                "objectIdentity": String(describing: ObjectIdentifier(object)),
                "publicSuperviewIdentity": (object as? UIView)?.superview.map {
                    String(describing: ObjectIdentifier($0))
                } as Any? ?? NSNull(),
                "publicAccessibilityContainerIdentity":
                    ((object as? UIAccessibilityElement)?.accessibilityContainer as? NSObject).map {
                        String(describing: ObjectIdentifier($0))
                    } as Any? ?? NSNull(),
                "label": object.accessibilityLabel as Any? ?? NSNull(),
                "identifierGetterSupported": supportsIdentifierGetter,
                "identifierProtocolConformance": identification != nil,
                "identifier": actualIdentifier as Any? ?? NSNull(),
                "buttonTrait": object.accessibilityTraits.contains(.button),
                "isAccessibilityElement": exposedElement,
                "frame": NSCoder.string(for: frame),
                "containedInHostWindow": inWindow as Any? ?? NSNull(),
                "originalMatcherEligible": matches,
                "rejectedBy": rejected,
            ]
        }
        let report: [String: Any] = [
            "scenario": "SIMULATED unchanged delivery lookup failed after original five seconds",
            "requestedLabel": label as Any? ?? NSNull(),
            "requestedIdentifier": identifier as Any? ?? NSNull(),
            "requiresButton": button,
            "snapshotStartedUptime": started,
            "snapshotCompletedUptime": ProcessInfo.processInfo.systemUptime,
            "hostBounds": NSCoder.string(for: host.view.bounds),
            "windowBounds": window.map { NSCoder.string(for: $0.bounds) } as Any? ?? NSNull(),
            "hostAttachedToWindow": window != nil,
            "windowIsKey": window?.isKeyWindow as Any? ?? NSNull(),
            "candidateCount": candidates,
            "objects": rows,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            let attachment = XCTAttachment(string: text)
            attachment.name = "SIMULATED-delivery-failure-public-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture(host, "SIMULATED-delivery-failure-current-host")
    }

    private struct MovieFixture {
        let clip: MediaClip
        let bucket: URL
        let root: URL
        let rootExisted: Bool
    }

    @MainActor
    private func supportedMovie(in store: MediaClipStore) async throws -> MovieFixture {
        let cameraID = "SIMULATED-delivery-\(UUID().uuidString)"
        let bucket = store.directory(for: cameraID)
        guard !FileManager.default.fileExists(atPath: bucket.path) else {
            throw NSError(domain: "MediaDeliveryCompositionTests", code: 2)
        }
        let rootExisted = FileManager.default.fileExists(atPath: store.root.path)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        let url = try store.localURL(cameraID: cameraID, filename: "SIMULATED.MOV")
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16,
                    AVVideoHeightKey: 16,
                ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16,
                ])
            XCTAssertTrue(writer.canAdd(input))
            writer.add(input)
            XCTAssertTrue(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !input.isReadyForMoreMediaData && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(
                CVPixelBufferCreate(
                    kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer),
                kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            if let address = CVPixelBufferGetBaseAddress(pixel) {
                memset(address, 0x80, CVPixelBufferGetDataSize(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: .zero))
            while !input.isReadyForMoreMediaData && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(
                adaptor.append(pixel, withPresentationTime: CMTime(value: 1, timescale: 25)))
            writer.endSession(atSourceTime: CMTime(value: 2, timescale: 25))
            input.markAsFinished()
            // Explicit documented callback, not the imported async completion thunk.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            XCTAssertEqual(writer.status, .completed)
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertFalse(videoTracks.isEmpty)
            let duration = try await asset.load(.duration)
            XCTAssertTrue(duration.seconds.isFinite && duration.seconds > 0)
            let size = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            ).uint64Value
            XCTAssertGreaterThan(size, 0)
            XCTAssertLessThan(size, 100_000)
            return MovieFixture(
                clip: MediaClip(
                    cameraID: cameraID, filename: "SIMULATED.MOV", handle: 1, storageID: 65_537,
                    sizeBytes: size, captureDate: ""),
                bucket: bucket, root: store.root, rootExisted: rootExisted)
        } catch {
            try? FileManager.default.removeItem(at: bucket)
            if !rootExisted,
                (try? FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
                    == true
            {
                try? FileManager.default.removeItem(at: store.root)
            }
            throw error
        }
    }

    private func restore(_ movie: MovieFixture) {
        do {
            try FileManager.default.removeItem(at: movie.bucket)
            XCTAssertFalse(FileManager.default.fileExists(atPath: movie.bucket.path))
            if !movie.rootExisted {
                let empty = try FileManager.default.contentsOfDirectory(atPath: movie.root.path)
                    .isEmpty
                XCTAssertTrue(empty)
                if empty { try FileManager.default.removeItem(at: movie.root) }
            }
        } catch {
            XCTFail("SIMULATED delivery bucket restoration failed: \(error)")
        }
    }
}
