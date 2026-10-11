import CoreImage
import MetalKit
import MonitorPresentation
import MonitorUI
import Network
import Observation
import OpenCineApple
import OpenCineCameraControls
import OpenCineCore
import OpenCineMedia
import SwiftUI
import Testing
import UIKit
import XCTest

@testable import OpenZCineCore
@testable import Runner

final class RunnerTests: XCTestCase {

    @MainActor
    func testDefaultSharedMediaFilterFormKeepsNativeCalendarColourAndClear() async throws {
        let state = NativeDefaultFilterFixture()
        // The real form is rebuilt from observed choices after each native accessibility action.
        let content = NativeDefaultFilterFixtureView(state: state)
        let host = UIHostingController(rootView: content)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKeyAndVisible()
        }
        for size in [CGSize(width: 874, height: 402), CGSize(width: 402, height: 874)] {
            state.formats = []
            state.colours = []
            state.picks = []
            window.frame.size = size
            host.view.frame.size = size
            let start = try await nativeFilterElement("Start", host: host)
            let end = try await nativeFilterElement("End", host: host)
            XCTAssertEqual(start.accessibilityValue, "Any")
            XCTAssertEqual(end.accessibilityValue, "Any")
            let labels = Set(nativeFilterElements(host.view).compactMap(\.accessibilityLabel))
            XCTAssertFalse(labels.contains("SIZE"))
            XCTAssertFalse(labels.contains("STORAGE"))
            XCTAssertFalse(labels.contains("TODAY"))
            XCTAssertTrue(start.accessibilityActivate())
            XCTAssertTrue(end.accessibilityActivate())
            XCTAssertEqual(state.picks, ["start", "end"])
            let mov = try await nativeFilterElement("MOV", host: host)
            XCTAssertTrue(mov.accessibilityActivate())
            XCTAssertEqual(state.formats, ["MOV"])
            let log = try await nativeFilterElement("LOG", host: host)
            XCTAssertTrue(log.accessibilityActivate())
            XCTAssertEqual(state.colours, [9])
            let clear = try await nativeFilterElement("Clear all filters", host: host)
            XCTAssertTrue(clear.accessibilityActivate())
            XCTAssertTrue(state.formats.isEmpty && state.colours.isEmpty)
            let attachment = XCTAttachment(
                image: UIGraphicsImageRenderer(size: size).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                })
            attachment.name = "SIMULATED-default-filter-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func nativeFilterElements(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let count = object.accessibilityElementCount()
            if count > 0 && count < 256 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject {
                        visit(child)
                    }
                }
            }
            if let view = object as? UIView {
                for child in view.subviews { visit(child) }
            }
        }
        visit(root)
        return result
    }

    @MainActor
    private func nativeFilterElement(_ label: String, host: UIViewController) async throws
        -> NSObject
    {
        for _ in 0..<200 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
            if let element = nativeFilterElements(host.view).first(where: {
                $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
            }) {
                return element
            }
        }
        XCTFail("Default common form did not expose its native \(label) button")
        return try XCTUnwrap(
            nativeFilterElements(host.view).first { $0.accessibilityLabel == label })
    }

    @MainActor
    func testActualMediaFilterAdapterUsesOfferedMetadataAndComposesTypedSelections() throws {
        // SIMULATED listed metadata, without a camera session or any file/store writes.
        let model = NativeAppModel()
        model.connection = .connected
        model.mediaCategoryTab = .all
        let today = filterCaptureDate(daysAgo: 0)
        let old = filterCaptureDate(daysAgo: 90)
        model.mediaClips = [
            filterClip("A.MOV", width: 1920, date: today),
            filterClip("B.MP4", width: 3840, date: old),
            filterClip("L.JPG", width: 6048, date: today),
            filterClip("M.TIF", width: 4032, date: old),
        ]
        var form = MonitorMediaFilterForm(
            presentation: model.mediaGalleryPresentation(model.mediaGalleryProjection),
            onAction: model.applyMediaGalleryFilter)
        XCTAssertFalse(form.hasDates)
        XCTAssertTrue(form.colors.isEmpty)
        form.onToggleFormat("JPEG")
        form.onToggleFormat("TIFF")
        XCTAssertEqual(Set(model.filteredMediaClips.map(\.filename)), ["L.JPG", "M.TIF"])
        try XCTUnwrap(form.photoSizes).onToggle("L")
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["L.JPG"])
        try XCTUnwrap(form.photoSizes).onToggle("M")
        XCTAssertEqual(Set(model.filteredMediaClips.map(\.filename)), ["L.JPG", "M.TIF"])
        try XCTUnwrap(form.dateWindows).onToggle("TODAY")
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["L.JPG"])
        try XCTUnwrap(form.dateWindows).onToggle("7 DAYS")
        XCTAssertEqual(model.mediaDateWindow, .last7Days)
        try XCTUnwrap(form.dateWindows).onToggle("7 DAYS")
        XCTAssertNil(model.mediaDateWindow)
        let selected = model.mediaActiveFilterCount
        form.onToggleFormat("not-offered")
        try XCTUnwrap(form.photoSizes).onToggle("not-offered")
        try XCTUnwrap(form.dateWindows).onToggle("not-offered")
        XCTAssertEqual(model.mediaActiveFilterCount, selected)
        XCTAssertEqual(Set(model.filteredMediaClips.map(\.filename)), ["L.JPG", "M.TIF"])
        model.mediaCategoryTab = .videos
        XCTAssertTrue(model.mediaFormatFilters.isEmpty)
        XCTAssertTrue(model.mediaPhotoSizeFilters.isEmpty)
        form = MonitorMediaFilterForm(
            presentation: model.mediaGalleryPresentation(model.mediaGalleryProjection),
            onAction: model.applyMediaGalleryFilter)
        XCTAssertNil(form.photoSizes)
        form.onToggleFormat("MOV")
        form.onToggleFormat("MP4")
        form.onToggleResolution("HD")
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["A.MOV"])
        form.onToggleResolution("4K")
        XCTAssertEqual(Set(model.filteredMediaClips.map(\.filename)), ["A.MOV", "B.MP4"])
        // An incoming partial listing must not erase a freshly selected chip.
        model.mediaClips.removeAll { $0.filename == "A.MOV" }
        XCTAssertEqual(model.mediaFormatFilters, [.mov, .mp4])
        XCTAssertEqual(model.mediaResolutionFilters, [.hd, .fourK])
        form.onClear()
        XCTAssertEqual(model.mediaActiveFilterCount, 0)
        XCTAssertEqual(model.mediaCategoryTab, .videos)
    }

    @MainActor
    func testActualMediaFilterAdapterPreservesCardIdentityBackupsAndHiddenActiveClear() throws {
        let model = NativeAppModel()
        model.connection = .connected
        model.mediaCategoryTab = .all
        let first: UInt32 = 0xF001_0001
        let second: UInt32 = 0xF002_0001
        model.mediaStorageSlots = [
            MediaStorageSlotDisplay(
                storageID: first, slotNumber: 3, cameraName: "SIMULATED", usedGigabytes: 0,
                freeGigabytes: 1, totalGigabytes: 1),
            MediaStorageSlotDisplay(
                storageID: second, slotNumber: 7, cameraName: "SIMULATED", usedGigabytes: 0,
                freeGigabytes: 1, totalGigabytes: 1),
        ]
        var backup = filterClip("BACKUP.MOV", width: 1920, date: filterCaptureDate(daysAgo: 0))
        backup.storageID = first
        backup.storageLocations = [
            MediaObjectHandle(storageID: first, handle: 1),
            MediaObjectHandle(storageID: second, handle: 2),
        ]
        var single = filterClip("PRIMARY.MOV", width: 1920, date: filterCaptureDate(daysAgo: 90))
        single.storageID = first
        model.mediaClips = [backup, single]
        let form = MonitorMediaFilterForm(
            presentation: model.mediaGalleryPresentation(model.mediaGalleryProjection),
            onAction: model.applyMediaGalleryFilter)
        let storage = try XCTUnwrap(form.storage)
        XCTAssertEqual(storage.options.map(\.label), ["SLOT 3", "SLOT 7"])
        storage.onToggle(String(second))
        XCTAssertEqual(model.mediaStorageSlotFilter, second)
        XCTAssertEqual(model.filteredMediaClips.map(\.filename), ["BACKUP.MOV"])
        storage.onToggle("7")
        XCTAssertEqual(
            model.mediaStorageSlotFilter, second, "A label/index cannot become a card ID")
        storage.onToggle(String(first))
        XCTAssertEqual(
            Set(model.filteredMediaClips.map(\.filename)), ["BACKUP.MOV", "PRIMARY.MOV"])
        storage.onToggle(String(first))
        XCTAssertNil(model.mediaStorageSlotFilter)
        storage.onToggle(String(second))
        let sort = model.mediaSortOrder
        model.mediaBrowserSource = .iPhone
        let hidden = MonitorMediaFilterForm(
            presentation: model.mediaGalleryPresentation(model.mediaGalleryProjection),
            onAction: model.applyMediaGalleryFilter)
        XCTAssertNil(hidden.storage)
        XCTAssertEqual(hidden.hasActiveFilters, true)
        XCTAssertEqual(model.mediaStorageSlotFilter, second)
        hidden.onClear()
        XCTAssertEqual(model.mediaActiveFilterCount, 0)
        XCTAssertEqual(model.mediaCategoryTab, .all)
        XCTAssertEqual(model.mediaSortOrder, sort)
    }

    private func filterCaptureDate(daysAgo: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return formatter.string(from: date)
    }

    private func filterClip(_ name: String, width: UInt32, date: String) -> MediaClip {
        MediaClip(
            cameraID: "SIMULATED-filter", filename: name, handle: 1, storageID: 65_537,
            sizeBytes: 1, captureDate: date, pixelWidth: width)
    }

    @MainActor
    func testCommonZebraUnknownEditorOmitsNativeFieldsWithoutLosingZoneControls() async throws {
        let absent = MonitorZebraNumberZone(
            enabled: .constant(false), entry: nil,
            colors: [MonitorSettingsColorDot(value: "White", title: "White", color: .white)],
            paint: .constant("White"))
        let content = MonitorZebraMenu(
            units: ["Native", "IRE"], unit: .constant("IRE"), title: { $0 },
            unitsTitle: "Units", unitsHelp: "SIMULATED missing calibration", highlightHelp: "",
            midtoneHelp: "", highlight: absent, midtone: absent, compact: true)
        let host = UIHostingController(
            rootView: MonitorViewAssistSettings(sections: [.zebra(content)]))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for _ in 0..<200 {
            host.view.layoutIfNeeded()
            await Task.yield()
        }
        func fields(_ view: UIView) -> [UITextField] {
            if let field = view as? UITextField { return [field] }
            return view.subviews.flatMap(fields)
        }
        XCTAssertTrue(
            fields(host.view).isEmpty,
            "Unknown calibration cannot manufacture a numeric field or zero threshold")
        XCTAssertGreaterThan(host.view.bounds.width, 0)
    }

    @MainActor
    func testActualZebraRowsUseCommonNumberPadClampAndDoneWithNativeConversion() async throws {
        let model = NativeAppModel(assist: .scratch())
        let original = model.preferences
        let originalAssist = model.assistConfiguration
        model.preferences = OperatorPreferences.defaults
        model.assistConfiguration.zebra = .init()
        defer {
            model.preferences = original
            model.assistConfiguration = originalAssist
        }
        let host = UIHostingController(
            rootView:
                NikonZebraNativeFixtureView(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func fields(_ view: UIView) -> [UITextField] {
            if let field = view as? UITextField { return [field] }
            return view.subviews.flatMap(fields)
        }
        for _ in 0..<200 {
            host.view.layoutIfNeeded()
            await Task.yield()
        }
        let threshold = try XCTUnwrap(fields(host.view).first)
        XCTAssertEqual(
            fields(host.view).count, 2, "The real highlight and midtone rows use native fields")
        XCTAssertEqual(threshold.keyboardType, .numberPad)

        func enterAndFinish(_ text: String) async throws -> String? {
            XCTAssertTrue(threshold.becomeFirstResponder())
            threshold.text = text
            threshold.sendActions(for: .editingChanged)
            let bar = try XCTUnwrap(threshold.inputAccessoryView as? UIToolbar)
            let done = try XCTUnwrap(
                bar.items?.first { $0.title == MonitorSettingsNumberField.doneTitle })
            let selector = try XCTUnwrap(done.action)
            XCTAssertTrue(
                UIApplication.shared.sendAction(selector, to: done.target, from: done, for: nil))
            let committed = threshold.text
            for _ in 0..<200 {
                host.view.layoutIfNeeded()
                await Task.yield()
            }
            XCTAssertFalse(threshold.isFirstResponder, "Done dismisses the actual native keyboard")
            return committed
        }

        let clampedIRE = try await enterAndFinish("999")
        XCTAssertEqual(clampedIRE, "100")
        XCTAssertEqual(threshold.text, "100")
        XCTAssertEqual(model.assist.zebraHighlightIRE, 100)
        model.assistConfiguration.zebra.unit = .native
        for _ in 0..<200 {
            host.view.layoutIfNeeded()
            await Task.yield()
        }
        let clampedNative = try await enterAndFinish("999")
        XCTAssertEqual(clampedNative, "255")
        XCTAssertEqual(
            model.assist.zebraHighlightIRE,
            model.exposureSignalMapping.monitorPercent(signalNative: 255), accuracy: 0.0001)
        // Codes above the tone curve's clipping point map to the existing normalized maximum.
        // After committing, the real binding displays that converted threshold again.
        XCTAssertEqual(
            threshold.text,
            String(
                model.assistConfiguration.zebra.unit.displayValue(
                    for: model.assist.zebraHighlightIRE,
                    mapping: model.exposureSignalMapping)))
        _ = try await enterAndFinish("128")
        XCTAssertEqual(
            model.assist.zebraHighlightIRE,
            model.exposureSignalMapping.monitorPercent(signalNative: 128), accuracy: 0.0001)
        let retained = model.assist.zebraHighlightIRE
        _ = try await enterAndFinish("")
        XCTAssertEqual(threshold.text, "128")
        XCTAssertEqual(model.assist.zebraHighlightIRE, retained)
    }

    @MainActor
    func testActualSharedNikonInspectorUsesAcceptedNativePictureAndRetiresChangedMeaning()
        async throws
    {
        // SIMULATED raster enters the same accepted local picture path used by still/demo feeds.
        // The actual shared monitor composes the inspector and drives the native renderer task.
        let model = NativeAppModel()
        let savedPreferences = model.preferences
        let savedConfiguration = model.assistConfiguration
        let savedTools = model.assist.liveTools
        let savedInspector = model.assist.configureTool
        defer {
            model.assist.configureTool = savedInspector
            for tool in MonitorAssistTool.activeCases {
                model.assist.set(tool, visible: savedTools.contains(tool), context: .liveView)
            }
            model.preferences = savedPreferences
            model.assistConfiguration = savedConfiguration
        }
        model.preferences = OperatorPreferences.defaults
        model.isMonitorPresented = true
        model.videoSource = .hdmiCapture
        for tool in MonitorAssistTool.activeCases {
            model.assist.set(tool, visible: false, context: .liveView)
        }
        func raster(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image {
                color.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            }
        }
        model.liveFrameImage = raster(.green)
        model.assistConfiguration.selectedLUT = .builtIn(.log3G10Rec709)
        model.shell.present(
            ConnectedCamera(
                saved: SavedCamera(
                    id: "SIMULATED-inspector",
                    integration: IntegrationID("org.opencapture.nikon-ptp"),
                    advertisedName: "SIMULATED camera", model: "SIMULATED"),
                session: NikonPictureLifetimeSession()))
        let delivery = MediaDeliveryCoordinator()
        let host = UIHostingController(
            rootView: GeometryReader { proxy in
                NikonMonitorShell(
                    context: LiveViewLayoutContext(
                        proxy: proxy, deviceOrientation: .unknown, screenWidth: nil)
                )
                .environment(model).environment(delivery).environment(\.scenePhase, .active)
            })
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKeyAndVisible()
        }
        func renderedElement(_ identifier: String) -> NSObject? {
            var seen = Set<ObjectIdentifier>()
            func find(_ object: NSObject) -> NSObject? {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
                let getter = NSSelectorFromString("accessibilityIdentifier")
                if object.responds(to: getter),
                    object.perform(getter)?.takeUnretainedValue() as? String
                        == identifier
                {
                    return object
                }
                var children = object.accessibilityElements as? [NSObject] ?? []
                let count = object.accessibilityElementCount()
                if count > 0 && count < 512 {
                    children += (0..<count).compactMap {
                        object.accessibilityElement(at: $0) as? NSObject
                    }
                }
                if let view = object as? UIView { children += view.subviews }
                for child in children { if let result = find(child) { return result } }
                return nil
            }
            return find(host.view)
        }
        func previewElement() -> NSObject? { renderedElement("monitor.inspector.preview") }
        func mountedElement(_ identifier: String) async throws -> NSObject {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        host.view.layoutIfNeeded()
                        return renderedElement(identifier) != nil
                    }
                }, object: nil)
            let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
            XCTAssertEqual(
                result, .completed, "Actual monitor control did not mount: \(identifier)")
            return try XCTUnwrap(renderedElement(identifier))
        }
        func openRenderedLUTOptions() async throws {
            if renderedElement("monitor.assists.collapse") == nil {
                let expand = try await mountedElement("monitor.assists.expand")
                XCTAssertTrue(expand.accessibilityActivate())
                _ = try await mountedElement("monitor.assists.collapse")
            }
            let element = try await mountedElement("monitor.assist.LUT")
            let action = try XCTUnwrap(
                element.accessibilityCustomActions?.first { $0.name == "Options" })
            let handler = try XCTUnwrap(action.actionHandler)
            XCTAssertTrue(handler(action))
            XCTAssertEqual(model.assist.configureTool, MonitorAssistTool.lut.selection)
        }
        func settledImage() async throws -> CGImage {
            for _ in 0..<250 {
                host.view.layoutIfNeeded()
                if previewElement()?.accessibilityValue == "Picture",
                    let meaning = model.nativeInspectorMeaning(tool: .lut),
                    let image = model.nativeInspectorPreview.image(matching: meaning)
                {
                    return image
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let meaning = model.nativeInspectorMeaning(tool: .lut)
            let element = previewElement()
            let hasImage =
                meaning.flatMap { model.nativeInspectorPreview.image(matching: $0) } != nil
            XCTFail(
                "Actual composed LUT inspector did not publish a current native preview: "
                    + "element=\(element != nil), accessibility=\(String(describing: element?.accessibilityValue)), "
                    + "frame=\(model.nativeInspectorFrame != nil), meaning=\(meaning != nil), image=\(hasImage), "
                    + "tool=\(String(describing: model.assist.configureTool)), "
                    + "scene=\(model.assist.inspectorSceneActive), covered=\(model.assist.liveCovered), "
                    + "playback=\(model.assist.gradesClip), locked=\(model.interfaceLocked), "
                    + "editor=\(String(describing: model.chromeEditorMode)), "
                    + "panel=\(String(describing: model.activePanel)), display=\(model.displayMode)"
            )
            return try XCTUnwrap(nil as CGImage?)
        }
        func center(_ image: CGImage) -> [UInt8] {
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                let context = CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(
                    image,
                    in: CGRect(
                        x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                        width: CGFloat(image.width), height: CGFloat(image.height)))
            }
            return pixel
        }
        try await openRenderedLUTOptions()
        let colored = try await settledImage()
        XCTAssertLessThanOrEqual(max(colored.width, colored.height), 320)
        XCTAssertGreaterThan(Int(center(colored)[1]), Int(center(colored)[0]) + 20)
        XCTAssertFalse(model.assist.isOn(.lut), "Previewing a tool must not enable its live switch")
        model.assistConfiguration.selectedLUT = .builtIn(.monochrome)
        let nextMeaning = try XCTUnwrap(model.nativeInspectorMeaning(tool: .lut))
        XCTAssertNil(
            model.nativeInspectorPreview.image(matching: nextMeaning),
            "The old look must retire synchronously")
        let mono = center(try await settledImage())
        XCTAssertLessThan(abs(Int(mono[0]) - Int(mono[1])), 3)
        XCTAssertLessThan(abs(Int(mono[1]) - Int(mono[2])), 3)
        let oldSource = try XCTUnwrap(model.liveFrameSource)
        let retiredScopePublication = model.captureLiveScopePublication()
        model.liveFrameImage = nil
        XCTAssertFalse(oldSource.isActive)
        XCTAssertNil(model.nativeInspectorMeaning(tool: .lut))
        model.assist.configureTool = nil
        for _ in 0..<20 { await Task.yield() }
        let red = raster(.red)
        model.liveFrameImage = red
        await model.refreshScopes(from: red, full: true)
        let currentScopeBundle = model.scopeAssist
        XCTAssertNotEqual(currentScopeBundle, .empty)
        retiredScopePublication(.empty)
        XCTAssertEqual(
            model.scopeAssist, currentScopeBundle,
            "Retired native sampling must not replace the new source's bundle")
        XCTAssertFalse(model.liveFrameSource === oldSource)
        model.assistConfiguration.selectedLUT = .builtIn(.log3G10Rec709)
        try await openRenderedLUTOptions()
        let reopened = center(try await settledImage())
        XCTAssertGreaterThan(Int(reopened[0]), Int(reopened[1]) + 20)
        model.beginChromeEditing(.live)
        XCTAssertNil(model.nativeInspectorMeaning(tool: .lut))
        model.endChromeEditing()
        try await openRenderedLUTOptions()
        _ = try await settledImage()
        model.retireOperatorQuickPresentation()
        let retired = try XCTUnwrap(model.nativeInspectorMeaning(tool: .lut))
        XCTAssertNil(
            model.nativeInspectorPreview.image(matching: retired),
            "Geometry/source receipts retire old pictures")
    }

    @MainActor
    func testActualSharedNikonMonitorKeepsNativePictureThroughOwnedAndBorrowedLifetimes()
        async throws
    {
        // SIMULATED HDMI raster and public-contract session; no camera transport is invoked.
        for borrowed in [false, true] {
            let model = NativeAppModel()
            model.preferences = OperatorPreferences.defaults
            model.isMonitorPresented = true
            model.videoSource = .hdmiCapture
            let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image {
                context in
                UIColor.green.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
            }
            model.liveFrameImage = image
            let session = NikonPictureLifetimeSession()
            let saved = SavedCamera(
                id: "SIMULATED-picture-lifetime",
                integration: IntegrationID("org.opencapture.nikon-ptp"),
                advertisedName: "SIMULATED camera", model: "SIMULATED")
            let camera = ConnectedCamera(saved: saved, session: session)
            var returns = 0
            if borrowed {
                model.shell.borrow(camera) { returns += 1 }
            } else {
                model.shell.present(camera)
            }
            let monitor = model.shell.monitor?.id
            let delivery = MediaDeliveryCoordinator()
            let content = GeometryReader { proxy in
                NikonMonitorShell(
                    context: LiveViewLayoutContext(
                        proxy: proxy,
                        deviceOrientation: .unknown, screenWidth: nil)
                ).environment(model).environment(delivery)
            }
            let host = UIHostingController(rootView: content)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = host
            window.isHidden = false
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            let original = try await picture(in: host)
            for size in [CGSize(width: 874, height: 402), CGSize(width: 402, height: 874)] {
                window.frame.size = size
                host.view.frame.size = size
                for mode in [DispMode.live, .clean, .command] {
                    model.displayMode = mode
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    let next = try await picture(in: host)
                    XCTAssertTrue(
                        next === original,
                        "Rotation and DISP must preserve the actual native picture view")
                }
            }
            model.displayMode = .live
            for panel in [NativeAppModel.ActivePanel.settings, .media] {
                model.activePanel = panel
                let coveredPicture = try await picture(in: host)
                XCTAssertTrue(coveredPicture === original)
                XCTAssertEqual(model.shell.monitor?.id, monitor)
                model.activePanel = nil
                let returnedPicture = try await picture(in: host)
                XCTAssertTrue(returnedPicture === original)
            }
            // Control is lost while HDMI continues. The shared session remains in recovery;
            // neither telemetry/authority loss nor the app's disconnected link removes its raster.
            session.loseControl()
            model.connection = .disconnected
            let heldPicture = try await picture(in: host)
            XCTAssertTrue(heldPicture === original)
            XCTAssertTrue(model.liveFrameImage === image)
            XCTAssertEqual(model.shell.monitor?.id, monitor)
            XCTAssertTrue(session.closes.isEmpty)
            model.shell.close()
            for _ in 0..<200 { await Task.yield() }
            XCTAssertEqual(session.closes, borrowed ? [] : [.requested])
            XCTAssertEqual(returns, borrowed ? 1 : 0)
            XCTAssertEqual(
                session.commands, 0, "Retirement must never send Stop or any camera command")
        }
    }

    @MainActor
    private func picture(in host: UIViewController) async throws -> UIView {
        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "monitor.native.picture" { return view }
            for child in view.subviews { if let result = find(child) { return result } }
            return nil
        }
        for _ in 0..<300 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
            if let view = find(host.view), !view.bounds.isEmpty { return view }
        }
        return try XCTUnwrap(find(host.view), "The production native picture host was not mounted")
    }

    /// SIMULATED HDMI raster through the actual mounted Metal picture host. The shared native
    /// baker keeps the held frame current and presentable through transport recovery and an
    /// in-recovery repaint; only an explicit clear retires it, and a successor mounts a new owner.
    @MainActor
    func testMountedMetalPictureKeepsHeldFrameThroughRecoveryUntilExplicitClear() async throws {
        func solid(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
            }
        }
        let isGreen: (RGB) -> Bool = { $0.green > 200 && $0.red < 60 && $0.blue < 60 }
        let isRed: (RGB) -> Bool = { $0.red > 200 && $0.green < 60 && $0.blue < 60 }
        let model = NativeAppModel()
        model.preferences = OperatorPreferences.defaults
        model.isMonitorPresented = true
        model.videoSource = .hdmiCapture
        model.liveFrameImage = solid(.green)
        let held = try XCTUnwrap(model.liveFrameSource)
        let session = NikonPictureLifetimeSession()
        let saved = SavedCamera(
            id: "SIMULATED-held-recovery",
            integration: IntegrationID("org.opencapture.nikon-ptp"),
            advertisedName: "SIMULATED camera", model: "SIMULATED")
        model.shell.present(ConnectedCamera(saved: saved, session: session))
        let delivery = MediaDeliveryCoordinator()
        let content = GeometryReader { proxy in
            NikonMonitorShell(
                context: LiveViewLayoutContext(
                    proxy: proxy, deviceOrientation: .unknown, screenWidth: nil)
            ).environment(model).environment(delivery)
        }
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.rootViewController = host
        window.isHidden = false
        var acquired: [(MonitorFrameBaker, MonitorFrameBaker.Frame)] = []
        defer {
            for (owner, frame) in acquired { owner.releaseBakedTexture(frame.texture) }
            model.liveFrameImage = nil
            model.shell.close()
            window.isHidden = true
            window.rootViewController = nil
        }
        func mounted() async throws -> (MTKView, MonitorMetalPicturePresenter, MonitorFrameBaker) {
            let found = try await picture(in: host)
            let view = try XCTUnwrap(found as? MTKView, "The Metal feed must mount the picture")
            let presenter = try XCTUnwrap(view.delegate as? MonitorMetalPicturePresenter)
            // Read-only reflection of the actual mounted owner; no production test seam.
            let baker = try XCTUnwrap(
                Mirror(reflecting: presenter).descendant("baker") as? MonitorFrameBaker)
            return (view, presenter, baker)
        }
        func presented(
            _ owner: (MTKView, MonitorMetalPicturePresenter, MonitorFrameBaker),
            _ matches: (RGB) -> Bool
        ) async throws -> MonitorFrameBaker.Frame {
            let (view, presenter, baker) = owner
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                // Exactly the presenter's draw-time acquisition for its current drawable.
                if let frame = baker.acquireFrame(
                    for: presenter.drawableSize, pixelFormat: view.colorPixelFormat)
                {
                    if frame.isCurrent, try matches(centerPixel(of: frame.texture)) {
                        acquired.append((baker, frame))
                        return frame
                    }
                    baker.releaseBakedTexture(frame.texture)
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("No current matching frame was baked for the mounted presenter")
            throw XCTestError(.timeoutWhileWaiting)
        }

        let owner = try await mounted()
        let first = try await presented(owner, isGreen)

        // Recovery: control and link are lost while the held raster remains admitted.
        session.loseControl()
        model.connection = .reconnecting
        let (view, presenter, baker) = owner
        let recovering = try await picture(in: host)
        XCTAssertTrue(recovering === view, "Recovery must keep the mounted native picture host")
        XCTAssertTrue(view.delegate === presenter)
        XCTAssertTrue(model.liveFrameSource === held)
        XCTAssertTrue(held.isActive)
        XCTAssertTrue(first.isCurrent, "Transport recovery must not retire the held baked frame")
        _ = try await presented(owner, isGreen)

        // A repaint during recovery keeps the same lease and bakes through the same owner.
        model.liveFrameImage = solid(.red)
        XCTAssertTrue(model.liveFrameSource === held)
        let repainted = try await presented(owner, isRed)
        XCTAssertTrue(first.isCurrent)
        XCTAssertTrue(repainted.isCurrent)

        // Explicit clear retires the lease, every acquired frame and the mounted owner.
        model.liveFrameImage = nil
        XCTAssertFalse(held.isActive)
        XCTAssertFalse(first.isCurrent)
        XCTAssertFalse(repainted.isCurrent)
        for _ in 0..<300 where view.delegate != nil {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
        }
        XCTAssertNil(view.delegate, "Explicit clear must dismantle the mounted presenter")
        XCTAssertNil(
            baker.acquireFrame(for: presenter.drawableSize, pixelFormat: view.colorPixelFormat))

        // A successor raster admits a new lease and a new mounted owner; the old stays retired.
        model.liveFrameImage = solid(.green)
        let successor = try XCTUnwrap(model.liveFrameSource)
        XCTAssertFalse(successor === held)
        let next = try await mounted()
        XCTAssertFalse(next.0 === view)
        let admitted = try await presented(next, isGreen)
        XCTAssertTrue(admitted.isCurrent)
        XCTAssertFalse(first.isCurrent)
        XCTAssertFalse(repainted.isCurrent)
        XCTAssertEqual(session.commands, 0, "A captured frame never sends a camera command")
    }

    struct RGB { let red, green, blue: UInt8 }

    /// Reads the centre texel of a private BGRA8 bake through a blit into shared memory.
    private func centerPixel(of texture: MTLTexture) throws -> RGB {
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        let device = texture.device
        let buffer = try XCTUnwrap(device.makeBuffer(length: 4, options: .storageModeShared))
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: texture.width / 2, y: texture.height / 2, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return RGB(red: bytes[2], green: bytes[1], blue: bytes[0])
    }

    func testDemoSettingsTabSelection() {
        XCTAssertEqual(MonitorSettingsTab.demoLaunchTab("assist"), .assist)
        XCTAssertEqual(MonitorSettingsTab.demoLaunchTab("storage"), .storage)
        XCTAssertEqual(MonitorSettingsTab.demoLaunchTab("unknown"), .link)
    }

    func testMediaClipStoreBuildsContainedURLsForSafeBasenames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)

        let mediaURL = try store.localURL(
            cameraID: "../camera serial", filename: "Scene 12 – Göteborg.MOV")
        let thumbnailURL = try store.thumbURL(
            cameraID: "../camera serial", filename: "Scene 12 – Göteborg.MOV")

        XCTAssertTrue(mediaURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        XCTAssertTrue(thumbnailURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        XCTAssertEqual(mediaURL.lastPathComponent, "Scene 12 – Göteborg.MOV")
        XCTAssertEqual(thumbnailURL.lastPathComponent, "Scene 12 – Göteborg.jpg")
    }

    func testMediaClipStoreRejectsTraversalSeparatorsAndControls() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)

        for filename in [
            "../outside.mp4",
            "folder/clip.mov",
            "folder\\clip.mov",
            "clip\n.mp4",
            "clip\0.mp4",
        ] {
            XCTAssertThrowsError(try store.localURL(cameraID: "camera", filename: filename))
            XCTAssertThrowsError(try store.thumbURL(cameraID: "camera", filename: filename))
            XCTAssertThrowsError(
                try store.openForStreaming(cameraID: "camera", filename: filename))
        }
    }

    func testMediaClipStoreRejectsTraversalDeletionAndPreservesOutsideFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideURL = root.appendingPathComponent("outside.mp4")
        try Data("keep".utf8).write(to: outsideURL)
        let store = MediaClipStore(root: root)

        XCTAssertThrowsError(
            try store.removeLocalFile(cameraID: "camera", filename: "../outside.mp4"))
        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("keep".utf8))
    }

    func testMediaClipStoreDeletesOnlyValidatedMediaBasename() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        let url = try store.localURL(cameraID: "camera", filename: "clip.mp4")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: url)

        try store.removeLocalFile(cameraID: "camera", filename: "clip.mp4")

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLUTFileStoreImportRejectsUnusableCubeBeforeCopy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-bad.cube")
        try Data("LUT_3D_SIZE 66\n0 0 0\n".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let store = LUTFileStore(root: root)

        XCTAssertThrowsError(try store.importFile(from: source, into: .custom))
        XCTAssertTrue(store.list(.custom).isEmpty)
    }

    func testLUTFileStoreImportAcceptsValidCube() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-Clean Whites.cube")
        try Data(
            """
            TITLE "Generated by Resolve"
            LUT_3D_SIZE 2
            0.03 0.04 0.05
            1 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1 1 1
            """.utf8
        ).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let store = LUTFileStore(root: root)

        let stored = try store.importFile(from: source, into: .custom)
        let cube = try XCTUnwrap(store.cube(category: .custom, fileName: stored.fileName))

        XCTAssertEqual(stored.fileName, source.lastPathComponent)
        XCTAssertEqual(cube.size, 2)
        XCTAssertEqual(Array(cube.rgb.prefix(3)), [0.03, 0.04, 0.05])
    }

    @MainActor
    func testImportCustomLUTSelectsAndEnablesTheLook() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-look.cube")
        try Data(
            """
            LUT_3D_SIZE 2
            0 0 0
            1 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1 1 1
            """.utf8
        ).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = NativeAppModel(lutFileStore: LUTFileStore(root: root))

        try model.importCustomLUT(from: source)

        XCTAssertEqual(model.customLUTs.map(\.fileName), [source.lastPathComponent])
        XCTAssertEqual(
            model.assistConfiguration.selectedLUT,
            .stored(category: .custom, fileName: source.lastPathComponent))
        XCTAssertNotNil(model.currentLUTCube())
    }

    func testLUTFileStoreDeletesStoredLUTAndRejectsBuiltInDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lut = StoredCustomLUT(fileName: "Operator Look.cube")
        let lutURL = custom.appendingPathComponent(lut.fileName)
        try Data("stored".utf8).write(to: lutURL)
        let store = LUTFileStore(root: root)

        try store.remove(lut, from: .custom)

        XCTAssertFalse(FileManager.default.fileExists(atPath: lutURL.path))
        XCTAssertThrowsError(try store.remove(lut, from: .builtIn)) { error in
            XCTAssertEqual(error as? LUTDeletionError, .builtInProtected)
        }
    }

    func testLUTFileStoreRejectsTraversalDeletionAndPreservesOutsideFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideURL = root.appendingPathComponent("outside.cube")
        try Data("keep".utf8).write(to: outsideURL)
        let store = LUTFileStore(root: root)

        XCTAssertThrowsError(
            try store.remove(StoredCustomLUT(fileName: "../outside.cube"), from: .custom)
        ) { error in
            XCTAssertEqual(error as? LUTDeletionError, .invalidFileName)
        }
        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("keep".utf8))
    }

    func testLUTCubeCacheInvalidationRebuildsSameNamedStoredLook() throws {
        let key = "test-stored:\(UUID().uuidString)"
        var buildCount = 0
        func makeCube() -> CubeLUT {
            buildCount += 1
            return MonitorLUT.monochrome.cube(size: 2)
        }

        _ = try XCTUnwrap(LUTCubeCache.cube(forKey: key) { makeCube() })
        _ = try XCTUnwrap(LUTCubeCache.cube(forKey: key) { makeCube() })
        XCTAssertEqual(buildCount, 1)

        LUTCubeCache.invalidate(forKey: key)
        _ = try XCTUnwrap(LUTCubeCache.cube(forKey: key) { makeCube() })

        XCTAssertEqual(buildCount, 2)
    }

    @MainActor
    func testDeletingSelectedStoredLUTChoosesRemainingLookThenBuiltInFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for fileName in ["A.cube", "B.cube"] {
            try Data(fileName.utf8).write(to: custom.appendingPathComponent(fileName))
        }
        let model = NativeAppModel(lutFileStore: LUTFileStore(root: root))
        model.refreshCustomLUTs()
        model.assistConfiguration.selectedLUT = .stored(category: .custom, fileName: "B.cube")

        try model.deleteStoredLUT(StoredCustomLUT(fileName: "B.cube"), from: .custom)

        XCTAssertEqual(model.customLUTs.map(\.fileName), ["A.cube"])
        XCTAssertEqual(
            model.assistConfiguration.selectedLUT,
            .stored(category: .custom, fileName: "A.cube"))

        try model.deleteStoredLUT(StoredCustomLUT(fileName: "A.cube"), from: .custom)

        XCTAssertTrue(model.customLUTs.isEmpty)
        XCTAssertEqual(
            model.assistConfiguration.selectedLUT,
            .builtIn(.log3G10Rec709))
    }

    @MainActor
    func testDeletingNonselectedStoredLUTPreservesSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for fileName in ["A.cube", "B.cube"] {
            try Data(fileName.utf8).write(to: custom.appendingPathComponent(fileName))
        }
        let model = NativeAppModel(lutFileStore: LUTFileStore(root: root))
        model.refreshCustomLUTs()
        model.assistConfiguration.selectedLUT = .stored(category: .custom, fileName: "B.cube")

        try model.deleteStoredLUT(StoredCustomLUT(fileName: "A.cube"), from: .custom)

        XCTAssertEqual(
            model.assistConfiguration.selectedLUT,
            .stored(category: .custom, fileName: "B.cube"))
    }

    @MainActor
    func testDemoKeyCatcherRegistersStartupAndInDemoCommands() {
        let commands = DemoKeyCatcherView().keyCommands ?? []

        XCTAssertTrue(
            commands.contains {
                $0.input == "o" && $0.modifierFlags == .command
            })
        XCTAssertTrue(
            commands.contains {
                $0.input == "d" && $0.modifierFlags == .command
            })
        XCTAssertFalse(commands.contains { Int($0.input ?? "") != nil })
    }

    @MainActor
    func testStartupShortcutEntersInteractiveDemo() {
        let model = NativeAppModel()

        model.enterInteractiveDemoFromStartupShortcut()

        XCTAssertTrue(model.isDemoSession)
        XCTAssertTrue(model.isMonitorPresented)
        XCTAssertTrue(model.demoUIMode)
        XCTAssertEqual(model.connection, .connected)
        XCTAssertEqual(model.liveViewFocus?.boxes.count, 2)
    }

    @MainActor
    func testStartupShortcutCannotReplaceAnOpenMonitor() {
        let model = NativeAppModel()
        model.isMonitorPresented = true

        model.enterInteractiveDemoFromStartupShortcut()

        XCTAssertFalse(model.isDemoSession)
        XCTAssertFalse(model.demoUIMode)
    }

    @MainActor
    func testDemoKeyRoutesMarketingStillsOneThroughFive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = try (1...5).map { number in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image {
                context in
                UIColor(hue: CGFloat(number) / 5, saturation: 1, brightness: 1, alpha: 1)
                    .setFill()
                context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 2, height: 2)))
            }
            let url = directory.appendingPathComponent("\(number).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            return url.path
        }

        let model = NativeAppModel()
        model.startDemoSession()
        model.demoFeedImagePaths = paths
        for number in 1...5 {
            model.liveFrameImage = nil
            model.handleDemoKey(input: "\(number)", hasCommand: false)
            XCTAssertNotNil(model.liveFrameImage)
        }
        model.liveFrameImage = nil
        model.handleDemoKey(input: "6", hasCommand: false)
        XCTAssertNil(model.liveFrameImage)
    }

    @MainActor
    func testDemoKeyCatcherRoutesPrintableDigitsThroughUIKeyInput() {
        let catcher = DemoKeyCatcherView()
        var inputs: [String] = []
        catcher.onKey = { input, hasCommand in
            inputs.append("\(input):\(hasCommand)")
        }

        catcher.insertText("1a28")

        XCTAssertEqual(inputs, ["1:false", "2:false", "8:false"])
    }

    @MainActor
    func testDemoFeedDiscoveryScansOnlyConfiguredDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marketing = root.appendingPathComponent("marketing", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: marketing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectedNames = try (1...5).map { number in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image {
                context in
                UIColor(hue: CGFloat(number) / 5, saturation: 1, brightness: 1, alpha: 1)
                    .setFill()
                context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
            }
            let name = "Still \(number).jpg"
            let url = root.appendingPathComponent(name)
            try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: url)
            return name
        }
        try Data("not a demo still".utf8).write(
            to: marketing.appendingPathComponent("marketing.png"))

        let paths = DemoFeedImageDiscovery.imagePaths(in: root.path)

        XCTAssertEqual(paths.map { URL(fileURLWithPath: $0).lastPathComponent }, expectedNames)
        XCTAssertTrue(
            paths.allSatisfy { URL(fileURLWithPath: $0).deletingLastPathComponent() == root })

        let model = NativeAppModel()
        model.startDemoSession()
        model.demoFeedImagePaths = paths
        var selectedImages: [Data] = []
        for number in 1...3 {
            model.handleDemoKey(input: "\(number)", hasCommand: false)
            selectedImages.append(try XCTUnwrap(model.liveFrameImage?.pngData()))
        }
        XCTAssertEqual(Set(selectedImages).count, 3)
    }

    @MainActor
    func testDemoFeedLaunchDiscoveryFallsBackWhenEnvironmentIsAbsentOrStale() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.green.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 2, height: 2)))
        }
        let imageURL = root.appendingPathComponent("Still 1.jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: imageURL)
        let nestedDirectory = root.appendingPathComponent("not-a-feed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedDirectory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(
            to: nestedDirectory.appendingPathComponent("marketing-export.png"))

        for environment in [[:], ["ZC_DEMO_FEED_DIR": root.appendingPathComponent("missing").path]]
        {
            let paths = DemoFeedImageDiscovery.launchImagePaths(
                environment: environment, fallbackDirectoryPath: root.path)
            XCTAssertEqual(paths, [imageURL.path])
        }
    }

    @MainActor
    func testDemoKeyEightTogglesEyeBox() throws {
        let model = NativeAppModel()
        model.enterInteractiveDemoFromStartupShortcut()

        model.handleDemoKey(input: "8", hasCommand: false)

        let withoutEye = try XCTUnwrap(model.liveViewFocus)
        XCTAssertEqual(withoutEye.boxes.count, 1)
        XCTAssertFalse(withoutEye.subjectDetectionActive)
        XCTAssertFalse(withoutEye.trackingAFActive)
        XCTAssertEqual(withoutEye.selectedBoxIndex, 0)

        model.handleDemoKey(input: "8", hasCommand: false)

        let restored = try XCTUnwrap(model.liveViewFocus)
        XCTAssertEqual(restored.boxes.count, 2)
        XCTAssertTrue(restored.subjectDetectionActive)
        XCTAssertEqual(restored.selectedBoxIndex, 1)
    }

    @MainActor
    func testDemoDragOnEyeMovesOnlyEyeAndClampsItInsideFocusBox() throws {
        let model = NativeAppModel()
        model.enterInteractiveDemoFromStartupShortcut()
        let feedSize = CGSize(width: 6048, height: 3400)
        let initial = try XCTUnwrap(model.liveViewFocus)
        let focusBox = initial.boxes[0]
        let eye = initial.boxes[1]

        XCTAssertEqual(
            model.demoFocusDragTarget(
                at: CGPoint(x: eye.centerX, y: eye.centerY), feedSize: feedSize),
            .eye)
        model.demoMoveEyeBox(to: .zero, feedSize: feedSize)

        let moved = try XCTUnwrap(model.liveViewFocus)
        XCTAssertEqual(moved.boxes[0], focusBox)
        let movedEye = moved.boxes[1]
        XCTAssertGreaterThanOrEqual(
            movedEye.centerX - movedEye.width / 2,
            focusBox.centerX - focusBox.width / 2)
        XCTAssertLessThanOrEqual(
            movedEye.centerX + movedEye.width / 2,
            focusBox.centerX + focusBox.width / 2)
        XCTAssertGreaterThanOrEqual(
            movedEye.centerY - movedEye.height / 2,
            focusBox.centerY - focusBox.height / 2)
        XCTAssertLessThanOrEqual(
            movedEye.centerY + movedEye.height / 2,
            focusBox.centerY + focusBox.height / 2)
    }

    @MainActor
    func testFalseColorCurveAlwaysFollowsCodec() {
        let model = NativeAppModel(assist: .scratch())
        model.assist.set(.falseColor, visible: true, context: .liveView)
        model.assist.set(.falseColor, visible: true, context: .playback)
        model.connection = .connected
        let cases: [(codec: String, curve: ExposureToneCurve)] = [
            ("R3D NE", .redLog3G10),
            ("N-RAW", .nikonNLog),
            ("ProRes RAW HQ", .nikonNLog),
            ("ProRes 422 HQ", .nikonNLog),
            ("H.265 10-bit", .nikonNLog),
        ]
        for value in cases {
            model.cameraState = model.cameraState.updating(codec: value.codec)
            XCTAssertEqual(model.falseColorToneCurve, value.curve)
            XCTAssertEqual(model.liveImageEffects.falseColor?.curve, value.curve)
            XCTAssertEqual(model.playbackImageEffects.falseColor?.curve, value.curve)
        }

        model.cameraState = model.cameraState.updating(codec: "N-RAW")
        model.connection = .disconnected
        XCTAssertEqual(model.liveImageEffects.falseColor?.curve, .nikonNLog)
        XCTAssertEqual(model.playbackExposureSignalMapping.curve, .redLog3G10)
        XCTAssertEqual(model.playbackImageEffects.falseColor?.curve, .redLog3G10)
    }

    @MainActor
    func testDeletionConfirmMessageIsContextAware() {
        let model = NativeAppModel()

        // A video names the file and never shows stills (RAW+JPEG) wording — the exact
        // regression Erik reported.
        let video = MediaClip(
            cameraID: "cam", filename: "C0001.MOV", handle: 10, storageID: 0x0001_0001,
            sizeBytes: 1, captureDate: "20260724T120000")
        let videoMessage = model.deletionConfirmMessage(for: [video])
        XCTAssertTrue(videoMessage.contains("C0001.MOV"))
        XCTAssertFalse(videoMessage.contains("RAW"))
        XCTAssertFalse(videoMessage.contains("photo"))

        // A lone still: "photo" wording, no companion notes.
        let photo = MediaClip(
            cameraID: "cam", filename: "DSC_0001.JPG", handle: 11, storageID: 0x0001_0001,
            sizeBytes: 1, captureDate: "20260724T120001")
        model.mediaClips = [photo]
        let photoMessage = model.deletionConfirmMessage(for: [photo])
        XCTAssertTrue(photoMessage.contains("photo"))
        XCTAssertFalse(photoMessage.contains("other card"))

        // A backup-mode still lives on both cards (one row, two locations) — the confirm names
        // the cross-card removal.
        var backup = MediaClip(
            cameraID: "cam", filename: "DSC_0002.JPG", handle: 12, storageID: 0x0001_0001,
            sizeBytes: 1, captureDate: "20260724T120002")
        backup.storageLocations = [
            MediaObjectHandle(storageID: 0x0001_0001, handle: 12),
            MediaObjectHandle(storageID: 0x0002_0001, handle: 44),
        ]
        model.mediaClips = [backup]
        XCTAssertTrue(model.deletionConfirmMessage(for: [backup]).contains("other card"))
    }

    @MainActor
    func testDemoStaticRendererAppliesLUTAndFalseColorWithoutMetal() async {
        let encodedSkinHighlight = ExposureToneCurve.redLog3G10.encode(linearLight: 0.18 * 2)
        let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4)).image { context in
            UIColor(
                red: encodedSkinHighlight, green: encodedSkinHighlight,
                blue: encodedSkinHighlight, alpha: 1
            ).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 8, height: 4)))
        }
        let renderer = LiveFrameRenderer(fileStore: LUTFileStore())

        var lutEffects = LiveImageEffects()
        lutEffects.lut = .builtIn(.log3G10Rec709)
        let lutImage = await renderer.renderStaticFrame(source, effects: lutEffects)

        var falseColorEffects = LiveImageEffects()
        falseColorEffects.falseColor = FalseColorSettings(
            scale: .stops, curve: .redLog3G10)
        let falseColorImage = await renderer.renderStaticFrame(
            source, effects: falseColorEffects)

        XCTAssertEqual(lutImage.size, source.size)
        XCTAssertEqual(falseColorImage.size, source.size)
        let sourcePixel = rgbaPixel(source)
        let lutPixel = rgbaPixel(lutImage)
        let falseColorPixel = rgbaPixel(falseColorImage)
        XCTAssertNotEqual(Array(lutPixel.prefix(3)), Array(sourcePixel.prefix(3)))
        XCTAssertGreaterThan(falseColorPixel[0], falseColorPixel[1] + 40)
        XCTAssertLessThan(abs(Int(falseColorPixel[2]) - Int(falseColorPixel[1])), 15)

    }

    func testReferenceFalseColorRendererUsesLimitZonesAndSmoothHighlightTransition() {
        let red = renderedReferenceFalseColorPixel(
            monitorIRE: 100, scale: .limits, curve: .redLog3G10)
        let yellow = renderedReferenceFalseColorPixel(
            monitorIRE: 96, scale: .limits, curve: .redLog3G10)
        let transition = renderedReferenceFalseColorPixel(
            monitorIRE: 99, scale: .limits, curve: .redLog3G10)
        let purple = renderedReferenceFalseColorPixel(
            monitorIRE: 2, scale: .limits, curve: .redLog3G10)

        XCTAssertGreaterThan(red[0], 180)
        XCTAssertLessThan(red[1], 110)
        XCTAssertGreaterThan(yellow[0], 200)
        XCTAssertGreaterThan(yellow[1], 140)
        XCTAssertLessThan(yellow[2], 100)
        XCTAssertGreaterThan(transition[1], red[1])
        XCTAssertLessThan(transition[1], yellow[1])
        XCTAssertGreaterThan(purple[2], purple[0])
        XCTAssertGreaterThan(purple[0], purple[1])
    }

    func testReferenceFalseColorRendererMapsBothCurvesToSharedIREZones() {
        for curve in ExposureToneCurve.allCases {
            let middleGray = renderedReferenceFalseColorPixel(
                monitorIRE: 40, scale: .ire, curve: curve)
            let irePassthrough = renderedReferenceFalseColorPixel(
                monitorIRE: 66, scale: .ire, curve: curve)
            let skinHighlight = renderedReferenceFalseColorPixel(
                monitorIRE: 66, scale: .video, curve: curve)
            let clipped = renderedReferenceFalseColorPixel(
                monitorIRE: 100, scale: .ire, curve: curve)

            XCTAssertGreaterThan(middleGray[1], middleGray[0] + 25)
            XCTAssertGreaterThan(middleGray[1], middleGray[2] + 30)
            for channel in irePassthrough.prefix(3) {
                XCTAssertEqual(Double(channel), 0.66 * 255, accuracy: 1)
            }
            XCTAssertGreaterThan(skinHighlight[0], skinHighlight[1] + 50)
            XCTAssertGreaterThan(skinHighlight[2], skinHighlight[1] + 20)
            XCTAssertGreaterThan(clipped[0], 170)
            XCTAssertLessThan(clipped[1], 110)
        }
    }

    func testFalseColorReferenceUsesCompactProportionalScales() {
        XCTAssertEqual(MonitorFalseColorReference.panelSize, CGSize(width: 264, height: 52))
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        let ire = FalseColorReference.segments(scale: .ire, mapping: mapping)
        XCTAssertEqual(ire.count, 6)
        XCTAssertEqual(ire[0].lowerFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(ire[0].upperFraction, 0.025, accuracy: 0.0001)
        XCTAssertEqual(ire[2].lowerFraction, 0.38, accuracy: 0.0001)
        XCTAssertEqual(ire[2].upperFraction, 0.42, accuracy: 0.0001)
        XCTAssertEqual(ire[5].lowerFraction, 0.95, accuracy: 0.0001)
        XCTAssertEqual(ire[5].upperFraction, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(ire[2].lowerFraction, ire[1].upperFraction)
        let video = FalseColorReference.segments(scale: .video, mapping: mapping)
        XCTAssertEqual(video.count, 9)
        XCTAssertEqual(video[3].lowerFraction, 0.41, accuracy: 0.0001)
        XCTAssertEqual(video[3].upperFraction, 0.49, accuracy: 0.0001)
        let stops = FalseColorReference.segments(scale: .stops, mapping: mapping)
        XCTAssertEqual(stops.count, 9)
        XCTAssertEqual(stops.first?.lowerFraction, 0)
        XCTAssertEqual(stops.last?.upperFraction, 1)
        for pair in zip(stops, stops.dropFirst()) {
            XCTAssertEqual(pair.0.upperFraction, pair.1.lowerFraction, accuracy: 0.0001)
        }
        let markers = FalseColorReference.stopAxisMarkers(mapping: mapping)
        XCTAssertEqual(markers.map(\.label), ["Min", "−2", "−1", "18%", "+1", "+2", "Clip"])
        XCTAssertEqual(
            markers[3].fraction,
            (stops[4].lowerFraction + stops[4].upperFraction) * 0.5, accuracy: 0.0001)
        let reference = FalseColorReference.values(scale: .stops, mapping: mapping, read709: true)
        XCTAssertEqual(reference.subtitle, "CineStop · 709")
        for (curve, label) in [(ExposureToneCurve.srgb, "sRGB"), (.hlg, "HLG")] {
            XCTAssertEqual(
                FalseColorReference.values(
                    scale: .video,
                    mapping: ExposureSignalMapping(curve: curve), read709: true
                ).subtitle,
                "Video · \(label)")
        }
    }

    func testAudioMeterPanelUsesQuarterOriginalWidth() {
        XCTAssertEqual(MonitorAudioMetrics.panelSize.width, 28)
        XCTAssertEqual(MonitorAudioMetrics.panelSize.height, 168)
    }

    /// Live view samples the feed JPEG's raw codes straight through UIKit; playback taps the
    /// composition through Core Image with an explicit BT.709 output space to undo AVFoundation's
    /// working-space conversion. This pins the two pipelines to each other: the same pixels
    /// sampled through both must produce (near-)identical scope readings. [1:1 live/playback]
    func testLiveAndPlaybackScopeTapsReadTheSameCodes() throws {
        // A full-range gradient with per-channel offsets, tagged BT.709 like camera files.
        let width = 256
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x)
                pixels[i + 1] = UInt8((x + 40) % 256)
                pixels[i + 2] = UInt8((x + 90) % 256)
                pixels[i + 3] = 255
            }
        }
        let space = MonitorImageSampling.fileCodeColorSpace
        let data = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: data, decode: nil, shouldInterpolate: false, intent: .defaultIntent))

        // Path A — live view: straight UIKit decode into the untagged sampling context.
        let live = try XCTUnwrap(
            MonitorImageSampling.rgbaBuffer(from: UIImage(cgImage: cgImage), maxWidth: 256))
        let liveSamples = OpenCineMedia.ScopeSampler.sampleRaw(
            bytes: live.data, width: live.width, height: live.height,
            bytesPerRow: live.bytesPerRow, transfer: .rec709, includePoints: true, layout: .rgba,
            stride: ScopeAssistSampling.pointStride, includeSampleCoordinates: true,
            requireCompleteRows: true)

        // Path B — playback: through the composition render context (working sRGB) with the
        // BT.709 output space, exactly like the player's scope tap.
        let ciImage = CIImage(cgImage: cgImage)
        let rendered = try XCTUnwrap(
            MediaLUT.renderContext.createCGImage(
                ciImage, from: ciImage.extent, format: .RGBA8,
                colorSpace: MonitorImageSampling.fileCodeColorSpace))
        let playback = try XCTUnwrap(
            MonitorImageSampling.rgbaBuffer(from: UIImage(cgImage: rendered), maxWidth: 256))
        let playbackSamples = OpenCineMedia.ScopeSampler.sampleRaw(
            bytes: playback.data, width: playback.width, height: playback.height,
            bytesPerRow: playback.bytesPerRow, transfer: .rec709, includePoints: true,
            layout: .rgba, stride: ScopeAssistSampling.pointStride,
            includeSampleCoordinates: true, requireCompleteRows: true)

        XCTAssertEqual(
            liveSamples.histogramLuma.reduce(0, +), playbackSamples.histogramLuma.reduce(0, +),
            "both taps must sample the same number of pixels")
        // Mean code value per channel must agree to well under one 8-bit code — the round trip
        // through the working space is only float quantization, never a transfer-curve shift.
        func meanCode(_ histogram: [Int]) -> Double {
            let total = histogram.reduce(0, +)
            guard total > 0 else { return 0 }
            let weighted = histogram.enumerated().reduce(0.0) {
                $0 + Double($1.offset * $1.element)
            }
            return weighted / Double(total)
        }
        for (a, b) in [
            (liveSamples.histogramRed, playbackSamples.histogramRed),
            (liveSamples.histogramGreen, playbackSamples.histogramGreen),
            (liveSamples.histogramBlue, playbackSamples.histogramBlue),
            (liveSamples.histogramLuma, playbackSamples.histogramLuma),
        ] {
            XCTAssertEqual(meanCode(a), meanCode(b), accuracy: 0.75)
        }
    }

    func testScopeBundleKeepsRawSamples() {
        let point = OpenCineMedia.ScopePoint(
            xRatio: 0.5, yRatio: 0, red: 112, green: 68, blue: 62, luma: 82)
        var luma = Array(repeating: 0, count: 256)
        luma[82] = 1
        let samples = OpenCineMedia.ScopeSamples(
            histogramLuma: luma,
            histogramRed: Array(repeating: 0, count: 256),
            histogramGreen: Array(repeating: 0, count: 256),
            histogramBlue: Array(repeating: 0, count: 256),
            points: [point])
        let mapping = ExposureSignalMapping(curve: .redLog3G10)

        let bundle = ScopeAssistSampling.bundle(
            samples: samples,
            trafficLightsCrushClip: .quarter,
            mapping: mapping)
        // Every scope — vectorscope included — reads the untouched source/log points.
        XCTAssertEqual(bundle.samples, samples)
        XCTAssertEqual(bundle.revision, 1)
        // The shared histogram is drawn on this camera's axis, not a shared transfer curve.
        XCTAssertEqual(
            bundle.histogramDisplay,
            OpenCineMedia.ScopeSampler.histogramDisplay(
                samples: samples, previous: .empty, axis: mapping.scopeLevelAxis))
        let next = ScopeAssistSampling.bundle(
            samples: samples, trafficLightsCrushClip: .quarter, mapping: mapping,
            previous: bundle)
        XCTAssertEqual(next.revision, 2)
        XCTAssertEqual(next.trailSamples, samples)
    }

    func testWaveformAndParadePaletteUsesCalibratedBrightness() {
        // The intensity the Nikon scope plot hands the shared plots.
        XCTAssertEqual(NikonScopePlot.traceIntensity(0), 0)
        XCTAssertEqual(NikonScopePlot.traceIntensity(100), 0.25)
        XCTAssertEqual(NikonScopePlot.traceIntensity(200), 0.5)
        // The vectorscope keeps its unity baseline.
        XCTAssertEqual(MonitorScopeGeometry.vectorscopeIntensity(100), 1)
    }

    @MainActor
    func testVectorscopeAloneActivatesScopeSampling() {
        let model = NativeAppModel(assist: .scratch())
        model.assist.set(.vectorscope, visible: true, context: .liveView)
        XCTAssertTrue(model.scopesActive)
    }

    @MainActor
    func testDemoRendererMapsBothCurvesToSharedStopZones() async {
        let renderer = LiveFrameRenderer(fileStore: LUTFileStore())
        for curve in ExposureToneCurve.allCases {
            let encoded = curve.encode(linearLight: 0.18 * 2)
            let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4)).image {
                context in
                UIColor(red: encoded, green: encoded, blue: encoded, alpha: 1).setFill()
                context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 8, height: 4)))
            }
            var effects = LiveImageEffects()
            effects.falseColor = FalseColorSettings(scale: .stops, curve: curve)
            let output = await renderer.renderStaticFrame(source, effects: effects)
            let pixel = rgbaPixel(output)

            XCTAssertGreaterThan(pixel[0], pixel[1] + 35)
            XCTAssertLessThan(abs(Int(pixel[2]) - Int(pixel[1])), 15)
        }
    }

    private func renderedReferenceFalseColorPixel(
        monitorIRE: Double,
        scale: FalseColorScale,
        curve: ExposureToneCurve
    ) -> [UInt8] {
        let mapping = ExposureSignalMapping(curve: curve)
        let transfer: MonitorTransfer =
            switch curve {
            case .redLog3G10: .log3G10
            case .nikonNLog: .nlog
            case .srgb: .srgb
            case .hlg: .hdr
            }
        let encoded = OpenCineMedia.ScopeDisplayScale.signalNative(
            monitorPercent: monitorIRE, transfer: transfer,
            clipByte: Int(mapping.clipNative.rounded()))
        let encodedSource = CIImage(
            color: CIColor(red: encoded, green: encoded, blue: encoded, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        // The compositor's cube is indexed by the display-encoded signal values it receives from
        // live view and playback. Keep this synthetic source encoded too, matching production.
        let source = encodedSource
        var effects = LiveImageEffects()
        effects.falseColor = FalseColorSettings(scale: scale, curve: curve)
        let resolved = ImageEffectsCompositor.resolve(effects) { _ in nil }
        let output = ImageEffectsCompositor.apply(to: source, effects: resolved)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(
                output,
                toBitmap: bytes.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: nil)
        }
        return pixel
    }

    private func rgbaPixel(_ image: UIImage) -> [UInt8] {
        guard let input = CIImage(image: image) else { return [] }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(
                input,
                toBitmap: bytes.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: nil)
        }
        return pixel
    }

    private func rgbaPixel(_ image: CIImage) -> [UInt8] {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(
                image,
                toBitmap: bytes.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: nil)
        }
        return pixel
    }

    /// The paused-frame refresh keys off whether the composition payload actually changed, so the
    /// effects box must report mutations accurately: `true` only for a genuinely new payload,
    /// `false` for repeats (unrelated `assistConfiguration` changes re-set the same effects).
    func testPlaybackEffectsBoxReportsWhetherEffectsChanged() {
        let box = MediaLUT.PlaybackEffectsBox()

        XCTAssertFalse(box.set(effects: ImageEffectsCompositor.ResolvedEffects()))

        var effects = ImageEffectsCompositor.ResolvedEffects()
        effects.peaking = PeakingSettings()
        XCTAssertTrue(box.set(effects: effects))
        XCTAssertFalse(box.set(effects: effects))

        effects.peaking?.sensitivity = .high
        XCTAssertTrue(box.set(effects: effects))

        XCTAssertTrue(box.set(effects: ImageEffectsCompositor.ResolvedEffects()))
    }

    /// The watch relay now encodes the display-baked frame (an RGBAh 16-bit-float bitmap out of the
    /// LUT bake), not a camera JPEG. Guard the encode path end to end for that input: downscale to
    /// the target width and produce a decodable JPEG.
    func testWatchThumbnailEncodesFloatBakedFrame() async throws {
        // Render a gradient through the same context settings as LiveFrameRenderer's bake output.
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAh, .workingColorSpace: space,
        ])
        let gradient = CIFilter(
            name: "CISmoothLinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 1024, y: 576),
                "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.3),
                "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.7),
            ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 576))
        let cg = try XCTUnwrap(
            context.createCGImage(
                gradient, from: gradient.extent, format: .RGBAh, colorSpace: space)
        )
        let baked = UIImage(cgImage: cg)

        let encoded = await WatchRelay.thumbnailJPEG(from: baked, maxWidth: 416, quality: 0.3)
        let jpeg = try XCTUnwrap(encoded)
        let decoded = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(decoded.size.width, 416, accuracy: 2)
        XCTAssertEqual(
            decoded.size.height, (416 * 576 / 1024 as CGFloat).rounded(), accuracy: 2)
    }

    /// Metal and demo feeds reach the relay as raw images. Guard the real Watch encode path: it
    /// must apply the selected monitor LUT after adaptive downscaling, then survive JPEG decoding
    /// with pixels materially different from the ungraded log source.
    func testWatchThumbnailAppliesLUTToRawFrameBeforeJPEG() async throws {
        let encodedHighlight = ExposureToneCurve.redLog3G10.encode(linearLight: 0.18 * 2)
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 576)).image {
            context in
            UIColor(
                red: encodedHighlight, green: encodedHighlight, blue: encodedHighlight, alpha: 1
            ).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 1024, height: 576)))
        }
        var effects = LiveImageEffects()
        effects.lut = .builtIn(.log3G10Rec709)
        let renderer = LiveFrameRenderer(fileStore: LUTFileStore())

        let rawJPEG = await WatchRelay.thumbnailJPEG(
            from: source, maxWidth: 416, quality: 0.32)
        let gradedJPEG = await WatchRelay.thumbnailJPEG(
            from: source, applying: effects, renderer: renderer,
            maxWidth: 416, quality: 0.32)
        let rawImage = try XCTUnwrap(UIImage(data: try XCTUnwrap(rawJPEG)))
        let gradedImage = try XCTUnwrap(UIImage(data: try XCTUnwrap(gradedJPEG)))

        XCTAssertLessThanOrEqual(try XCTUnwrap(gradedImage.cgImage?.width), 416)
        XCTAssertLessThanOrEqual(try XCTUnwrap(gradedImage.cgImage?.height), 234)
        let rawPixel = rgbaPixel(rawImage)
        let gradedPixel = rgbaPixel(gradedImage)
        let colorDistance = zip(rawPixel.prefix(3), gradedPixel.prefix(3))
            .reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        XCTAssertGreaterThan(colorDistance, 30)
    }
}

