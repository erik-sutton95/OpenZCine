import Foundation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineHostedAccessibility
import OpenCineMedia
import OpenZCineCore
import SwiftUI
import UIKit
import XCTest

@testable import Runner

/// SIMULATED files exercise the actual app gallery, source retirement and rendered Close.
/// Four-byte files do not prove decoded video, photos or physical camera behavior.
@MainActor final class NikonMediaOpeningAdmissionTests: XCTestCase {
    func testRetiredVideoCloseReturnsToActualGallery() async throws {
        try await retired(photo: false)
    }
    func testRetiredPhotoCloseReturnsToActualGallery() async throws {
        try await retired(photo: true)
    }

    func testActualBurstCoverKeepsNormalCompanionAndZeroDeletionProgressAboveThePhoto() async throws
    {
        let fixture = try await NikonOpeningFixture(photo: true, burst: true)
        addTeardownBlock { @MainActor in await fixture.close() }
        let record = try XCTUnwrap(
            fixture.library.records.first { $0.payload.filename == "DSC_0001.JPG" })
        let cell = try await fixture.element("monitor.media.clip." + record.asset.id.rawValue)
        XCTAssertTrue(cell.accessibilityActivate(), "Open the actual burst representative")
        _ = try await fixture.element("monitor.photo.back")
        let members = fixture.model.burstMembers(of: record.payload)
        XCTAssertEqual(members.count, 3, "The actual series cover must retain all frames")
        // Frame identity, not the whole record: EXIF orientation can arrive after the cover opens.
        func frames(_ clips: [MediaClip]) -> [String] {
            clips.map { $0.cameraID + "/" + $0.filename }
        }
        for (completed, total, selected, title, detail) in [
            (0, 1, 1, "Deleting 1 item…", "0 of 1"),
            (2, 3, 3, "Deleting 3 items…", "2 of 3"),
            (2, 6, 3, "Deleting 3 items…", "2 of 6 files · incl. RAW + copies"),
            (0, 0, 3, "Deleting 3 items…", "0 of 0"),
        ] {
            fixture.model.mediaDeletionProgress = .init(
                completed: completed, total: total, selectedCount: selected)
            let visible = await fixture.wait {
                let cover = fixture.host.presentedViewController
                guard let cover else { return false }
                let labels = HostedAccessibility.elements(in: cover.view).compactMap(
                    \.accessibilityLabel)
                return labels.contains(title) && labels.contains(detail)
            }
            XCTAssertTrue(visible, "The actual burst cover must show " + title + " / " + detail)
            fixture.capture(
                self, name: "SIMULATED-Z-burst-progress-\(completed)-\(total)-\(selected)")
            XCTAssertTrue(fixture.model.mediaLibrary === fixture.library)
            XCTAssertEqual(frames(fixture.model.burstMembers(of: record.payload)), frames(members))
            for member in members {
                XCTAssertTrue(
                    fixture.model.mediaClipStore.isDownloaded(
                        cameraID: member.cameraID, filename: member.filename))
            }
        }
        fixture.model.mediaDeletionProgress = nil
        let cleared = await fixture.wait {
            !HostedAccessibility.elements(in: fixture.window).contains {
                $0.accessibilityLabel?.hasPrefix("Deleting ") == true
            }
        }
        XCTAssertTrue(cleared, "Clearing progress must reveal the retained series")
        _ = try await fixture.element("monitor.photo.back")
    }

    private func retired(photo: Bool) async throws {
        let fixture = try await NikonOpeningFixture(photo: photo)
        addTeardownBlock { @MainActor in await fixture.close() }
        let record = try XCTUnwrap(fixture.library.records.first)
        let admission = fixture.library.actionToken
        let cellID = "monitor.media.clip." + record.asset.id.rawValue
        let cell = try await fixture.element(cellID)
        XCTAssertTrue(cell.accessibilityActivate(), "Tap the actual app gallery cell")
        let presented = await fixture.wait {
            fixture.host.presentedViewController?.viewIfLoaded?.window != nil
        }
        XCTAssertTrue(presented)
        _ = try await fixture.element(photo ? "monitor.photo.back" : "monitor.playback.back")
        fixture.library.close()
        XCTAssertFalse(fixture.library.isCurrent(admission))
        _ = try await fixture.element("monitor.media.unavailable")
        let close = try await fixture.element("monitor.media.unavailable.close")
        fixture.capture(
            self, name: "SIMULATED-Z-" + (photo ? "photo" : "video") + "-retired-unavailable")
        XCTAssertTrue(close.accessibilityTraits.contains(.button))
        XCTAssertGreaterThanOrEqual(close.accessibilityFrame.width, 44)
        XCTAssertGreaterThanOrEqual(close.accessibilityFrame.height, 44)
        XCTAssertTrue(close.accessibilityActivate(), "Activate the real rendered Close")
        let returned = await fixture.wait { fixture.host.presentedViewController == nil }
        XCTAssertTrue(returned, "Close must return to the actual Z gallery after source retirement")
        _ = try await fixture.element(cellID)
    }
}

