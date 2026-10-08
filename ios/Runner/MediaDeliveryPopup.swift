import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineFrameIO
import SwiftUI
import UIKit

struct MediaDeliveryPresentation: Identifiable {
    let id = UUID()
    let clip: MediaClip
    var preferredDestination: MediaDeliveryDestination? = nil
    var capture: NikonMediaDeliveryCapture? = nil
}
struct MediaDeliveryRequest: Identifiable {
    let id = UUID()
    let clips: [MediaClip]
    var preferredDestination: MediaDeliveryDestination? = nil
    var capture: NikonMediaDeliveryCapture? = nil
}

enum MediaDeliveryPopupPlacement { case belowAnchor, aboveAnchor }

/// Legacy anchor parameters stay compatible; the actual popup uses Pocket's complete owner.
struct MediaDeliveryPopupOverlay: View {
    let clips: [MediaClip]
    let anchorFrame: CGRect
    let placement: MediaDeliveryPopupPlacement
    var preferredDestination: MediaDeliveryDestination? = nil
    var safeArea: MonitorEdgeInsets = .zero
    var capture: NikonMediaDeliveryCapture? = nil
    let onBeginDelivery: (MediaDeliveryBeginRequest) -> Void
    let onDismiss: () -> Void
    @Environment(NativeAppModel.self) private var model
    @Environment(MediaDeliveryCoordinator.self) private var coordinator
    static let width: CGFloat = 420
    var body: some View {
        CapturedNikonMediaDeliveryPopup(
            model: model, coordinator: coordinator, clips: clips,
            capture: capture, preferredDestination: preferredDestination, maxCardHeight: nil,
            onBeginDelivery: onBeginDelivery, onClose: onDismiss
        ).id(clips.map(\.id))
    }
}

struct MediaDeliveryPopup: View {
    let clips: [MediaClip]
    let maxCardHeight: CGFloat
    let preferredDestination: MediaDeliveryDestination?
    let capture: NikonMediaDeliveryCapture?
    var onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)?
    let onClose: () -> Void
    @Environment(NativeAppModel.self) private var model
    @Environment(MediaDeliveryCoordinator.self) private var coordinator: MediaDeliveryCoordinator?
    init(
        clip: MediaClip, preferredDestination: MediaDeliveryDestination? = nil,
        maxCardHeight: CGFloat = 520, onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)? = nil,
        onClose: @escaping () -> Void, capture: NikonMediaDeliveryCapture? = nil
    ) {
        self.init(
            clips: [clip], preferredDestination: preferredDestination, maxCardHeight: maxCardHeight,
            onBeginDelivery: onBeginDelivery, onClose: onClose, capture: capture)
    }
    init(
        clips: [MediaClip], preferredDestination: MediaDeliveryDestination? = nil,
        maxCardHeight: CGFloat = 520, onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)? = nil,
        onClose: @escaping () -> Void, capture: NikonMediaDeliveryCapture? = nil
    ) {
        self.clips = clips
        self.preferredDestination = preferredDestination
        self.maxCardHeight = maxCardHeight
        self.onBeginDelivery = onBeginDelivery
        self.onClose = onClose
        self.capture = capture
    }
    var body: some View {
        CapturedNikonMediaDeliveryPopup(
            model: model, coordinator: coordinator,
            clips: clips, capture: capture, preferredDestination: preferredDestination,
            maxCardHeight: maxCardHeight, onBeginDelivery: onBeginDelivery, onClose: onClose
        )
        .id(clips.map(\.id))
    }
}