extension RunnerTests {
    /// The anchor is the operator's own level, not mid-scale. Arming the shutter used to set every
    /// phone to half volume — remote or not — and drag whatever they were listening to with it.
    /// All the mechanism needs is a step of room each way, which nearly every real setting has.
    func testTheVolumeAnchorLeavesAnOrdinaryLevelExactlyWhereItIs() {
        // Anything with a step of headroom either side is its own anchor: nothing to hear.
        for volume in stride(from: Float(0.0625), through: Float(0.9375), by: 0.0625) {
            XCTAssertEqual(
                BluetoothShutterMonitor.anchor(forCurrentVolume: volume), volume, accuracy: 0.0001,
                "volume \(volume) should not be moved")
        }
        // Only the rails move, and only by the one step a press needs to be visible.
        XCTAssertEqual(
            BluetoothShutterMonitor.anchor(forCurrentVolume: 0), 0.0625, accuracy: 0.0001)
        XCTAssertEqual(
            BluetoothShutterMonitor.anchor(forCurrentVolume: 1), 0.9375, accuracy: 0.0001)
        // Both rails keep room to MOVE, which is the whole reason the anchor exists: a press
        // either way from the anchored value lands somewhere detectably different.
        for rail in [Float(0), Float(1)] {
            let anchored = BluetoothShutterMonitor.anchor(forCurrentVolume: rail)
            XCTAssertGreaterThan(anchored, 0)
            XCTAssertLessThan(anchored, 1)
        }
    }

