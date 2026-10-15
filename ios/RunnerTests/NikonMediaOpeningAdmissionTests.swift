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

    init(photo: Bool) async throws {
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
        let store = MediaClipStore(root: root)
        let model = NativeAppModel(mediaClipStore: store)
        model.mediaBrowserSource = .iPhone
        model.mediaCategoryTab = .all
        let filename = photo ? "SIMULATED-CAPTURED.JPG" : "SIMULATED-CAPTURED.MOV"
        let clip = MediaClip(
            cameraID: MediaClipStore.localBucketID, filename: filename,
            handle: nil, storageID: nil, sizeBytes: 4, captureDate: "20261013T120000")
        store.upsertBatch([clip], cameraID: clip.cameraID)
        let file = try store.localURL(cameraID: clip.cameraID, filename: filename)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: file)
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

    func wait(_ condition: @escaping () -> Bool) async -> Bool {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { [self] _, _ in
                MainActor.assumeIsolated {
                    host.view.layoutIfNeeded()
                    return condition()
                }
            }, object: nil)
        return await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed
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