@MainActor private final class NikonOpeningFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SIMULATED-S02-Z-" + UUID().uuidString)
    let model: NativeAppModel
    let library: MonitorMediaLibraryModel<MediaClip>
    let delivery: MonitorDeliveryCoordinator
    let window: UIWindow
    let host: UIHostingController<AnyView>
    private weak var previous: UIWindow?

    init(photo: Bool, burst: Bool = false) async throws {
        let active = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    UIApplication.shared.connectedScenes.contains {
                        $0.activationState == .foregroundActive
                    }
                }
            }, object: nil)
        let activated = await XCTWaiter.fulfillment(of: [active], timeout: 5)
        XCTAssertEqual(activated, .completed, "The actual app host must have a foreground scene")
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        if burst {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            let landscape = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        scene.interfaceOrientation.isLandscape
                            && scene.coordinateSpace.bounds.width
                                > scene.coordinateSpace.bounds.height
                    }
                }, object: nil)
            let rotated = await XCTWaiter.fulfillment(of: [landscape], timeout: 5)
            XCTAssertEqual(
                rotated, .completed, "The actual burst cover is verified in landscape first")
        }
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        model.mediaCategoryTab = .all
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
            context.cgContext.setFillColor(UIColor.darkGray.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let bytes =
            burst ? try XCTUnwrap(image.jpegData(compressionQuality: 0.8)) : Data([1, 2, 3, 4])
        let clips: [MediaClip] = (0..<(burst ? 3 : 1)).map { index in
            let filename =
                burst
                ? String(format: "DSC_%04d.JPG", index + 1)
                : (photo ? "SIMULATED-CAPTURED.JPG" : "SIMULATED-CAPTURED.MOV")
            return MediaClip(
                cameraID: MediaClipStore.localBucketID, filename: filename,
                handle: burst ? UInt32(index + 1) : nil, storageID: burst ? 65_537 : nil,
                sizeBytes: UInt64(bytes.count),
                captureDate: String(format: "20261013T12000%d", index),
                pixelWidth: burst ? 6048 : nil, pixelHeight: burst ? 4000 : nil)
        }
        store.upsertBatch(clips, cameraID: MediaClipStore.localBucketID)
        for clip in clips {
            let file = try store.localURL(cameraID: clip.cameraID, filename: clip.filename)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        model.refreshMediaClips()
        let library = try XCTUnwrap(model.mediaLibrary)
        library.begin()
        let delivery = MonitorDeliveryCoordinator(
            exports: MonitorDeliveryExportStore(
                root: root.appendingPathComponent("exports")))
        self.model = model
        self.library = library
        self.delivery = delivery
        previous = scene.keyWindow
        host = UIHostingController(
            rootView: AnyView(MediaBrowserView().environment(model).environment(delivery)))
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }

    /// Polls every 50 ms for up to 5 s. `XCTNSPredicateExpectation` samples about once a second,
    /// so on a loaded hosted runner a 5 s wait saw only a few layouts (OpenCine #18).
    func wait(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            host.view.layoutIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        host.view.layoutIfNeeded()
        return condition()
    }
    func element(_ id: String) async throws -> NSObject {
        let found = await wait {
            HostedAccessibility.elements(in: self.window).contains {
                HostedAccessibility.identifier($0) == id
            }
        }
        XCTAssertTrue(found, "The actual rendered element must be present: " + id)
        return try XCTUnwrap(
            HostedAccessibility.elements(in: window).first {
                HostedAccessibility.identifier($0) == id
            })
    }
    func capture(_ test: XCTestCase, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
    func close() async {
        host.dismiss(animated: false)
        _ = await wait { self.host.presentedViewController == nil }
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
        delivery.close()
        await library.dispose()
        try? FileManager.default.removeItem(at: root)
    }
}