    /// The decision travels with whatever anchor the session took, not a hardcoded half.
    func testTheTriggerDecisionFollowsTheOperatorsOwnAnchor() {
        let t0: TimeInterval = 100
        let anchor: Float = 0.25
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.25, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: anchor),
            "the anchor's own echo is never a press")
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.3125, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: anchor))
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.1875, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: anchor))
        // 0.5 is just a volume now — at this anchor it is a press, not a resting place.
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: anchor))
    }

    /// The Bluetooth-shutter volume decision: any move off the mid-scale anchor triggers (shutter
    /// remotes send volume-up or volume-down depending on model), but not within the debounce
    /// window after a trigger nor within the echo window after a programmatic re-anchor; the
    /// anchor value itself (our own re-anchor landing) never triggers.
    func testBluetoothShutterTriggerDecision() {
        let t0: TimeInterval = 100
        // Presses in BOTH directions, well clear of both windows → trigger.
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: 0.5))
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.4375, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: 0.5))
        // The anchor echo (same value) never triggers.
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: 0.5))
        // Inside the debounce window after a trigger → suppressed; after it → fires again.
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: t0 + 0.3, lastTriggerAt: t0, lastAnchorAt: t0, anchor: 0.5))
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625,
                now: t0 + BluetoothShutterMonitor.debounceInterval + 0.01,
                lastTriggerAt: t0, lastAnchorAt: t0, anchor: 0.5))
        // Right after a programmatic re-anchor, a rise is its echo → suppressed.
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: t0 + 0.1, lastTriggerAt: 0, lastAnchorAt: t0, anchor: 0.5))
    }

    /// KVO is the primary detector and the private notification is a rail fallback. On releases
    /// that emit both for one press, the shared debounce must collapse them to one record toggle.
    func testBluetoothShutterDeduplicatesObservationSources() {
        let firstEventAt: TimeInterval = 200
        XCTAssertTrue(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625, now: firstEventAt, lastTriggerAt: 0, lastAnchorAt: 0, anchor: 0.5
            ))
        XCTAssertFalse(
            BluetoothShutterMonitor.isTrigger(
                newVolume: 0.5625,
                now: firstEventAt + 0.01,
                lastTriggerAt: firstEventAt,
                lastAnchorAt: firstEventAt, anchor: 0.5))
    }

    func testBluetoothShutterReportsWhyVolumeEventsAreIgnored() {
        let t0: TimeInterval = 300
        XCTAssertEqual(
            BluetoothShutterMonitor.triggerDecision(
                newVolume: 0.5, now: t0, lastTriggerAt: 0, lastAnchorAt: 0, anchor: 0.5),
            .atAnchor)
        XCTAssertEqual(
            BluetoothShutterMonitor.triggerDecision(
                newVolume: 0.5625, now: t0 + 0.1, lastTriggerAt: t0, lastAnchorAt: 0, anchor: 0.5),
            .debounced)
        XCTAssertEqual(
            BluetoothShutterMonitor.triggerDecision(
                newVolume: 0.5625, now: t0 + 0.1, lastTriggerAt: 0, lastAnchorAt: t0, anchor: 0.5),
            .selfInflicted)
    }

    func testBluetoothShutterRunsOnlyForEnabledActiveFrontLiveView() {
        XCTAssertTrue(
            BluetoothShutterMonitor.shouldRun(
                enabled: true, monitorPresented: true, liveViewFront: true,
                applicationIsActive: true, audioSessionAvailable: true))
        XCTAssertFalse(
            BluetoothShutterMonitor.shouldRun(
                enabled: false, monitorPresented: true, liveViewFront: true,
                applicationIsActive: true, audioSessionAvailable: true))
        XCTAssertFalse(
            BluetoothShutterMonitor.shouldRun(
                enabled: true, monitorPresented: false, liveViewFront: true,
                applicationIsActive: true, audioSessionAvailable: true))
        // Settings / Media / Tool Library covering the monitor must disarm the rocker — a press
        // inside a menu may not start recording.
        XCTAssertFalse(
            BluetoothShutterMonitor.shouldRun(
                enabled: true, monitorPresented: true, liveViewFront: false,
                applicationIsActive: true, audioSessionAvailable: true))
        XCTAssertFalse(
            BluetoothShutterMonitor.shouldRun(
                enabled: true, monitorPresented: true, liveViewFront: true,
                applicationIsActive: false, audioSessionAvailable: true))
        XCTAssertFalse(
            BluetoothShutterMonitor.shouldRun(
                enabled: true, monitorPresented: true, liveViewFront: true,
                applicationIsActive: true, audioSessionAvailable: false))
    }

    @MainActor
    func testBluetoothShutterFindsNestedSystemVolumeSlider() {
        let volumeView = UIView()
        let container = UIView()
        let slider = UISlider()
        container.addSubview(slider)
        volumeView.addSubview(container)

        XCTAssertIdentical(BluetoothShutterMonitor.firstSlider(in: volumeView), slider)
    }
}