private struct CapturedNikonMediaDeliveryPopup: View {
    @State private var source: NikonMediaDeliveryPreparationSource?
    let maxCardHeight: CGFloat?
    let onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)?
    let onClose: () -> Void
    init(
        model: NativeAppModel, coordinator: MediaDeliveryCoordinator?, clips: [MediaClip],
        capture: NikonMediaDeliveryCapture?, preferredDestination: MediaDeliveryDestination?,
        maxCardHeight: CGFloat?, onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)?,
        onClose: @escaping () -> Void
    ) {
        _source = State(
            initialValue: NikonMediaDeliveryPreparationSource(
                model: model, coordinator: coordinator,
                clips: clips, capture: capture, preferredDestination: preferredDestination))
        self.maxCardHeight = maxCardHeight
        self.onBeginDelivery = onBeginDelivery
        self.onClose = onClose
    }
    var body: some View {
        if let source {
            Group {
                if let maxCardHeight {
                    MonitorOperatorDeliveryScreen(
                        model: source.preparation, maxCardHeight: maxCardHeight,
                        onClose: {
                            source.close()
                            onClose()
                        },
                        onBegin: { source.begin($0, onBeginDelivery: onBeginDelivery) },
                        remoteArtwork: { Image("IconFrameio").resizable().scaledToFit() })
                } else {
                    MonitorOperatorDeliveryPopupOverlay(
                        model: source.preparation,
                        onDismiss: {
                            source.close()
                            onClose()
                        },
                        onBegin: { source.begin($0, onBeginDelivery: onBeginDelivery) },
                        remoteArtwork: { Image("IconFrameio").resizable().scaledToFit() })
                }
            }.onDisappear { source.close() }
        } else {
            Text("Media source changed. Reopen Share.").foregroundStyle(MonitorTheme.muted)
        }
    }
}