// MARK: - Media favorite / rating sync

extension RunnerTests {
    private func mediaRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func mediaClip(
        _ filename: String, stars: Int? = nil, favorite: Bool = false, captureDate: String = ""
    ) -> MediaClip {
        var clip = MediaClip(
            cameraID: "cam", filename: filename, handle: nil, storageID: nil,
            sizeBytes: 0, captureDate: captureDate)
        clip.starRating = stars
        clip.isFavorite = favorite
        return clip
    }

    /// A shot favorited during a shoot must count under Favorites whether the signal is the
    /// local heart or a camera star — this is exactly the tab's filter predicate.
    func testIsFavoritedCountsLocalHeartOrAnyCameraStar() {
        XCTAssertTrue(mediaClip("A.JPG", favorite: true).isFavorited)
        XCTAssertTrue(mediaClip("B.JPG", stars: 1).isFavorited)
        XCTAssertTrue(mediaClip("C.JPG", stars: 5).isFavorited)
        XCTAssertFalse(mediaClip("D.JPG").isFavorited)
        XCTAssertFalse(mediaClip("E.JPG", stars: 0).isFavorited)

        let clips = [
            mediaClip("A.JPG", favorite: true), mediaClip("B.JPG", stars: 2), mediaClip("D.JPG"),
        ]
        XCTAssertEqual(clips.filter(\.isFavorited).map(\.filename), ["A.JPG", "B.JPG"])
    }

    /// The write-through a rating write performs (`mirrorRatingIntoIndex` → `store.update`)
    /// persists both the star and the derived favorite flag, offline (no camera in this test).
    func testMediaIndexUpdateWritesStarRatingAndFavoriteThrough() throws {
        let root = mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        store.upsertBatch([mediaClip("DSC_0001.JPG")], cameraID: "cam")

        store.update(cameraID: "cam", filename: "DSC_0001.JPG") {
            $0.starRating = 3
            $0.isFavorite = true
        }

        let row = try XCTUnwrap(
            store.list(cameraID: "cam").first { $0.filename == "DSC_0001.JPG" })
        XCTAssertEqual(row.starRating, 3)
        XCTAssertTrue(row.isFavorite)
        XCTAssertTrue(row.isFavorited)
    }

    /// Instant playback rates a raw handle the index has never seen — the mirror must upsert.
    func testMediaIndexUpdateUpsertsRowWhenClipNotYetIndexed() throws {
        let root = mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)

        store.update(cameraID: "cam", filename: "DSC_0009.JPG") {
            $0.starRating = 5
            $0.isFavorite = true
        }

        let row = try XCTUnwrap(
            store.list(cameraID: "cam").first { $0.filename == "DSC_0009.JPG" })
        XCTAssertEqual(row.starRating, 5)
        XCTAssertTrue(row.isFavorited)
    }

    /// A RAW+JPEG pair mirrors onto the JPEG row the grid renders; the RAW sibling stays untouched.
    func testMediaRatingMirrorsOntoJPEGRowLeavingRawSiblingUntouched() throws {
        let root = mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        store.upsertBatch([mediaClip("DSC_0001.JPG"), mediaClip("DSC_0001.NEF")], cameraID: "cam")

        store.update(cameraID: "cam", filename: "DSC_0001.JPG") {
            $0.starRating = 4
            $0.isFavorite = true
        }

        let rows = store.list(cameraID: "cam")
        let jpeg = try XCTUnwrap(rows.first { $0.filename == "DSC_0001.JPG" })
        let nef = try XCTUnwrap(rows.first { $0.filename == "DSC_0001.NEF" })
        XCTAssertEqual(jpeg.starRating, 4)
        XCTAssertTrue(jpeg.isFavorited)
        XCTAssertNil(nef.starRating)
        XCTAssertFalse(nef.isFavorited)
    }

    /// Index rows written before `starRating` existed decode to nil (additive Codable) — an
    /// unrated legacy row is not silently promoted into Favorites.
    func testMediaClipDecodesLegacyIndexRowWithoutStarRatingAsNil() throws {
        let legacy = """
            {"cameraID":"cam","filename":"DSC_0001.JPG","sizeBytes":100,\
            "captureDate":"20260724T101500","isFavorite":false,\
            "frameioStatus":"notUploaded","exportStatus":"none"}
            """
        let clip = try JSONDecoder().decode(MediaClip.self, from: Data(legacy.utf8))
        XCTAssertNil(clip.starRating)
        XCTAssertFalse(clip.isFavorited)
    }

    /// Rating-descending sort clusters the highest-starred shots at the top for culling.
    func testRatingSortClustersHighestStarsFirst() {
        let clips = [
            mediaClip("A.JPG", stars: 0), mediaClip("B.JPG", stars: 5),
            mediaClip("C.JPG", stars: 2), mediaClip("D.JPG"),
        ]
        let sorted = MediaClipSorting.sort(clips, order: .rating).map(\.filename)
        XCTAssertEqual(sorted.first, "B.JPG")
        XCTAssertEqual(sorted[1], "C.JPG")
        XCTAssertEqual(Set(sorted.suffix(2)), ["A.JPG", "D.JPG"])
    }

    /// A formatted card recycles PTP handles. Removal of those handles must drop the
    /// remote-only old filename so the next fetch can install the new object.
    func testApplyCameraRemovalDropsRemoteOnlyRowWhenHandleIsSuperseded() {
        let root = mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        var clip = mediaClip("DSC_0001.JPG")
        clip.handle = 10
        clip.storageID = 0x0001_0001
        store.upsertBatch([clip], cameraID: "cam")

        let removed = store.applyCameraRemoval(
            cameraID: "cam",
            removedHandles: [MediaObjectHandle(storageID: 0x0001_0001, handle: 10)],
            hasLocalFile: { _ in false }
        )

        XCTAssertEqual(removed, ["DSC_0001.JPG"])
        XCTAssertTrue(store.list(cameraID: "cam").isEmpty)
    }

    /// Intentionally downloaded copies survive a card generation change as local-only rows.
    func testApplyCameraRemovalKeepsDownloadedCopyWhenHandleLeavesTheCard() throws {
        let root = mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        var clip = mediaClip("C0001.MOV")
        clip.handle = 4
        clip.storageID = 0x0001_0001
        clip.sizeBytes = 4
        store.upsertBatch([clip], cameraID: "cam")
        let url = try store.localURL(cameraID: "cam", filename: "C0001.MOV")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: url)

        let removed = store.applyCameraRemoval(
            cameraID: "cam",
            removedHandles: [MediaObjectHandle(storageID: 0x0001_0001, handle: 4)],
            hasLocalFile: { candidate in
                store.cachedByteCount(cameraID: candidate.cameraID, filename: candidate.filename)
                    > 0
            }
        )

        XCTAssertTrue(removed.isEmpty)
        let row = try XCTUnwrap(store.list(cameraID: "cam").first)
        XCTAssertEqual(row.filename, "C0001.MOV")
        XCTAssertNil(row.handle)
        XCTAssertNil(row.storageID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// Camera-bucket cache is not source of truth — clearing it must drop `index.json`.
    func testClearingCameraCacheDropsTheIndex() {
        let root = mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        store.upsertBatch([mediaClip("DSC_0001.JPG")], cameraID: "cam")

        store.clearCache(cameraID: "cam", preservingIndex: false)

        XCTAssertTrue(store.list(cameraID: "cam").isEmpty)
    }

    /// The on-device library has no camera to rebuild from, so its index survives a cache clear.
    func testClearingLocalCachePreservesTheIndex() {
        let root = mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaClipStore(root: root)
        store.upsertBatch([mediaClip("IMPORT.MOV")], cameraID: MediaClipStore.localBucketID)

        store.clearCache(cameraID: MediaClipStore.localBucketID, preservingIndex: true)

        XCTAssertEqual(
            store.list(cameraID: MediaClipStore.localBucketID).map(\.filename), ["IMPORT.MOV"])
    }

    // MARK: - Fused peaking kernel vs the reference filter chain

    /// The single-pass CIKL detector must reproduce the filter chain exactly — every constant in
    /// `Peaking` was calibrated against the chain, so any divergence here is the kernel being
    /// WRONG, not different. The frame mixes the four cases that matter: hard sharp edges, fine
    /// texture, a defocused (pre-blurred) region, and per-pixel noise dense enough to exercise the
    /// gate's partial band. Checked at every sensitivity because the gains and biases change with
    /// it.
    /// The frame the peaking equivalence tests measure on: sharp strokes and fine texture on the
    /// left half, the same content defocused on the right, and sensor-like noise over all of it —
    /// so a detector that confuses grain for detail, or blur for focus, separates here.
    private func peakingProbeFrame(width w: Int, height h: Int) throws -> CIImage {
        // Scale pinned to 1 — the renderer defaults to the screen scale, which would silently make
        // the frame 3x the stated size and every readback a partial crop of it.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let frame = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
            .image { ctx in
                let cg = ctx.cgContext
                cg.setFillColor(UIColor(white: 0.3, alpha: 1).cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
                var seed: UInt64 = 0x5_DEEC_E66D
                func rand() -> Double {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return Double(seed >> 33) / Double(UInt64(1) << 31)
                }
                // Sharp strokes and fine texture on the left half.
                for i in 0..<24 {
                    cg.setFillColor(UIColor(white: i % 2 == 0 ? 0.85 : 0.12, alpha: 1).cgColor)
                    cg.fill(CGRect(x: 8 + i * 5, y: 10, width: 2, height: 70))
                    cg.fill(CGRect(x: 8, y: 90 + i * 3, width: 130, height: 1))
                }
                // Noise everywhere, including over the edges.
                for _ in 0..<4_000 {
                    cg.setFillColor(UIColor(white: rand(), alpha: 1).cgColor)
                    cg.fill(
                        CGRect(
                            x: Int(rand() * Double(w - 1)), y: Int(rand() * Double(h - 1)),
                            width: 1, height: 1))
                }
            }
        let source = try XCTUnwrap(CIImage(image: frame, options: [.colorSpace: NSNull()]))
        // Defocus the right half by pre-blurring — the ratio must read it as out of focus.
        let blurredHalf =
            source
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.0])
            .cropped(to: CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        return blurredHalf.composited(over: source).cropped(to: source.extent)
    }

    /// `Peaking.overlay` is the transcription target for all three Android shells, so it has to be
    /// a transcription of what iOS actually renders. This test is the only thing standing behind
    /// that, and without it "Android matches iOS" is an intention rather than a fact.
    ///
    /// Checked end to end against the composited frame rather than against an intermediate mask, so
    /// every part of the port lands here as pixels: the operator's tap quad, the measured re-blur
    /// weights, the ratio ceiling, the ramps being LINEAR rather than the smoothstep a shader
    /// reaches for by habit, the closing's five-point element, and the order the dark hairline and
    /// the stroke composite in.
    func testSharedCoreReferenceReproducesTheRenderedDetector() throws {
        let w = 320
        let h = 180
        let frame = try peakingProbeFrame(width: w, height: h)

        // Colour management off and float readback: this compares the MATH, so nothing may convert
        // between the two paths. Under the shipping BGRA8 space the chain quantises every one of its
        // ~25 intermediates to 1/255, which is below the detector's own gates.
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false,
        ])
        func rendered(_ image: CIImage) -> [Float] {
            var out = [Float](repeating: 0, count: w * h * 4)
            context.render(
                image, toBitmap: &out, rowBytes: w * 16,
                bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
            return out
        }

        // `CIContext.render(toBitmap:)` writes buffer row 0 as the image's TOP row — probed, not
        // assumed — which is the same top-down order `Peaking.overlay` reads, so the operator's
        // `+y` tap lands on the same neighbour in both. Getting this backwards would shift the
        // whole overlay by one row, which is exactly the sort of thing this test exists to catch.
        let base = rendered(frame)
        let grey: [Double] = (0..<(w * h)).map { i -> Double in
            let red = Double(base[i * 4])
            let green = Double(base[i * 4 + 1])
            let blue = Double(base[i * 4 + 2])
            return (red + green + blue) / 3
        }
        let dark = Peaking.underColor

        for sensitivity in Peaking.Sensitivity.allCases {
            let settings = PeakingSettings(color: .red, sensitivity: sensitivity)
            let actual = rendered(
                ImageEffectsCompositor.applyPeaking(
                    over: frame, source: frame, settings: settings, extent: frame.extent))
            let reference = Peaking.overlay(
                grey: grey, width: w, height: h, sensitivity: sensitivity)
            let tint = settings.color.rgb

            /// The hairline first, then the stroke over it — `composite`'s two blends.
            func expected(_ baseValue: Float, _ darkValue: Double, _ tintValue: Double, _ i: Int)
                -> Double
            {
                let under = reference.under[i]
                let stroke = reference.stroke[i]
                let withUnder = Double(baseValue) * (1 - under) + darkValue * under
                return withUnder * (1 - stroke) + tintValue * stroke
            }

            var painted = 0
            var worst = 0.0
            var worstAt = (0, 0)
            var beyondTolerance = 0
            for i in 0..<(w * h) {
                if reference.stroke[i] > 0.35 { painted += 1 }
                let channels = [
                    expected(base[i * 4], dark.red, tint.0, i),
                    expected(base[i * 4 + 1], dark.green, tint.1, i),
                    expected(base[i * 4 + 2], dark.blue, tint.2, i),
                ]
                for (channel, want) in channels.enumerated() {
                    let delta = abs(Double(actual[i * 4 + channel]) - want)
                    if delta > worst {
                        worst = delta
                        worstAt = (i % w, i / w)
                    }
                    if delta > 2.0 / 255 { beyondTolerance += 1 }
                }
            }
            // The frame must actually paint, or an all-zero overlay would agree with anything.
            XCTAssertGreaterThan(
                painted, 200, "\(sensitivity): probe frame drew almost nothing to compare")
            // 2/255 absorbs float ordering across the graph's passes; a formula divergence moves
            // whole strokes, not a handful of channels on a ramp knee.
            XCTAssertLessThan(
                Double(beyondTolerance) / Double(w * h * 3), 0.001,
                "\(sensitivity): \(beyondTolerance) of \(w * h * 3) channels differ by >2/255, "
                    + "worst \(worst) at \(worstAt) (\(painted) px painted)")
        }
    }

    func testFusedPeakingMatchesFilterChainPixelForPixel() throws {
        try XCTSkipIf(
            !ImageEffectsCompositor.fusedPeakingAvailable,
            "fused peaking disabled on this OS (kernel missing or the runtime self-check found it "
                + "does not reproduce the chain) — chain fallback is in force, nothing to compare")
        let w = 320
        let h = 180
        let mixed = try peakingProbeFrame(width: w, height: h)
        let source = mixed

        // Float working space, deliberately NOT the shipping BGRA8: this test compares the MATH.
        // Under BGRA8 the chain quantises every intermediate to 1/255 across its ~25 passes — the
        // detector's own gates sit below one code value there, which is exactly the precision loss
        // the 8-bit switch was measured to cost — while the fused kernel holds float through its
        // single pass. Their shipping outputs therefore differ legitimately (the kernel is the
        // more faithful one); equality of the formulas is only decidable where both see exact
        // intermediates.
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: false,
        ])
        func rendered(_ image: CIImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h * 4)
            context.render(
                image, toBitmap: &out, rowBytes: w * 4,
                bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .BGRA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return out
        }

        for sensitivity in Peaking.Sensitivity.allCases {
            let settings = PeakingSettings(color: .red, sensitivity: sensitivity)
            let fused = rendered(
                ImageEffectsCompositor.applyPeaking(
                    over: mixed, source: mixed, settings: settings, extent: source.extent))
            let chain = rendered(
                ImageEffectsCompositor.applyPeakingFilterChain(
                    over: mixed, source: mixed, settings: settings, extent: source.extent))
            var worst = 0
            var differing = 0
            var inRing = 0
            var worstAt = (0, 0)
            let inset = Int(Peaking.edgeInset)
            for i in 0..<fused.count {
                let d = abs(Int(fused[i]) - Int(chain[i]))
                if d > worst {
                    worst = d
                    worstAt = ((i / 4) % w, (i / 4) / w)
                }
                if d > 1 {
                    differing += 1
                    let px = (i / 4) % w
                    let py = (i / 4) / w
                    if px < inset || py < inset || px >= w - inset || py >= h - inset {
                        inRing += 1
                    }
                }
            }
            // ±1/255 allows float-order-of-operations rounding; anything past that on more than a
            // stray pixel means a real formula divergence.
            XCTAssertLessThanOrEqual(
                differing, 8,
                "\(sensitivity): \(differing) channels differ by >1/255 (\(inRing) of them in the "
                    + "\(inset)px inset ring), worst \(worst) at \(worstAt)")
        }
    }

    // MARK: - Live-feed bake resolution

    /// A 16:9 feed on a 2.17:1 panel bakes the WHOLE source at source resolution: fit, never
    /// crop (#115) — the present letterboxes, so no source pixel is ever discarded here.
    func testFeedBakeKeepsSourceResolutionAndItsOwnAspect() {
        let size = MonitorFrameBaker.bakeSize(
            source: CGSize(width: 1_024, height: 576),
            drawable: CGSize(width: 2_868, height: 1_320))

        XCTAssertEqual(size, CGSize(width: 1_024, height: 576))
    }

    /// A source wider than the drawable downscales uniformly — the SOURCE's aspect survives,
    /// because the present letterboxes rather than the bake cropping (#115).
    func testFeedBakeDownscalesPreservingTheSourceAspect() {
        let size = MonitorFrameBaker.bakeSize(
            source: CGSize(width: 1_024, height: 256),
            drawable: CGSize(width: 800, height: 600))

        XCTAssertEqual(size.width, 800, accuracy: 0.5)
        XCTAssertEqual(size.width / size.height, 1_024.0 / 256.0, accuracy: 0.001)
    }

    /// Demo stills out-resolve the panel. Baking at their size would render pixels that can never
    /// be shown — slower than the drawable-sized path this replaced — so it clamps.
    func testFeedBakeClampsToDrawableWhenSourceOutResolvesThePanel() {
        let drawable = CGSize(width: 1_024, height: 768)

        XCTAssertEqual(
            MonitorFrameBaker.bakeSize(
                source: CGSize(width: 4_032, height: 3_024), drawable: drawable),
            drawable)
    }

    /// An empty or infinite source extent (a CI generator with no bounds) falls back to the drawable.
    func testFeedBakeFallsBackToDrawableForADegenerateSource() {
        let drawable = CGSize(width: 1_024, height: 768)

        XCTAssertEqual(
            MonitorFrameBaker.bakeSize(source: .zero, drawable: drawable), drawable)
        XCTAssertEqual(
            MonitorFrameBaker.bakeSize(source: CGRect.infinite.size, drawable: drawable), drawable
        )
    }

    // MARK: - Hardware JPEG decode

    /// The decoder against a REAL ZR live-view frame, not a synthetic baseline JPEG.
    ///
    /// The MockFeed test below passed while the camera's own frames silently fell back to ImageIO
    /// on device — camera motion-JPEG differs from `UIImage.jpegData` output (subsampling,
    /// restart markers), and a fallback nobody sees means every feature living on the hardware
    /// path (the noise filter) quietly never runs. The peaking corpus carries genuine
    /// LiveViewObjects, so this is the frame class the device actually decodes.
    func testHardwareJPEGDecodeTakesARealZRLiveViewFrame() throws {
        #if targetEnvironment(simulator)
            // The simulator's software VideoToolbox stack is not the device's: it refuses this
            // frame class while macOS accepts the identical bytes (probed step-by-step, forced
            // 420v AND native). Device truth comes from the on-feed debug key, which reports the
            // decode path and the filter's verdict live (`LiveDenoiseSwitch.pipelineReport`).
            throw XCTSkip("simulator VideoToolbox refuses the ZR frame class")
        #else
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // RunnerTests
                .deletingLastPathComponent()  // ios
                .appendingPathComponent("Tests/OpenZCineCoreTests/Fixtures/peaking/zr-sweep-12.bin")
            let object = try Data(contentsOf: url)
            let soi = try XCTUnwrap(
                object.firstRange(of: Data([0xFF, 0xD8, 0xFF])), "no JPEG in the fixture")
            let jpeg = object[soi.lowerBound...]
            let header = try XCTUnwrap(JPEGPixelBufferDecoder.dimensions(of: jpeg))
            let decoder = JPEGPixelBufferDecoder()
            let buffer = try XCTUnwrap(
                decoder.decode(jpeg),
                "the hardware decoder refuses a real ZR live-view frame (\(decoder.report))")
            XCTAssertGreaterThanOrEqual(CVPixelBufferGetWidth(buffer), header.width)
            XCTAssertGreaterThanOrEqual(CVPixelBufferGetHeight(buffer), header.height)
        #endif
    }
    // MARK: - Hardware JPEG decode

    /// The camera's live view is motion JPEG, and `420v` is what a JPEG already is inside. This
    /// decoder is the whole reason the super-resolution input needs no colour conversion — so it
    /// has to actually produce that format, at the right size, with real content in it.
    func testHardwareJPEGDecodeProducesA420vBufferWithRealPixels() throws {
        let image = try XCTUnwrap(UIImage(named: "MockFeed"), "MockFeed asset missing")
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let header = try XCTUnwrap(
            JPEGPixelBufferDecoder.dimensions(of: jpeg), "dimensions must come off the header")

        let buffer = try XCTUnwrap(
            JPEGPixelBufferDecoder().decode(jpeg), "hardware JPEG decode returned nothing")

        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(buffer),
            JPEGPixelBufferDecoder.pixelFormat,
            "the decoder must land in the model's own format, not RGB")
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), header.width)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), header.height)

        // A buffer of one constant value is what every failure so far looked like — flat green —
        // so "it decoded" is not the claim; "it decoded a picture" is.
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let rows = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytes = luma.assumingMemoryBound(to: UInt8.self)
        var lowest = UInt8.max
        var highest = UInt8.min
        for row in stride(from: 0, to: rows, by: 8) {
            for column in stride(from: 0, to: CVPixelBufferGetWidthOfPlane(buffer, 0), by: 8) {
                let value = bytes[row * rowBytes + column]
                lowest = min(lowest, value)
                highest = max(highest, value)
            }
        }
        XCTAssertGreaterThan(
            Int(highest) - Int(lowest), 16,
            "the luma plane is nearly uniform — this decoded to a flat field, not a frame")
    }

    // MARK: - Feed upscaler availability

    /// The picker lists only what this device can run, and the Lanczos floor is the one thing every
    /// device can — the simulator, which has neither MetalFX nor VideoToolbox super resolution,
    /// lists that alone.
    func testOfferedUpscalersAreAllRunnableAndAlwaysIncludeTheFloor() {
        XCTAssertTrue(MonitorUpscaler.supportedOnThisDevice.contains(.off))
        XCTAssertTrue(MonitorUpscaler.supportedOnThisDevice.contains(.lanczos))
        for upscaler in MonitorUpscaler.supportedOnThisDevice {
            XCTAssertTrue(
                upscaler.isSupportedOnThisDevice, "\(upscaler) is offered but not runnable")
        }
        #if targetEnvironment(simulator)
            XCTAssertEqual(MonitorUpscaler.supportedOnThisDevice, [.off, .lanczos])
        #endif
    }

    /// A stored choice outlives the device it was made on. Whatever it names, what comes back is
    /// something this device actually runs — never a setting that reads as active while the
    /// renderer quietly does something else.
    func testAStoredChoiceThisDeviceCannotRunResolvesToOneItCan() {
        XCTAssertTrue(MonitorUpscaler.supported(or: nil).isSupportedOnThisDevice)
        for upscaler in MonitorUpscaler.allCases {
            XCTAssertTrue(MonitorUpscaler.supported(or: upscaler).isSupportedOnThisDevice)
        }
        XCTAssertEqual(MonitorUpscaler.supported(or: .lanczos), .lanczos)
    }

    /// An untouched install starts at the floor, on every device — the picker is how an operator
    /// spends GPU on the feed, not something they have to find to stop spending it.
    func testTheDefaultUpscalerIsTheFastFloorEvenWhereBetterOnesExist() {
        XCTAssertEqual(MonitorUpscaler.supported(or: nil), .lanczos)
        XCTAssertEqual(MonitorUpscaler.lanczos.rawValue, "Fast")
        // A stored choice still wins wherever the device can run it — the default is a starting
        // point, not a cap.
        for upscaler in MonitorUpscaler.supportedOnThisDevice {
            XCTAssertEqual(MonitorUpscaler.supported(or: upscaler), upscaler)
        }
    }

    // MARK: - Super-resolution input size

    /// The low-latency processor tops out at 960×960, and a Quality-preset ZR feed is 1024×576 —
    /// over the ceiling, which is why it offered no scale factor and the option did nothing. A 6%
    /// shrink clears it and buys a ×2 ML upscale of the result.
    func testSuperResolutionShrinksABakeThatOutsizesTheProcessor() {
        let input = MonitorUpscaler.superResolutionInputSize(
            source: (1_024, 576), target: (2_347, 1_320), scale: 0, maximum: (960, 960))

        XCTAssertEqual(input.width, 960)
        XCTAssertEqual(input.height, 540)
        // Uniform: the present letterboxes against this aspect, so it must not change.
        XCTAssertEqual(
            Double(input.width) / Double(input.height), 1_024.0 / 576.0, accuracy: 0.01)
    }

    /// Never an upscale — a source already inside the limit is handed over untouched, and
    /// enlarging before the model would only give it invented detail to sharpen.
    func testSuperResolutionLeavesASourceInsideTheLimitAlone() {
        let input = MonitorUpscaler.superResolutionInputSize(
            source: (640, 480), target: (1_280, 960), scale: 2, maximum: (960, 960))

        XCTAssertEqual(input.width, 640)
        XCTAssertEqual(input.height, 480)
    }

    /// Height can be the binding limit as easily as width.
    func testSuperResolutionShrinksToWhicheverDimensionBindsFirst() {
        let input = MonitorUpscaler.superResolutionInputSize(
            source: (1_000, 2_000), target: (4_000, 8_000), scale: 0, maximum: (1_440, 1_080))

        XCTAssertEqual(input.height, 1_080)
        XCTAssertEqual(input.width, 540)
    }

    /// A fixed ×4 against a 2347×1320 panel produced 4096×2304 — 75 MB a surface, three deep,
    /// and the drawable queue starved until `nextDrawable` timed out on every frame. The input
    /// has to be sized so the model's OUTPUT lands on the panel, not far past it.
    func testSuperResolutionShrinksTheInputSoAFixedFactorLandsOnThePanel() {
        let input = MonitorUpscaler.superResolutionInputSize(
            source: (1_024, 576), target: (2_347, 1_320), scale: 4, maximum: (1_440, 1_080))

        // ×4 of this clears the panel with nothing meaningful left over.
        XCTAssertEqual(Double(input.width) * 4, 2_347, accuracy: 8)
        XCTAssertEqual(Double(input.height) * 4, 1_320, accuracy: 8)
        XCTAssertLessThan(input.width, 1_024)
    }

    /// When the factor cannot reach the panel even from the whole source, there is nothing to
    /// give back — the fit enlarges the remainder and the model gets every pixel available.
    func testSuperResolutionKeepsTheWholeSourceWhenTheFactorCannotReachThePanel() {
        let input = MonitorUpscaler.superResolutionInputSize(
            source: (960, 540), target: (2_347, 1_320), scale: 2, maximum: (1_440, 1_080))

        XCTAssertEqual(input.width, 960)
        XCTAssertEqual(input.height, 540)
    }

    // MARK: - Super-resolution scale selection

    /// The model only offers discrete factors, so the one it runs at has to CLEAR the blow-up the
    /// present needs — 1024×576 into a 2868×1320 panel is 2.8×, and 2× would leave Lanczos to
    /// enlarge the model's own output by the rest, which is the whole thing being paid for.
    func testSuperResolutionScaleClearsTheRatioSoTheFitOnlyShrinks() {
        XCTAssertEqual(
            MonitorUpscaler.superResolutionScale(offered: [1.5, 2, 3], ratio: 2.8), 3)
        XCTAssertEqual(
            MonitorUpscaler.superResolutionScale(offered: [1.5, 2, 3], ratio: 2), 2)
    }

    /// When nothing on offer clears the ratio the largest gets as close as the processor allows —
    /// a softer last leg beats refusing the model outright.
    func testSuperResolutionScaleFallsToTheLargestOfferedWhenNoneClearsTheRatio() {
        XCTAssertEqual(MonitorUpscaler.superResolutionScale(offered: [1.5, 2], ratio: 2.8), 2)
    }

    /// An empty list is the processor saying it does not serve this source size at all.
    func testSuperResolutionScaleIsNilWhenNoFactorsAreOffered() {
        XCTAssertNil(MonitorUpscaler.superResolutionScale(offered: [], ratio: 2.8))
    }

    /// Order comes from the processor, not from us — an unsorted list must not pick a factor that
    /// happens to be first.
    func testSuperResolutionScaleDoesNotTrustTheOfferedOrder() {
        XCTAssertEqual(MonitorUpscaler.superResolutionScale(offered: [3, 1.5, 2], ratio: 1.6), 2)
    }

    /// A layout animation walks the drawable through a dozen sizes — a device log caught the
    /// MetalFX scaler rebuilt five times across one. Changing factor restarts the processor and
    /// loads an ML model on the draw thread, so a running factor that still clears the ratio is
    /// kept rather than traded down.
    func testSuperResolutionScaleKeepsARunningFactorThatStillClearsTheRatio() {
        XCTAssertEqual(
            MonitorUpscaler.superResolutionScale(offered: [1.5, 2, 3], ratio: 1.3, held: 3), 3)
        XCTAssertEqual(
            MonitorUpscaler.superResolutionScale(offered: [1.5, 2, 3], ratio: 2, held: 2), 2)
    }

    /// It is kept, not pinned: once the panel outgrows what the running factor covers, the model
    /// has to be restarted at one that clears it or the fit goes back to enlarging its output.
    func testSuperResolutionScaleReplacesARunningFactorThatNoLongerClearsTheRatio() {
        XCTAssertEqual(
            MonitorUpscaler.superResolutionScale(offered: [1.5, 2, 3], ratio: 2.8, held: 2), 3)
    }

    /// The Focus dial is opt-in, and switching the default off must not overrule an operator who
    /// already made the choice — in either direction. The stored key IS the migration: it only
    /// exists once the FOCUS-popup toggle wrote it.
    @MainActor
    func testFocusDialDefaultsOffAndPreservesAnExplicitOperatorChoice() {
        let key = "mfDriveScrubEnabled"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // Fresh install / settings reset: nothing stored, so the dial is off — and a new model
        // (the relaunch case) reads the same answer.
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(PreferencesStore.loadMFScrubEnabled())
        XCTAssertFalse(NativeAppModel().mfDriveScrubEnabled)

        // An operator who deliberately switched the dial ON keeps it across the default change.
        PreferencesStore.saveMFScrubEnabled(true)
        XCTAssertTrue(PreferencesStore.loadMFScrubEnabled())
        XCTAssertTrue(NativeAppModel().mfDriveScrubEnabled)

        // …and one who deliberately switched it OFF is never migrated back on.
        PreferencesStore.saveMFScrubEnabled(false)
        XCTAssertFalse(PreferencesStore.loadMFScrubEnabled())
        XCTAssertFalse(NativeAppModel().mfDriveScrubEnabled)
    }

    /// Preference off hides the dial whatever else is true — mode included, since the chrome no
    /// longer gates it. (Visible-when-on needs a live focus mode from a camera; that is the
    /// simulator/hardware check.)
    @MainActor
    func testFocusDialStaysHiddenWhileThePreferenceIsOff() {
        let key = "mfDriveScrubEnabled"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let model = NativeAppModel()
        model.mfDriveScrubEnabled = false
        model.connection = .connected
        model.activePanel = nil

        XCTAssertFalse(model.showsMFDriveScrub)
    }

    /// #272: no focus-drive exit path may leave focus commands owned. Cancelling with nothing in
    /// flight, twice, and with no session must all be no-ops that leave the dial usable.
    @MainActor
    func testCancellingAFocusDriveIsAlwaysSafeAndNeverLatches() {
        let model = NativeAppModel()

        model.driveManualFocus(pulses: 400)
        model.cancelManualFocusDrive()
        model.cancelManualFocusDrive()

        // Nothing latched: the dial still reports a usable, re-armable position.
        model.resetMFDriveDial()
        XCTAssertEqual(model.mfDriveNetPulses, 0)
        XCTAssertNil(model.mfDriveAtEnd)
    }

    // MARK: - CODEC bit-depth pair (#276 follow-up)

    /// The Z6III's `MovFileType` enum: H.264 once, H.265 at both depths.
    private static let hevcBothDepthsEnum: [UInt32] = [0x0000_0801, 0x0001_0800, 0x0001_0A00]

    /// The codec drum lists ONE H.265 row, and the depth beside it is whatever the body's own
    /// readback reports — never a remembered UI choice that could disagree with the camera.
    /// Picking a depth writes that exact advertised value; settling the drum on a family carries
    /// the depth the body is currently recording at, and only falls back to the family's lowest
    /// advertised depth when the body's current depth is not one it offers.
    @MainActor
    func testCodecRowsCarryTheirBitDepthAndKeepItAcrossAFamilySwitch() {
        let model = NativeAppModel()
        model.cameraFileTypeModes = PTPCameraPropertyDecoders.fileTypeModes(
            fromEnum: Self.hevcBothDepthsEnum)

        // One row per family; only the two-variant family offers a depth choice.
        XCTAssertEqual(model.codecOptions, ["H.264", "H.265"])
        XCTAssertEqual(model.codecFamilies.map(\.offersBitDepthChoice), [false, true])
        let hevc = model.codecFamilies[1]
        XCTAssertEqual(hevc.depths.map(\.bitDepthLabel), ["8-bit", "10-bit"])

        // Body on H.265 8-bit: the drum centres on the family row, the pair reads 8-bit.
        model.applyDemoProperty(
            .movieFileType, data: PTPCameraPropertyWrite.fileType(raw: 0x0001_0800).data)
        XCTAssertEqual(model.cameraValue(for: .codec), "H.265")
        XCTAssertEqual(model.activeCodecMode?.bitDepth, 8)

        // Tapping "10-bit" writes the advertised 10-bit value.
        model.applyPickerValue("H.265 10-bit", for: .codec)
        XCTAssertEqual(model.activeCodecMode?.bitDepth, 10)
        XCTAssertEqual(model.cameraValue(for: .codec), "H.265")

        // Settling the drum on a family row carries the depth the body is on: H.264 is 8-bit, so
        // coming back to H.265 records 8-bit, and the pair — not a second row — moves it to 10.
        model.applyPickerValue("H.264", for: .codec)
        XCTAssertEqual(model.cameraValue(for: .codec), "H.264")
        model.applyPickerValue("H.265", for: .codec)
        XCTAssertEqual(model.activeCodecMode?.raw, 0x0001_0800)
        model.applyPickerValue("H.265 10-bit", for: .codec)
        XCTAssertEqual(model.activeCodecMode?.raw, 0x0001_0A00)
    }

    /// A depth the body is on but does not advertise for the codec being selected must not be
    /// carried across — the row falls back to that family's lowest advertised depth instead of
    /// writing a combination the body never offered.
    @MainActor
    func testAFamilyThatCannotHoldTheCurrentDepthFallsBackToItsLowest() {
        let model = NativeAppModel()
        // R3D NE is 12-bit only; H.265 is offered at 8 and 10.
        model.cameraFileTypeModes = PTPCameraPropertyDecoders.fileTypeModes(
            fromEnum: [0x0031_0C03, 0x0001_0800, 0x0001_0A00])
        model.applyDemoProperty(
            .movieFileType, data: PTPCameraPropertyWrite.fileType(raw: 0x0031_0C03).data)
        XCTAssertEqual(model.activeCodecMode?.bitDepth, 12)

        model.applyPickerValue("H.265", for: .codec)
        XCTAssertEqual(model.activeCodecMode?.raw, 0x0001_0800)
    }

    /// A body that advertises one variant of a codec gets no depth buttons at all — a dead button
    /// for a depth the body cannot record is exactly what this feature must not ship.
    @MainActor
    func testASingleVariantCodecOffersNoBitDepthChoice() {
        let model = NativeAppModel()
        model.cameraFileTypeModes = PTPCameraPropertyDecoders.fileTypeModes(
            fromEnum: [0x0031_0A03, 0x0002_0C02, 0x0001_0A01])
        XCTAssertEqual(model.codecOptions, ["R3D NE", "N-RAW", "H.265"])
        XCTAssertTrue(model.codecFamilies.allSatisfy { !$0.offersBitDepthChoice })
    }

    // MARK: - Picker option sourcing (#274)

    /// Every function picker must name the PTP property whose descriptor drives its drum. A nil
    /// here is a picker silently rendering the app's fixed union again — the whole #274 defect.
    /// (Which property each one names is asserted in the shared core's `PickerOptionPolicyTests`,
    /// where the descriptor decoders live; this target does not link the core module.)
    func testEveryFunctionPickerNamesItsDescriptorProperty() {
        let sourced: [(CameraPicker, Int)] = [
            (.mode, 0), (.stillMode, 0), (.stillMode, 1), (.stillDrive, 0),
            (.stillFocus, 0), (.stillFocus, 1), (.stillFocus, 2),
            (.stillMeter, 0), (.stillQuality, 0), (.stillPicture, 0),
            (.focus, 0), (.focus, 1), (.focus, 2),
        ]
        for (picker, mode) in sourced {
            XCTAssertNotNil(
                picker.optionProperty(forMode: mode),
                "\(picker.rawValue) mode \(mode) is not sourced from the camera")
        }
        // Focus mode / area / subject are three separate Nikon settings, so the three tabs must
        // read three different properties — never collapsed onto one.
        for picker: CameraPicker in [.focus, .stillFocus] {
            let properties = (0...2).compactMap { picker.optionProperty(forMode: $0) }
            XCTAssertEqual(Set(properties).count, 3, "\(picker.rawValue) conflates its focus tabs")
        }
        // The Drive picker's two Timer tabs are app state, not camera enums.
        XCTAssertNil(CameraPicker.stillDrive.optionProperty(forMode: 1))
        XCTAssertNil(CameraPicker.stillDrive.optionProperty(forMode: 2))
    }

    /// The fallback a body without a descriptor gets must be conservative: no user banks (the
    /// reported Zf), and the drive ladder in the body's release order (the reported Z6III).
    func testPickerFallbackLaddersAreConservativeAndInBodyOrder() {
        for picker: CameraPicker in [.mode, .stillMode] {
            XCTAssertFalse(
                picker.options.contains { $0.hasPrefix("U") },
                "\(picker.rawValue) invents user banks without a descriptor")
        }
        XCTAssertEqual(CameraPicker.stillMode.modes[0].options, ["Auto", "P", "S", "A", "M"])
        XCTAssertEqual(
            CameraPicker.stillDrive.options,
            [
                "Single", "Continuous L", "Continuous H", "Continuous H+", "C15", "C30", "C60",
                "C120",
            ]
        )
    }

    /// Focus AREA and subject DETECTION are separate Nikon settings, and neither tab may wear the
    /// other's name. The core suite proves these exact labels encode back to their own raw values.
    func testFocusAreaLabelsNameTheBodysSettings() {
        for picker: CameraPicker in [.focus, .stillFocus] {
            let areas = picker.modes[1].options
            let subjects = picker.modes[2].options
            // The bare forms are the reported confusion: "Subject" reads as the detection tab and
            // "3D" is not what the body calls 3D-tracking.
            XCTAssertFalse(areas.contains("Subject"), "\(picker.rawValue) area tab says 'Subject'")
            XCTAssertFalse(areas.contains("3D"), "\(picker.rawValue) area tab says bare '3D'")
            // Only "Auto" legitimately names a position in both spaces.
            XCTAssertTrue(Set(areas).intersection(subjects).isSubset(of: ["Auto"]))
        }
        // Each chrome's own tracking position, spelled the way the body spells it.
        XCTAssertTrue(CameraPicker.focus.modes[1].options.contains("Subject tracking"))
        XCTAssertTrue(CameraPicker.stillFocus.modes[1].options.contains("3D tracking"))
    }

    // MARK: - Controls that must be able to act

    /// The photography strip's WB tile reads the STILLS white balance. `WhiteBalance` (0x5005) and
    /// `MovWhiteBalance` are different camera settings sharing one decode table, so reading the
    /// movie one put a value the still never uses on the stills strip.
    func testPhotographyWhiteBalanceTileReadsTheStillsSide() {
        let split = PTPCameraPropertySnapshot(
            wbMode: "Color temp", stillWBMode: "Cloudy", wbKelvin: 3_200)
        let wbTile = { (snapshot: PTPCameraPropertySnapshot) -> String? in
            snapshot.photographyCaptureValues.first { $0.label == "WB" }?.value
        }
        XCTAssertEqual(wbTile(split), "Cloudy")
        // Kelvin still wins, but only when the STILLS side is the one in colour-temperature mode.
        let stillsKelvin = PTPCameraPropertySnapshot(
            wbMode: "Cloudy", stillWBMode: "Color temp", wbKelvin: 3_200)
        XCTAssertEqual(wbTile(stillsKelvin), "3200K")
        // A body that has only ever pushed the movie side still reads out rather than showing "—".
        let movieOnly = PTPCameraPropertySnapshot(wbMode: "Sunny")
        XCTAssertEqual(wbTile(movieOnly), "Sunny")
    }

    /// The AF box maps onto the PRESENTED picture, which de-squeeze narrows to a centred sub-rect —
    /// mapping into the whole frame is what drifted the box off its subject.
    func testFocusBoxFollowsTheDesqueezedPicture() throws {
        let focus = PTPLiveViewFocusInfo(
            coordinateWidth: 1_000, coordinateHeight: 1_000,
            focusResult: .focused, subjectDetectionActive: false, selectedBoxIndex: 0,
            boxes: [PTPLiveViewAFBox(centerX: 750, centerY: 500, width: 100, height: 100)])
        let box = try XCTUnwrap(focus.boxes.first)
        let size = CGSize(width: 800, height: 400)
        // Nikon's pillarboxing squeeze: the shared vertical direction.
        let squeezed = NikonDesqueeze(factor: 2, horizontal: false)

        let plain = try XCTUnwrap(
            liveFocusBoxRect(
                box, focus: focus, in: size, desqueeze: .off, mirrored: false))
        XCTAssertEqual(plain.midX, 600, accuracy: 0.01)
        // 2× horizontal: the picture is the middle 400pt, so 75% across it sits at 200 + 300.
        let desqueezed = try XCTUnwrap(
            liveFocusBoxRect(box, focus: focus, in: size, desqueeze: squeezed, mirrored: false))
        XCTAssertEqual(desqueezed.midX, 500, accuracy: 0.01)
        // The box narrows WITH the picture: 100 of 1000 coordinate units across a 400pt
        // presented width is 40pt, not the 80pt it spans unsqueezed. A box that kept its
        // unsqueezed width would straddle the subject it is meant to sit on.
        XCTAssertEqual(desqueezed.width, 40, accuracy: 0.01)
        // Vertical extent is untouched by a horizontal squeeze.
        XCTAssertEqual(desqueezed.midY, plain.midY, accuracy: 0.01)
        // Mirroring flips about the PRESENTED rect, not the frame: 75% across becomes 25%.
        let mirrored = try XCTUnwrap(
            liveFocusBoxRect(box, focus: focus, in: size, desqueeze: squeezed, mirrored: true))
        XCTAssertEqual(mirrored.midX, 300, accuracy: 0.01)
    }
}