/// Original selection and bounded native ports. Popup task, state and options live in OpenCine.
@MainActor final class NikonMediaDeliveryPreparationSource {
    typealias Preparation = MonitorDeliveryPreparationModel<
        String, MediaExportFormat,
        FrameioProject, NikonFrameioProjectContext, FrameioInternetHop.Token?
    >
    let capture: NikonMediaDeliveryCapture
    let preparation: Preparation
    private let cancelPreflight: () -> Void
    init?(
        model: NativeAppModel, coordinator: MediaDeliveryCoordinator?, clips: [MediaClip],
        capture supplied: NikonMediaDeliveryCapture?,
        preferredDestination: MediaDeliveryDestination?
    ) {
        guard let captured = supplied ?? NikonMediaDeliveryCapture(model: model, clips: clips),
            captured.isCurrent
        else { return nil }
        capture = captured
        var preflight: MonitorDeliveryRunHandle?
        cancelPreflight = { preflight?.cancel() }
        let current = MonitorDeliveryAdmission { captured.isCurrent }
        let needsHop: @MainActor () -> Bool = { model.isOnCameraAccessPoint }
        let beginHop: @MainActor () -> FrameioInternetHop.Token? = {
            let rehostsMedia =
                model.activePanel == .media && !model.isStandaloneMediaLibraryPresented
            let handover: (@MainActor (FrameioInternetHop.Token) -> FrameioInternetHop.Token?)?
            if rehostsMedia {
                handover = { (old: FrameioInternetHop.Token) -> FrameioInternetHop.Token? in
                    guard captured.action.sourceIsCurrent,
                        let next = model.transferInternetHop(old),
                        captured.action.sourceIsCurrent, model.ownsInternetHop(next)
                    else { return nil }
                    captured.internetLease = next
                    model.pendingMediaDelivery = NikonPendingMediaDelivery(
                        capture: captured, token: next)
                    return next
                }
            } else {
                handover = nil
            }
            let token = model.beginInternetHopCaptured(
                admission: { captured.action.sourceIsCurrent }, handover: handover)
            if !rehostsMedia { captured.internetLease = token }
            return token
        }
        let ownsHop: @MainActor (FrameioInternetHop.Token?) -> Bool = {
            $0.map(model.ownsInternetHop) == true
        }
        let waitForHop: @MainActor (FrameioInternetHop.Token?) async -> Bool = { token in
            guard let token else { return false }
            return await model.waitForInternetPath(captured: token, timeoutSeconds: 30)
        }
        let restoreEnteredHop: @MainActor (FrameioInternetHop.Token?) async -> Void = { token in
            if let token { await model.restoreInternetHop(token) }
        }
        let restoreHop: @MainActor (FrameioInternetHop.Token?) -> Void = { token in
            if let token { _ = model.endInternetHopCaptured(token) }
        }
        let internet = MonitorDeliveryInternetService<FrameioInternetHop.Token?>(
            needsHop: needsHop, begin: beginHop, owns: ownsHop, wait: waitForHop,
            restoreEntered: restoreEnteredHop, restore: restoreHop)
        let remote = MonitorDeliveryRemoteService<
            FrameioProject, NikonFrameioProjectContext, FrameioInternetHop.Token?
        >(
            presentation: .init(displayName: "Frame.io", progressCaption: "Uploading to Frame.io"),
            observe: {
                let saved = captured.frameioDestination
                return .init(
                    configured: captured.frameioConfiguration != nil,
                    connected: model.isFrameioConnected && captured.account.isCurrent,
                    onCameraNetwork: model.isOnCameraAccessPoint,
                    savedProjectID: saved?.projectID, savedProjectName: saved?.projectName)
            },
            load: {
                if let token = captured.internetLease {
                    guard await model.waitForInternetPath(captured: token, timeoutSeconds: 30),
                        current.isCurrent()
                    else { throw CancellationError() }
                }
                let listing = try await model.loadFrameioProjectListing(
                    captured: captured, admission: current)
                return .init(
                    context: listing,
                    projects: listing.listing.projects.map {
                        .init(
                            id: $0.id, name: $0.name, uploadable: $0.rootFolderID.map { _ in true },
                            payload: $0)
                    })
            },
            create: { name, context in
                let project = try await model.createFrameioProject(
                    name: name, captured: captured, context: context, admission: current)
                return .init(
                    id: project.id, name: project.name,
                    uploadable: project.rootFolderID.map { _ in true }, payload: project)
            },
            persist: { project, context in
                model.persistFrameioDestination(
                    project: project.payload, context: context, captured: captured)
            },
            internet: internet,
            transfer: { token in
                guard let token, current.isCurrent(), let next = model.transferInternetHop(token)
                else { return nil }
                captured.internetLease = next
                return next
            })
        var configuration = MonitorDeliveryExportConfiguration(
            logTransform: "unchanged", exportFormat: MediaExportFormat.mov)
        configuration.bakeLUT = captured.cube != nil
        preparation = .init(
            selection: {
                .init(
                    files: captured.clips.map {
                        .init(
                            filename: $0.filename, sizeBytes: $0.sizeBytes > 0 ? $0.sizeBytes : nil)
                    },
                    cachedCount: captured.clips.filter(captured.isCached).count,
                    connected: captured.action.sourceIsCurrent && model.isConnected)
            }, configuration: configuration,
            exportOptions: .init(
                curves: [],
                formats: MediaExportFormat.allCases.map {
                    .init(id: $0.rawValue, label: $0.label, value: $0)
                },
                lutAvailable: { captured.cube != nil }, convertLogAvailable: { nil },
                lutLabel: { captured.lutLabel },
                convertHelp: "", convertUnavailableHelp: "", bakeExposureAvailable: { nil },
                formatsForRemoteUpload: false,
                filename: { configuration in
                    captured.clips.count == 1
                        ? captured.clips.first.map {
                            configuration.bakeLUT
                                ? ($0.filename as NSString).deletingPathExtension + "."
                                    + configuration.exportFormat.rawValue : $0.filename
                        } : nil
                }), remote: remote,
            preferredDestination: preferredDestination.map {
                $0 == .nativeShare ? .nativeShare : .remoteUpload
            },
            sourceCurrent: { captured.isCurrent },
            beforeInternetHop: {
                guard let coordinator else { throw CancellationError() }
                try await coordinator.cacheSelectionForDelivery(captured) { preflight = $0 }
            })
        if let token = captured.internetLease, !preparation.adoptInternetLease(token) { return nil }
    }
    func close() {
        preparation.close()
        cancelPreflight()
    }
    func begin(
        _ request: MonitorDeliveryPreparedRequest<
            String, MediaExportFormat, FrameioInternetHop.Token?
        >,
        onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)?
    ) {
        guard capture.isCurrent,
            request.destination != .remoteUpload || capture.account.isCurrent,
            let settings = request.configuration
        else {
            if let token = request.internetLease.flatMap({ $0 }) {
                _ = capture.model?.endInternetHopCaptured(token)
            }
            return
        }
        capture.internetLease = request.internetLease.flatMap { $0 }
        let config = MediaDeliveryConfiguration(
            bakeLUT: settings.bakeLUT, exportFormat: settings.exportFormat,
            includeMetadata: settings.includeMetadata, forceFrameioReupload: settings.forceReupload)
        onBeginDelivery?(
            .init(
                clips: capture.clips,
                destination: request.destination == .nativeShare ? .nativeShare : .frameio,
                configuration: config,
                postExportAction: request.action == .saveToPhotos ? .saveToPhotos : .systemShare,
                capture: capture))
    }
}