/// The watch feed's encoder. HEIC carries roughly JPEG's perceived quality in half the bytes,
/// which is what buys back the cost of the larger frames.
@MainActor
final class WatchFrameEncodingTests: XCTestCase {
    private func solidImage(width: Int = 64, height: Int = 36) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// HEIC, not JPEG. An ISOBMFF file names its box type at bytes 4..8 ("ftyp"), where a JPEG
    /// opens 0xFFD8. Checking the container rather than "some bytes came back" is the point: the
    /// JPEG fallback is silent by design, so it would look identical to success at the call site,
    /// and shipping the fallback everywhere would quietly undo the whole change.
    func testFramesEncodeAsHeic() throws {
        let data = try XCTUnwrap(WatchRelay.encodedFrameData(solidImage(), quality: 0.5))
        XCTAssertGreaterThan(data.count, 0)
        let isJPEG =
            data.count >= 2 && data[data.startIndex] == 0xFF
            && data[data.startIndex + 1] == 0xD8
        XCTAssertFalse(isJPEG, "still JPEG — the HEIC destination silently fell back")
        let ftyp = data.count >= 8 ? Array(data[(data.startIndex + 4)..<(data.startIndex + 8)]) : []
        XCTAssertEqual(ftyp, Array("ftyp".utf8), "not an ISOBMFF container")
    }

    /// Quality has to actually reach the encoder. A parameter accepted and ignored would leave the
    /// feed exactly as compressed as before while the ladder claims otherwise.
    func testQualityReachesTheEncoder() throws {
        // A gradient, not a flat fill: a solid colour compresses to nearly the same size at any
        // quality, so it would pass this test without the parameter doing anything.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 72)).image { ctx in
            let colors = [UIColor.black.cgColor, UIColor.white.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            {
                ctx.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 128, y: 72), options: [])
            }
        }
        let low = try XCTUnwrap(WatchRelay.encodedFrameData(image, quality: 0.1))
        let high = try XCTUnwrap(WatchRelay.encodedFrameData(image, quality: 0.9))
        XCTAssertGreaterThan(high.count, low.count, "quality is not reaching the encoder")
    }
}

extension RunnerTests {
    /// The app target compiles the shared core from its OWN file references, so a rule the SPM
    /// suite proves is not thereby proven here — and the store the app writes through is this
    /// target's. Two routers on different subnets are two setups.
    func testTwoRoutersOnDifferentSubnetsStaySeparateInTheAppTarget() {
        let records = PTPIPSavedCameraRecords.canonicalized([
            PTPIPSavedCameraRecord(
                host: "10.99.0.20", displayName: "ZR_6002199", transport: "Wi-Fi",
                lastSeenAt: Date(timeIntervalSince1970: 1), serialNumber: "6002199",
                path: .infrastructure(networkName: nil)),
            PTPIPSavedCameraRecord(
                host: "192.168.129.66", displayName: "ZR_6002199", transport: "Wi-Fi",
                lastSeenAt: Date(timeIntervalSince1970: 2), serialNumber: "6002199",
                path: .infrastructure(networkName: nil)),
        ])
        XCTAssertEqual(records.count, 2, "hosts: \(records.map(\.host))")
    }
}

extension RunnerTests {
    /// Failure copy is matched on the TEXT of a status, which carries no idea which path produced
    /// it — so a cable failure used to be answered with "check Wi-Fi", sending the operator to
    /// inspect a radio the attempt never used.
    func testCableFailuresAreNotToldToCheckWiFi() {
        let timedOut = "PTP-IP connect timed out"
        XCTAssertTrue(
            StartupConnectionCopy.friendly(timedOut, path: .usbC).contains("Check the cable"))
        XCTAssertTrue(
            StartupConnectionCopy.friendly(timedOut, path: .hdmiCapture).contains("Check the cable")
        )

        // Every path with a network keeps the Wi-Fi wording, including an unknown one.
        for network in [CameraPath.Kind.cameraAccessPoint, .infrastructure, .phoneHotspot] {
            XCTAssertTrue(
                StartupConnectionCopy.friendly(timedOut, path: network).contains("Check Wi"),
                "\(network) should still be told to check Wi-Fi")
        }
        XCTAssertTrue(StartupConnectionCopy.friendly(timedOut).contains("Check Wi"))
    }

    /// The wizard's step headings describe the SHAPE of the wizard, not what any one path does in
    /// it — "Set up the network" over a cable is a different instruction from the one on screen.
    func testEveryPathsNetworkStepIsTitledForWhatItActuallyDoes() {
        // The generic title survives only where it is still true.
        XCTAssertEqual(
            NativeAppModel.FirstPairWizardStep.connectNetwork.title, "Set up the network")
        XCTAssertEqual(NativeAppModel.FirstPairWizardStep.discoverAndPair.title, "Find and pair")
        // HDMI never visits the network step; every other path does, and each needs its own words.
        XCTAssertFalse(
            NativeAppModel.FirstPairWizardStep.sequence(
                transport: .hdmiCapture, skipsPermissions: false
            ).contains(.connectNetwork))
        // Camera-AP pairing ends at the network step — nothing to find afterwards.
        XCTAssertFalse(
            NativeAppModel.FirstPairWizardStep.sequence(
                transport: .cameraAccessPoint, skipsPermissions: false
            ).contains(.discoverAndPair))
    }
}

// MARK: - Relay presence ledger

extension RunnerTests {
    /// An in-use shield must never be evidence that the network hides broadcasts.
    ///
    /// `CameraInUseBeacon` advertises under a distinct "<name> in-use" service name while its
    /// presence line carries the plain one, so it can never match its own browsed row by name.
    /// Counting it told every operator whose colleague merely HELD a camera — without sharing
    /// anything — that their network filters discovery.
    @MainActor
    func testAnInUseShieldNeverProvesTheNetworkFiltersDiscovery() {
        let model = NativeAppModel()
        let shield = RelayPresence(
            name: "Erik's iPad", watchable: false, servedCameraHost: "192.168.1.246",
            relayPort: nil)

        model.applyRelayPresences(["192.168.1.9": shield])
        model.applyRelayPresences(["192.168.1.9": shield])

        XCTAssertFalse(model.networkFiltersDiscovery)
    }

    /// A stopped broadcast's stale mDNS row is pruned even while that device keeps holding a
    /// camera — the in-use answer proves the DEVICE is there, never that it is still sharing.
    @MainActor
    func testAnInUseAnswerDoesNotKeepAStoppedBroadcastRowAlive() {
        let model = NativeAppModel()
        model.discoveredRelayHosts = [
            MonitorRelayDiscovery(
                id: "erik-ipad", name: "Erik's iPad",
                endpoint: .hostPort(host: "192.168.1.9", port: 7000))
        ]
        XCTAssertEqual(model.visibleRelayBroadcasts.count, 1)

        model.applyRelayPresences([
            "192.168.1.9": RelayPresence(
                name: "Erik's iPad", watchable: false, servedCameraHost: nil, relayPort: nil)
        ])

        // Asserted through the list the operator actually sees, not the private refutation set:
        // an in-use answer proves the DEVICE is there, never that it is still sharing.
        XCTAssertTrue(model.visibleRelayBroadcasts.isEmpty)
    }
}

// MARK: - RED download failure copy

extension RunnerTests {
    /// A failed page load must not invent a cause for itself.
    ///
    /// Six URL error codes all used to answer "you appear to be connected to the camera's Wi-Fi",
    /// which is a claim about the phone's NETWORK made from a fact about one REQUEST. Field report:
    /// that sentence on home Wi-Fi with working internet, sending the operator to change networks
    /// for nothing.
    @MainActor
    func testRedDownloadFailureDoesNotInventACameraWiFiDiagnosis() {
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let dns = NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)
        let lost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)

        for error in [timedOut, dns, lost] {
            let copy = redDownloadFailureMessage(for: error, availability: .available)
            XCTAssertFalse(
                copy.contains("camera"),
                "a request that failed on a working network says nothing about which network: \(copy)"
            )
        }

        // The one code that IS the OS reporting no route still says so, without naming a cause.
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let offlineCopy = redDownloadFailureMessage(
            for: offline, availability: .available)
        XCTAssertTrue(offlineCopy.contains("No internet connection"))
        XCTAssertFalse(offlineCopy.contains("camera"))
    }

    /// When the app genuinely knows the phone is on the camera's Wi-Fi, it says so — the diagnosis
    /// is read from the availability policy, never guessed from an error code.
    @MainActor
    func testRedDownloadFailureUsesTheAvailabilityVerdictWhenThereIsOne() {
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        let onAP = redDownloadFailureMessage(
            for: timedOut, availability: .blockedOnCameraAccessPoint)
        XCTAssertEqual(onAP, RedLUTDownloadAvailability.blockedOnCameraAccessPoint.blockedReason)

        let noRoute = redDownloadFailureMessage(
            for: timedOut, availability: .blockedNoInternet)
        XCTAssertEqual(noRoute, RedLUTDownloadAvailability.blockedNoInternet.blockedReason)
    }
}

/// The app side of the OpenCineNikon session port: picker routing and the refusal mapping.
final class NikonSessionPortMappingTests: XCTestCase {
    @MainActor
    func testMovieExposureAndWhiteBalanceRouteThroughTheSessionSeam() {
        let movieControls: [CameraPicker] = [.iso, .whiteBalance, .shutter, .iris]
        for picker in CameraPicker.allCases {
            let setting = picker.nikonControlSetting
            XCTAssertEqual(setting != nil, movieControls.contains(picker), "\(picker)")
            if let setting {
                XCTAssertEqual(CameraPicker(setting), picker)
                XCTAssertEqual(picker.cameraControl, setting.cameraControl)
            }
        }
    }

    func testOnlyAPTPRefusalCountsAsCameraRefused() {
        XCTAssertTrue(
            NativeCameraSessionError.isCameraRefusal(
                NativeCameraSessionError.operationRejected(.setDevicePropValue, .deviceBusy)))
        XCTAssertFalse(
            NativeCameraSessionError.isCameraRefusal(
                NativeCameraSessionError.timeout("SetDevicePropValue")))
        XCTAssertFalse(NativeCameraSessionError.isCameraRefusal(CancellationError()))
    }
}

/// SIMULATED public-contract control lifetime for the production monitor composition test.
@MainActor
final class NikonPictureLifetimeSession: CameraSession {
    nonisolated let id = CameraSessionID()
    private var snapshot: CameraSnapshot
    private var subscribers: [AsyncStream<CameraSnapshot>.Continuation] = []
    var closes: [SessionCloseReason] = []
    var commands = 0

    init() { snapshot = CameraSnapshot(session: id, connection: .ready, authority: .owner) }
    func snapshots() async -> AsyncStream<CameraSnapshot> {
        let (stream, continuation) = AsyncStream<CameraSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        subscribers.append(continuation)
        continuation.yield(snapshot)
        return stream
    }
    func submit(_ command: CameraCommand) async -> CommandReceipt {
        commands += 1
        return CommandReceipt(
            operation: command.operation, session: id, intent: command.intent,
            stage: .rejected(.supportUnknown))
    }
    func outcome(of operation: OperationID) async -> CommandReceipt? { nil }
    func receipt(of operation: OperationID) async -> CommandReceipt? { nil }
    func close(_ reason: SessionCloseReason) async {
        guard closes.isEmpty else { return }
        closes.append(reason)
        snapshot.connection = .disconnected(reason)
        for subscriber in subscribers {
            subscriber.yield(snapshot)
            subscriber.finish()
        }
        subscribers.removeAll()
    }
    func loseControl() {
        snapshot.connection = .recovering(ConnectionAttemptID())
        snapshot.authority = .readOnly
        snapshot.revision = snapshot.revision.next()
        for subscriber in subscribers { subscriber.yield(snapshot) }
    }
}

/// SIMULATED descriptor reports enter through the actual app bootstrap producer.
@MainActor
@Suite("Common Nikon exposure provenance")
struct NikonExposureProvenanceTests {
    private func movieModel() throws -> NativeAppModel {
        let model = NativeAppModel()
        model.applyBootstrapObservation(.property(.liveViewSelector, Data([1])))
        model.applyBootstrapObservation(
            .property(.movieShutterMode, Data([PTPCameraPropertyDecoders.shutterModeCode(.angle)])))
        model.applyBootstrapObservation(
            .property(
                .movieShutterAngle,
                try #require(PTPCameraPropertyWrite.request(control: .shutter, label: "180°")).data)
        )
        model.applyBootstrapObservation(
            .property(
                .movieFNumber,
                try #require(PTPCameraPropertyWrite.request(control: .iris, label: "f/2.8")).data))
        return model
    }

    @Test("Legacy UI ladders cannot authorize common exposure writes")
    func fallbackIsNotAnAdvertisedDomain() throws {
        let model = try movieModel()
        model.cameraControlOptions[.movieShutterAngle] = CameraPicker.shutter.modes[0].options
        #expect(!model.irisApertures.isEmpty)
        let facts = model.nikonControlFacts
        #expect(facts.shutterLabels.isEmpty)
        #expect(facts.apertureLabels.isEmpty)
        #expect(NikonExposureSettings.reported(facts.reported)[.shutter] == .shutter(.angle(180)))
        #expect(NikonExposureSettings.reported(facts.reported)[.aperture] == .aperture(2.8))
        for key in [SettingKey.shutter, .aperture] {
            let descriptor = try #require(
                NikonCameraSession.descriptors(facts).first { $0.key == key })
            #expect(try #require(descriptor.domain).choices.isEmpty)
            #expect(descriptor.availability == .unavailable(.notReady))
        }
    }

    @Test("Actual choices authorize only their advertised domain and retire with the circuit")
    func descriptorReportsOwnTheDomain() throws {
        let model = try movieModel()
        model.applyBootstrapObservation(.options(.movieShutterAngle, ["45°", "90°"]))
        model.applyBootstrapObservation(.apertures(["f/4.0"]))
        let facts = model.nikonControlFacts
        #expect(facts.shutterLabels == ["45°", "90°"])
        #expect(facts.apertureLabels == ["f/4.0"])
        let aperture = try #require(
            NikonCameraSession.descriptors(facts).first { $0.key == .aperture })
        #expect(try #require(aperture.domain).choices == [.aperture(4)])
        model.applyBootstrapObservation(.options(.movieShutterAngle, ["180°"]))
        #expect(model.nikonControlFacts.shutterLabels.isEmpty)
        model.applyBootstrapObservation(
            .property(.movieShutterMode, Data([PTPCameraPropertyDecoders.shutterModeCode(.speed)])))
        #expect(model.nikonControlFacts.shutterLabels.isEmpty)
        model.applyBootstrapObservation(.property(.liveViewSelector, Data([0])))
        model.applyBootstrapObservation(.apertures(["f/5.6"]))
        model.applyBootstrapObservation(.property(.liveViewSelector, Data([1])))
        #expect(model.nikonControlFacts.apertureLabels.isEmpty)
        #expect(model.advertisedExposureOptions.isEmpty)
    }
}

@MainActor
@Suite("SIMULATED shared settings native scrolling")
struct NikonSettingsScrollTests {
    @Test("Per-tab settled offsets restore, bounce is ignored, and retired observers cannot write")
    func scrollRestoresAndRetires() async throws {
        let state = NikonSettingsScrollFixture()
        let page = MonitorSettingsPage(
            safeArea: EdgeInsets(), brand: "SIMULATED",
            selection: Binding(get: { state.tab }, set: { state.tab = $0 }),
            isLive: false, phaseLabel: "SIMULATED settings",
            scrollOffsets: Binding(get: { state.offsets }, set: { state.offsets = $0 }),
            onClose: {}, disconnect: {},
            rows: { _ in
                ForEach(0..<50, id: \.self) { index in
                    Text("SIMULATED setting \(index)").frame(height: 44)
                }
            })
        let host = UIHostingController(rootView: AnyView(page))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let display = try await scroll(in: host, satisfying: { abs($0.contentOffset.y - 180) < 1 })
        display.setContentOffset(CGPoint(x: 0, y: 320), animated: false)
        try await settle(in: host) { state.offsets["Display"] == 320 }
        display.setContentOffset(CGPoint(x: 0, y: -50), animated: false)
        for _ in 0..<100 { await Task.yield() }
        #expect(state.offsets["Display"] == 320)

        state.tab = .assist
        let assist = try await scroll(in: host, satisfying: { abs($0.contentOffset.y - 75) < 1 })
        #expect(state.offsets["Display"] == 320)
        assist.setContentOffset(CGPoint(x: 0, y: 210), animated: false)
        try await settle(in: host) { state.offsets["View Assist"] == 210 }
        state.tab = .display
        let restored = try await scroll(in: host, satisfying: { abs($0.contentOffset.y - 320) < 1 })

        host.rootView = AnyView(EmptyView())
        try await settle(in: host) { settingsScroll(in: host.view) == nil }
        let offsets = state.offsets
        restored.setContentOffset(CGPoint(x: 0, y: 450), animated: false)
        for _ in 0..<100 { await Task.yield() }
        #expect(state.offsets == offsets)
    }

    @Test("The actual Nikon Display return preserves native offsets and retires its observer")
    func actualDisplayRestoresAndRetires() async throws {
        let model = NativeAppModel()
        let original = model.preferences
        model.preferences = OperatorPreferences.defaults
        defer { model.preferences = original }
        // DISP 2 returns to its section with the clean-view pin list open, a page tall enough for
        // these offsets now that DISP 1 has no toolbar order list.
        model.beginChromeEditing(.clean)
        model.endChromeEditing()
        model.operatorSettingsScrollOffsets = ["Display": 180]
        let host = UIHostingController(
            rootView: AnyView(OperatorSettingsPanel().environment(model)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let display = try await scroll(in: host) { abs($0.contentOffset.y - 180) < 1 }
        #expect(model.operatorSettingsTab == .display)
        #expect(model.chromeEditorReturnMode == nil)
        display.setContentOffset(CGPoint(x: 0, y: 320), animated: false)
        try await settle(in: host) { model.operatorSettingsScrollOffsets["Display"] == 320 }
        model.operatorSettingsTab = .controls
        try await settle(in: host) { settingsScroll(in: host.view) !== display }
        #expect(model.operatorSettingsScrollOffsets["Display"] == 320)
        model.operatorSettingsTab = .display
        let restored = try await scroll(in: host) { abs($0.contentOffset.y - 320) < 1 }
        host.rootView = AnyView(EmptyView())
        try await settle(in: host) { settingsScroll(in: host.view) == nil }
        let offsets = model.operatorSettingsScrollOffsets
        restored.setContentOffset(CGPoint(x: 0, y: 450), animated: false)
        for _ in 0..<100 { await Task.yield() }
        #expect(model.operatorSettingsScrollOffsets == offsets)
    }

    @Test("Measured full labels select the same column counts as Compose")
    func displayLabelFitBoundaries() {
        #expect(MonitorDisplayMetrics.toggleColumnCount(compact: false, availableWidth: 480) == 4)
        #expect(
            MonitorDisplayMetrics.toggleColumnCount(
                compact: false, availableWidth: 624, minimumCellWidth: 151) == 2)
        #expect(
            MonitorDisplayMetrics.toggleColumnCount(
                compact: false, availableWidth: 625, minimumCellWidth: 151) == 4)
        #expect(
            MonitorDisplayMetrics.toggleColumnCount(
                compact: true, availableWidth: 625, minimumCellWidth: 151) == 2)
        #expect(
            MonitorDisplayMetrics.toggleColumnCount(
                compact: false, availableWidth: 309, minimumCellWidth: 151) == 2)
        #expect(
            MonitorDisplayMetrics.toggleColumnCount(
                compact: false, availableWidth: 308, minimumCellWidth: 151) == 1)
    }

    @Test("A saved position beyond the current content restores inside the real viewport")
    func scrollClampsToCurrentContent() async throws {
        let state = NikonSettingsScrollFixture()
        state.offsets["Display"] = 10_000
        let page = MonitorSettingsPage(
            safeArea: EdgeInsets(), brand: "SIMULATED",
            selection: Binding(get: { state.tab }, set: { state.tab = $0 }),
            isLive: false, phaseLabel: "SIMULATED settings",
            scrollOffsets: Binding(get: { state.offsets }, set: { state.offsets = $0 }),
            onClose: {}, disconnect: {},
            rows: { _ in
                ForEach(0..<12, id: \.self) { index in
                    Text("SIMULATED setting \(index)").frame(height: 44)
                }
            })
        let host = UIHostingController(rootView: AnyView(page))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let view = try await scroll(in: host) { view in
            let maximum = max(0, view.contentSize.height - view.bounds.height)
            return maximum > 0 && abs(view.contentOffset.y - maximum) < 1
        }
        #expect(view.contentOffset.y >= 0)
        #expect(view.contentOffset.y <= view.contentSize.height - view.bounds.height)
    }

    private func settingsScroll(in view: UIView) -> UIScrollView? {
        // The real content viewport is wider than the 188-point navigation rail.
        if let scroll = view as? UIScrollView, scroll.bounds.height > 100, scroll.bounds.width > 200
        {
            return scroll
        }
        for child in view.subviews {
            if let found = settingsScroll(in: child) { return found }
        }
        return nil
    }

    private func scroll(
        in host: UIViewController, satisfying predicate: (UIScrollView) -> Bool
    ) async throws -> UIScrollView {
        try await settle(in: host) {
            settingsScroll(in: host.view).map(predicate) ?? false
        }
        return try #require(settingsScroll(in: host.view))
    }

    private func settle(in host: UIViewController, until predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
            if predicate() { return }
        }
        let observed =
            settingsScroll(in: host.view).map {
                "offset=\($0.contentOffset.y) size=\($0.contentSize) bounds=\($0.bounds)"
            } ?? "missing scroll"
        #expect(
            predicate(),
            "The actual shared settings scroll did not reach the expected native state: \(observed)"
        )
    }
}

@MainActor
@Observable
private final class NikonSettingsScrollFixture {
    var tab: MonitorSettingsTab = .display
    var offsets: [String: CGFloat] = ["Display": 180, "View Assist": 75]
}

@MainActor
@Observable
private final class NativeDefaultFilterFixture {
    var formats: Set<String> = []
    var colours: Set<UInt8> = []
    var picks: [String] = []
}

@MainActor
@Suite("SIMULATED native media selection ownership")
struct NikonMediaSelectionNativeOwnerTests {
    @Test("The shared catalog's gallery mounts the native policy once and retires it")
    func nativeOwnerMountsAndRetires() async throws {
        let state = NikonSelectionNativeFixtureState()
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: NikonSelectionNativeFixture(state: state))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKeyAndVisible()
        }
        try await settle(host) { scroll(host.view).map { recognizers($0).count == 2 } ?? false }
        let gallery = try #require(scroll(host.view))
        let hold = try #require(
            recognizers(gallery).compactMap { $0 as? UILongPressGestureRecognizer }.first)
        let standard = MonitorMediaSelectionConfiguration.standard
        #expect(hold.minimumPressDuration == Double(standard.holdMilliseconds) / 1_000)
        #expect(Double(hold.allowableMovement) == standard.movementTolerance)
        #expect(gallery.contentSize.height > gallery.bounds.height)
        let gridHeight = gallery.contentSize.height
        state.list = true
        try await settle(host) {
            scroll(host.view).map { $0.contentSize.height != gridHeight } ?? false
        }
        let list = try #require(scroll(host.view))
        #expect(mountedRecognizers(host.view) == 2)
        #expect(list.contentSize.height > list.bounds.height)
        state.present = false
        try await settle(host) { scroll(host.view) == nil && recognizers(list).isEmpty }
        #expect(recognizers(gallery).isEmpty && recognizers(list).isEmpty)
    }

    private func recognizers(_ scroll: UIScrollView) -> [UIGestureRecognizer] {
        (scroll.gestureRecognizers ?? []).filter {
            $0.delegate.map {
                String(describing: type(of: $0)).contains("MonitorMediaSelectionInteraction")
            } ?? false
        }
    }

    /// The catalog page has several scroll views; the gallery is the one carrying the policy.
    private func scroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, !recognizers(scroll).isEmpty { return scroll }
        return view.subviews.compactMap { scroll($0) }.first
    }

    private func mountedRecognizers(_ view: UIView) -> Int {
        ((view as? UIScrollView).map { recognizers($0).count } ?? 0)
            + view.subviews.map(mountedRecognizers).reduce(0, +)
    }

    private func settle(_ host: UIViewController, until predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            if predicate() { return }
        }
        try #require(predicate(), "The actual native selection scroll owner did not settle")
    }
}

@MainActor
@Observable
private final class NikonSelectionNativeFixtureState {
    var list = false
    var present = true
}

/// Nikon's browser on the shared catalog, with forty Nikon cell items.
@MainActor
private struct NikonSelectionNativeFixture: View {
    let state: NikonSelectionNativeFixtureState
    private let items = (0..<40).map { index in
        MediaClipCellPresentation.item(
            clip: MediaClip(
                cameraID: "SIMULATED-selection", filename: "SIMULATED-\(index).MOV", handle: 1,
                storageID: 65_537, sizeBytes: 1_000_000, captureDate: ""),
            detail: "", isDownloaded: false, cacheProgress: nil, isStreaming: false,
            hasRawSibling: false, duration: nil, list: false, selecting: false)
    }
    var body: some View {
        if state.present {
            MonitorMediaCatalog(
                brand: "OpenZCine", safeArea: EdgeInsets(), items: items,
                categories: [MonitorMediaCategory(id: "All", title: "All", count: items.count)],
                category: "All", layout: state.list ? .list : .grid, thumbnailSize: .medium,
                sortTitle: "Newest", status: "", selectedIDs: [], selecting: false,
                refreshing: false, canRefresh: false, tablet: false
            ) { _ in
            } thumbnail: { _ in
                Color.gray
            } empty: {
                EmptyView()
            } filters: {
                EmptyView()
            }
        }
    }
}

@MainActor
private struct NikonZebraNativeFixtureView: View {
    let model: NativeAppModel
    var body: some View {
        ScrollView {
            MonitorViewAssistSettings(sections: [
                .zebra(NikonAssistMenuAdapter(model: model, compact: true).zebra)
            ])
        }
        .environment(model)
    }
}

@MainActor
private struct NativeDefaultFilterFixtureView: View {
    var state: NativeDefaultFilterFixture
    var body: some View {
        ScrollView {
            MonitorMediaFilterForm(
                formats: ["MOV", "MP4"], resolutions: ["4K"],
                colors: [.init(id: 9, label: "LOG")],
                formatSelection: state.formats, resolutionSelection: [],
                colorSelection: state.colours,
                dateStartLabel: nil, dateEndLabel: nil, hasDates: true,
                onToggleFormat: { state.formats.formSymmetricDifference([$0]) },
                onToggleResolution: { _ in },
                onToggleColor: { state.colours.formSymmetricDifference([$0]) },
                onPickStart: { state.picks.append("start") },
                onPickEnd: { state.picks.append("end") },
                onClear: {
                    state.formats = []
                    state.colours = []
                }
            )
            .padding(16)
        }
        .background(Color.black)
    }
}

struct MediaClipCellPresentationTests {
    @Test func remotePhotoCarriesKnownPairAndBurstFactsWithoutInventingLocalSource() {
        let clip = sample("01.JPG")
        let item = MediaClipCellPresentation.item(
            clip: clip, detail: "", isDownloaded: false, cacheProgress: nil,
            isStreaming: false, hasRawSibling: true, burstCount: 4, duration: nil,
            list: false, selecting: false)
        #expect(item.id == clip.id && item.filename == clip.filename)
        #expect(item.availability == .camera && item.stateLabel == "ON CAMERA")
        #expect(item.duration.isEmpty && item.photo)
        #expect(item.mediaBadge == "RAW+J" && item.burstCount == 4)
        #expect(item.progress == nil && item.completionBadge == nil)
        #expect(!item.favorite)
    }

    @Test func realZeroProgressAndStreamingCaptionRemainKnown() {
        let item = MediaClipCellPresentation.item(
            clip: sample("01.MOV"), detail: "", isDownloaded: false, cacheProgress: 0,
            isStreaming: true, hasRawSibling: false, duration: "00:08",
            list: false, selecting: false)
        #expect(item.progress == 0 && item.transferCaption == "CACHING 0%")
        #expect(item.stateLabel == "CACHING" && item.duration.isEmpty)
        #expect(item.completionBadge == nil)
    }

    @Test func completedExportAndLocalFavoriteStaySourceFacts() {
        var clip = sample("01.MOV")
        clip.exportStatus = .exported
        clip.isFavorite = true
        let item = MediaClipCellPresentation.item(
            clip: clip, detail: "", isDownloaded: true, cacheProgress: nil,
            isStreaming: false, hasRawSibling: false, duration: "00:08",
            list: false, selecting: false)
        #expect(item.duration == "00:08" && item.completionBadge == "EXPORTED")
        #expect(item.favorite)
        #expect(item.availability == .original && item.stateLabel == "ON PHONE")
    }

    @Test func selectionAndListProjectionPreserveExistingBadgePolicies() {
        let clip = sample("01.JPG")
        let selecting = MediaClipCellPresentation.item(
            clip: clip, detail: "", isDownloaded: false, cacheProgress: nil,
            isStreaming: false, hasRawSibling: true, burstCount: 4, duration: nil,
            list: false, selecting: true)
        #expect(selecting.burstCount == nil && selecting.mediaBadge == nil)
        let list = MediaClipCellPresentation.item(
            clip: clip, detail: "RAW+J · 1MB", isDownloaded: true, cacheProgress: 0.5,
            isStreaming: true, hasRawSibling: true, burstCount: 4, duration: nil,
            list: true, selecting: false)
        #expect(list.metadata == "RAW+J · 1MB" && list.transferCaption == "50%")
        #expect(list.burstCount == nil && list.mediaBadge == nil)
    }

    @Test func listDetailNamesResolutionPairSizeAndDurationOrWhereItLives() {
        let video = sample("01.MOV")
        #expect(
            MediaClipCellPresentation.metadataLine(
                video, hasRawSibling: false, duration: "0:08", isDownloaded: true)
                == "\(MediaClipFormatting.byteLabel(1_000_000)) · 0:08")
        let photo = sample("01.JPG")
        #expect(
            MediaClipCellPresentation.metadataLine(
                photo, hasRawSibling: true, duration: "0:08", isDownloaded: false)
                == "RAW+J · \(MediaClipFormatting.byteLabel(1_000_000))")
        var empty = sample("02.MOV")
        empty.sizeBytes = 0
        #expect(
            MediaClipCellPresentation.metadataLine(
                empty, hasRawSibling: false, duration: nil, isDownloaded: false) == "On camera")
        #expect(
            MediaClipCellPresentation.metadataLine(
                empty, hasRawSibling: false, duration: nil, isDownloaded: true) == "Cached")
    }

    private func sample(_ filename: String) -> MediaClip {
        MediaClip(
            cameraID: "SIMULATED-cell", filename: filename, handle: 1, storageID: 65_537,
            sizeBytes: 1_000_000, captureDate: "")
    }
}

extension RunnerTests {
    @MainActor
    func testSharedMediaCellDefaultsKeepNativeFavoriteAndSelectionIndependent() async throws {
        let item = MonitorMediaItem(
            id: "SIMULATED-cell/01", filename: "01.MOV", metadata: "4K · 24",
            duration: "00:08", availability: .proxy, favorite: false, photo: false,
            permissions: [.favorite])
        var favorites = 0
        var selections = 0
        let host = UIHostingController(
            rootView: MonitorMediaCell(
                clip: MonitorClipValue(item: item), layout: .grid, selecting: true, selected: true,
                onOpen: { XCTFail("A child control must not open the clip") },
                onSelect: { selections += 1 }, onFavorite: { favorites += 1 }
            ) { Color.gray })
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        host.view.backgroundColor = UIColor(MonitorTheme.background)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKeyAndVisible()
        }
        for layout in [MonitorMediaLayout.grid, .list] {
            host.rootView = MonitorMediaCell(
                clip: MonitorClipValue(item: item), layout: layout, selecting: true, selected: true,
                onOpen: { XCTFail("A child control must not open the clip") },
                onSelect: { selections += 1 }, onFavorite: { favorites += 1 },
                thumbnail: { Color.gray }
            )
            let favorite = try await nativeFilterElement("Add favorite", host: host)
            let selection = try await nativeFilterElement("Deselect 01.MOV", host: host)
            XCTAssertGreaterThanOrEqual(favorite.accessibilityFrame.width, 44)
            XCTAssertGreaterThanOrEqual(favorite.accessibilityFrame.height, 44)
            XCTAssertTrue(favorite.accessibilityActivate())
            XCTAssertTrue(selection.accessibilityActivate())
            let attachment = XCTAttachment(
                image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                })
            attachment.name = "SIMULATED-common-media-cell-\(layout.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(favorites, 2)
        XCTAssertEqual(selections, 2)
        host.rootView = MonitorMediaCell(
            clip: MonitorClipValue(item: item), layout: .grid, selecting: false, selected: false,
            favoriteEnabled: false, onOpen: {}, onSelect: {}, onFavorite: { favorites += 1 },
            thumbnail: { Color.gray }
        )
        let disabled = try await nativeFilterElement("Add favorite", host: host)
        XCTAssertTrue(disabled.accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(favorites, 2)
    }

    @MainActor
    func testNikonMediaBadgesAndFavoriteRenderInTheSharedCatalog() async throws {
        let clip = MediaClip(
            cameraID: "SIMULATED-cell", filename: "01.JPG", handle: 1, storageID: 65_537,
            sizeBytes: 1_000_000, captureDate: "")
        let item = MediaClipCellPresentation.item(
            clip: clip, detail: "", isDownloaded: false, cacheProgress: nil,
            isStreaming: false, hasRawSibling: true, burstCount: 4, duration: nil,
            list: false, selecting: false, permissions: [.favorite])
        var favorites = 0
        let host = UIHostingController(
            rootView: MonitorMediaCatalog(
                brand: "OpenZCine", safeArea: EdgeInsets(), items: [item],
                categories: [MonitorMediaCategory(id: "All", title: "All", count: 1)],
                category: "All", layout: .grid, thumbnailSize: .medium, sortTitle: "Newest",
                status: "", selectedIDs: [], selecting: false, refreshing: false,
                canRefresh: false, tablet: false
            ) { action in
                if case .favorite = action { favorites += 1 }
            } thumbnail: { _ in
                Color.gray
            } empty: {
                EmptyView()
            } filters: {
                EmptyView()
            })
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        host.view.backgroundColor = UIColor(MonitorTheme.background)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKeyAndVisible()
        }
        let favorite = try await nativeFilterElement("Add favorite", host: host)
        let labels = Set(nativeFilterElements(host.view).compactMap(\.accessibilityLabel))
        XCTAssertTrue(labels.contains("ON CAMERA"))
        XCTAssertTrue(labels.contains("RAW+J"))
        XCTAssertTrue(labels.contains("4 frames"))
        // Screen-space frames of a cell at a fractional grid offset carry float rounding.
        XCTAssertGreaterThanOrEqual(favorite.accessibilityFrame.width, 44 - 1e-6)
        XCTAssertGreaterThanOrEqual(favorite.accessibilityFrame.height, 44 - 1e-6)
        XCTAssertTrue(favorite.accessibilityActivate())
        XCTAssertEqual(favorites, 1)
        let attachment = XCTAttachment(
            image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            })
        attachment.name = "SIMULATED-Nikon-media-catalog-badges"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension RunnerTests {
    /// Landscape: the expanded View Assist palette's lower row lies over the camera values bar.
    /// The palette draws above the values (Pocket's layering), so the values never paint over a
    /// chip or take its tap. Reduce Transparency makes the palette glass opaque, so a covered
    /// chip's pixels must not change when the values do, while the uncovered values must.
    @MainActor
    func testExpandedLandscapePaletteDrawsAboveTheCameraValues() async throws {
        let model = NativeAppModel()
        model.preferences = OperatorPreferences.defaults
        model.startDemoSession()
        let delivery = MediaDeliveryCoordinator()
        let host = UIHostingController(
            rootView: GeometryReader { proxy in
                NikonMonitorShell(
                    context: LiveViewLayoutContext(
                        proxy: proxy, deviceOrientation: .unknown, screenWidth: nil)
                )
                .environment(model).environment(delivery)
                .environment(\._accessibilityReduceTransparency, true)
            })
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKeyAndVisible()
        }
        func settle() async throws {
            for _ in 0..<60 {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func elements(_ root: NSObject) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            var result: [NSObject] = []
            func visit(_ object: NSObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return }
                result.append(object)
                // SwiftUI vends its nodes through `accessibilityElements`; `accessibilityElement(at:)`
                // can answer nil for them.
                for child in object.accessibilityElements as? [NSObject] ?? [] { visit(child) }
                let count = object.accessibilityElementCount()
                if count > 0 && count < 512 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) as? NSObject {
                            visit(child)
                        }
                    }
                }
                if let view = object as? UIView { for child in view.subviews { visit(child) } }
            }
            visit(root)
            return result.filter { $0.isAccessibilityElement && !$0.accessibilityFrame.isEmpty }
        }
        func identifier(_ object: NSObject) -> String {
            let getter = NSSelectorFromString("accessibilityIdentifier")
            guard object.responds(to: getter) else { return "" }
            return object.perform(getter)?.takeUnretainedValue() as? String ?? ""
        }
        func render() -> CGImage? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }.cgImage
        }
        func pixels(_ image: CGImage, _ rect: CGRect) -> [UInt8] {
            let crop = rect.integral
            var bytes = [UInt8](repeating: 0, count: Int(crop.width * crop.height) * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(
                    data: buffer.baseAddress, width: Int(crop.width), height: Int(crop.height),
                    bitsPerComponent: 8, bytesPerRow: Int(crop.width) * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(
                    image,
                    in: CGRect(
                        x: -crop.minX, y: crop.maxY - CGFloat(image.height),
                        width: CGFloat(image.width), height: CGFloat(image.height)))
            }
            return bytes
        }

        try await settle()
        let expand = try XCTUnwrap(
            elements(host.view).first { identifier($0) == "monitor.assists.expand" },
            "Exposed: \(elements(host.view).map(identifier).filter { !$0.isEmpty })")
        XCTAssertTrue(expand.accessibilityActivate())
        try await settle()
        let bar = model.captureBarFrame
        let covered = elements(host.view).filter { identifier($0).hasPrefix("monitor.assist.") }
            .map { $0.accessibilityFrame.intersection(bar) }
            .filter { !$0.isNull && $0.width >= 8 && $0.height >= 8 }
        XCTAssertFalse(covered.isEmpty, "The open landscape palette must reach the values bar")
        let palette = elements(host.view).filter { identifier($0).hasPrefix("monitor.assist") }
            .map(\.accessibilityFrame).reduce(CGRect.null) { $0.union($1) }
        let open = CGRect(
            x: palette.maxX + 8, y: bar.minY, width: bar.maxX - palette.maxX - 8,
            height: bar.height)
        // Copy the regions now: a renderer image read after a later render showed the later frame.
        let regions = [open] + covered
        let first = try XCTUnwrap(render())
        let shown = regions.map { pixels(first, $0) }

        let state = model.cameraState
        model.cameraState = CameraDisplayState(
            recordState: state.recordState, timecode: state.timecode,
            resolutionFrameRate: state.resolutionFrameRate, codec: state.codec,
            media: state.media, liveFPS: state.liveFPS,
            cameraBatteryPercent: state.cameraBatteryPercent,
            phoneBatteryPercent: state.phoneBatteryPercent, cameraName: state.cameraName,
            lens: state.lens, temperature: state.temperature,
            values: state.values.map { CameraValue(label: $0.label, value: "8888") },
            mediaStatus: state.mediaStatus)
        try await settle()
        let image = try XCTUnwrap(render())
        let changed = regions.map { pixels(image, $0) }
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "SIMULATED-landscape-palette-over-values"
        attachment.lifetime = .keepAlways
        add(attachment)

        // A value painted over a chip changes hundreds of its pixels; allow 1% for icon noise.
        func differing(_ index: Int) -> Int {
            stride(from: 0, to: shown[index].count, by: 4).filter {
                shown[index][$0..<$0 + 4] != changed[index][$0..<$0 + 4]
            }.count
        }
        func noise(_ rect: CGRect) -> Int { Int(rect.integral.width * rect.integral.height) / 100 }
        XCTAssertGreaterThan(differing(0), noise(open), "The uncovered camera values must redraw")
        for (index, rect) in covered.enumerated() {
            XCTAssertLessThanOrEqual(
                differing(index + 1), noise(rect),
                "A camera value drew over the open palette at \(NSCoder.string(for: rect))")
        }
    }
}

@MainActor
@Test func nikonMirrorAxesKeepBoxesAndInverseTapsOnTheDesqueezedPicture() throws {
    let focus = PTPLiveViewFocusInfo(
        coordinateWidth: 1_000, coordinateHeight: 1_000,
        focusResult: .focused, subjectDetectionActive: false, selectedBoxIndex: 0,
        boxes: [PTPLiveViewAFBox(centerX: 750, centerY: 250, width: 100, height: 200)])
    let box = try #require(focus.boxes.first)
    let size = CGSize(width: 800, height: 400)
    for horizontalSqueeze in [false, true] {
        let desqueeze = NikonDesqueeze(factor: 2, horizontal: horizontalSqueeze)
        let feed = desqueezedRect(CGRect(origin: .zero, size: size), desqueeze)
        for horizontal in [false, true] {
            for vertical in [false, true] {
                let drawn = try #require(
                    liveFocusBoxRect(
                        box, focus: focus, in: size,
                        desqueeze: desqueeze, mirrored: horizontal, mirroredVertically: vertical))
                #expect(
                    abs(drawn.midX - (feed.minX + feed.width * (horizontal ? 0.25 : 0.75))) < 0.001)
                #expect(
                    abs(drawn.midY - (feed.minY + feed.height * (vertical ? 0.75 : 0.25))) < 0.001)
                let inverse = LiveFeedFocusGesture.cameraPoint(
                    CGPoint(x: drawn.midX - feed.minX, y: drawn.midY - feed.minY),
                    in: feed.size, mirrored: horizontal, flippedVertically: vertical)
                #expect(abs(inverse.x - 0.75) < 0.001)
                #expect(abs(inverse.y - 0.25) < 0.001)
                let squeeze = desqueezeScale(desqueeze)
                let scale = MirrorAssist.feedScale(
                    mirrored: horizontal,
                    flippedVertically: vertical, squeeze: squeeze)
                #expect(scale.width == (horizontal ? -squeeze.width : squeeze.width))
                #expect(scale.height == (vertical ? -squeeze.height : squeeze.height))
            }
        }
    }
}
