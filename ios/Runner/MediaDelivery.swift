import Foundation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineCameraControls
import OpenCineFrameIO
import OpenCineFrameIOApple
import OpenCineMedia
import OpenZCineCore
import SwiftUI
import os

/// OpenZCine's side of delivery: the Nikon capture, its export, Frame.io account and the camera
/// AP hop. Run lifetime, progress, staging, Photos, share and the popup are the shared owners'.
typealias NikonDeliveryConfiguration = MonitorDeliveryExportConfiguration<
    String, MonitorMediaExporter.Format
>
typealias NikonHopToken = MonitorInternetHop<NikonHopRoute>.Token
typealias NikonDeliveryPopup = MonitorOperatorDeliveryPopupHost<
    String, MonitorMediaExporter.Format, FrameioProject, NikonFrameioProjectContext,
    NikonHopToken, FrameioMark
>

/// Where an internet hop leaves from and returns to (the Nikon side of A2-16).
struct NikonHopRoute {
    let host: String
    let displayName: String?
    /// The open Media or Settings page stays over the cameras page while the phone is away.
    let rehostActivePanel: Bool
    /// The camera AP the phone left, once it has.
    var ssid: String? = nil
}

/// The Nikon Wi‑Fi joiner calls of the hop. Tests replace them; a nil `rejoin` runs the full
/// camera join pipeline.
struct NikonHopNative {
    var currentSSID: @MainActor () async -> String? = {
        await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
    }
    /// Leaves the AP; `current` says whether the hop still holds, so a removal still queued
    /// behind a pending camera join never reaches the OS for a hop that already ended.
    var leaveNetwork: @MainActor (String, _ current: @escaping @MainActor () -> Bool) -> Void = {
        ssid, current in WiFiJoinCoordinator.shared.leaveCameraNetwork(ssid: ssid, isCurrent: current)
    }
    var rejoin: (@MainActor (_ host: String, _ ssid: String) async -> Void)?
}

/// Best-effort clip metadata written beside exports when the operator enables metadata:
/// OpenZCine's sidecar schema, with the body's model and serial.
struct MediaClipDeliveryMetadata: Codable, Sendable {
    let filename: String
    let captureDate: String
    let sizeBytes: UInt64
    let cameraName: String?
    let cameraModel: String?
    let cameraSerial: String?
    let lutName: String?
    let exportedAt: Date

    static func from(
        _ clip: MediaClip, camera: NativeCameraIdentity? = nil, lutName: String? = nil
    ) -> MediaClipDeliveryMetadata {
        MediaClipDeliveryMetadata(
            filename: clip.filename,
            captureDate: clip.captureDate,
            sizeBytes: clip.sizeBytes,
            cameraName: camera?.displayName,
            cameraModel: camera?.model.isEmpty == false ? camera?.model : nil,
            cameraSerial: camera?.serialNumber.isEmpty == false ? camera?.serialNumber : nil,
            lutName: lutName,
            exportedAt: Date()
        )
    }
}

enum NikonDelivery {
    static let logger = Logger(subsystem: "OpenZCine", category: "media-export")

    /// A still travels as its original, so the popup offers it no clip export: no Bake LUT,
    /// format or renamed movie (ZIB-469).
    static func selectionFile(_ clip: MediaClip) -> MonitorDeliveryFileFacts {
        .init(filename: clip.filename, sizeBytes: clip.sizeBytes > 0 ? clip.sizeBytes : nil,
            isStill: clip.mediaKind == .photo)
    }
    private static let timecodeLogger = Logger(subsystem: "OpenZCine", category: "media-timecode")

    @Sendable static func traceTimecode(_ diagnostic: MonitorMovieTimecode.Diagnostic) {
        switch diagnostic.level {
        case .information: timecodeLogger.info("\(diagnostic.message, privacy: .public)")
        case .error: timecodeLogger.error("\(diagnostic.message, privacy: .public)")
        }
    }

    /// The "Include metadata" share text of the delivered clips.
    static func metadataSummary(for clips: [MediaClip]) -> String {
        MonitorDeliveryMetadataSummary.text(
            files: clips.map {
                .init(
                    filename: $0.filename,
                    captureDate: $0.captureDate.isEmpty ? nil : $0.captureDate,
                    sizeBytes: $0.sizeBytes > 0 ? $0.sizeBytes : nil)
            },
            formatBytes: ByteCountLabel.label)
    }
}

extension NativeAppModel {
    /// The shared delivery popup over one captured selection, and its begin on the app's
    /// coordinator (A2-74). Nil when the selection's source is gone.
    func deliveryPopup(
        _ capture: NikonMediaDeliveryCapture, preferred: MonitorDeliveryDestination? = nil,
        coordinator: MonitorDeliveryCoordinator
    ) -> NikonDeliveryPopup.Made? {
        guard capture.isCurrent else { return nil }
        let current = MonitorDeliveryAdmission { capture.isCurrent }
        let hop = internetHop.deliveryService(
            route: { [weak self] in self?.hopRoute() },
            admission: { capture.action.sourceIsCurrent })
        // Once the camera session has gone, the lease the capture holds is its source.
        let internet = MonitorDeliveryInternetService<NikonHopToken>(
            needsHop: hop.needsHop,
            begin: {
                let token = hop.begin()
                capture.internetLease = token
                return token
            }, owns: hop.owns, wait: hop.wait, restoreEntered: hop.restoreEntered,
            restore: hop.restore)
        let remote = frameioRemote(capture, current: current, internet: internet)
        var configuration = NikonDeliveryConfiguration(
            logTransform: "unchanged", exportFormat: .mov)
        configuration.bakeLUT = capture.cube != nil
        let model = NikonDeliveryPopup.Preparation(
            selection: { [weak self] in
                .init(
                    files: capture.clips.map(NikonDelivery.selectionFile),
                    cachedCount: capture.clips.filter(capture.isCached).count,
                    connected: capture.action.sourceIsCurrent && self?.isConnected == true)
            }, configuration: configuration,
            exportOptions: .init(
                curves: [],
                formats: MonitorMediaExporter.Format.allCases.map {
                    .init(id: $0.rawValue, label: $0.label, value: $0)
                },
                lutAvailable: { capture.cube != nil }, convertLogAvailable: { nil },
                lutLabel: { capture.lutLabel }, convertHelp: "", convertUnavailableHelp: "",
                bakeExposureAvailable: { nil }, formatsForRemoteUpload: false,
                filename: { configuration in
                    capture.clips.count == 1
                        ? capture.clips.first.map {
                            capture.filename($0, configuration: configuration)
                        }
                        : nil
                }), remote: remote, preferredDestination: preferred,
            sourceCurrent: { capture.isCurrent },
            beforeInternetHop: {
                try await coordinator.cacheBeforeInternetHop(
                    records: capture.clips, originals: capture.originals,
                    source: .init { capture.action.sourceIsCurrent }, filename: \.filename,
                    uploadCaption: remote.presentation.progressCaption)
            })
        let begin: (NikonDeliveryPopup.Preparation.Request) -> Void = { [weak self] request in
            let remoteRun = request.destination == .remoteUpload
            guard let self, capture.isCurrent, !remoteRun || capture.account.isCurrent,
                let configuration = request.configuration
            else {
                if let lease = request.internetLease { internet.restore(lease) }
                return
            }
            capture.internetLease = request.internetLease
            coordinator.begin { admission, progress in
                let accepted = MonitorDeliveryAdmission {
                    admission.isCurrent() && capture.isCurrent
                        && (!remoteRun || capture.account.isCurrent)
                }
                return await coordinator.run(
                    records: capture.clips, destination: request.destination,
                    action: request.action, admission: accepted,
                    source: self.deliverySource(
                        capture, configuration: configuration, admission: accepted),
                    includeMetadata: configuration.includeMetadata,
                    remote: remoteRun
                        ? self.frameioRun(
                            capture, configuration: configuration, admission: accepted)
                        : nil,
                    internet: internet, lease: request.internetLease, progress: progress)
            }
        }
        return (model, begin)
    }

    /// The Nikon clips as a delivery source: stills as their cached originals, movies exported.
    private func deliverySource(
        _ capture: NikonMediaDeliveryCapture, configuration: NikonDeliveryConfiguration,
        admission: MonitorDeliveryAdmission
    ) -> MonitorDeliverySource<MediaClip> {
        .init(
            originals: capture.originals,
            still: { clip in
                guard clip.mediaKind == .photo, admission.isCurrent(), capture.isCached(clip)
                else { return nil }
                return capture.localURL(clip)
            },
            export: { clip, store, progress in
                try await capture.export(
                    clip, configuration: configuration, store: store, admission: admission,
                    progress: progress)
            },
            filename: \.filename, metadata: NikonDelivery.metadataSummary(for:),
            noPrepared: { _ in "Nothing to share." })
    }

    /// One accepted Frame.io run: the captured account and destination, and the clip's Frame.io
    /// status as its upload history (A2-53).
    private func frameioRun(
        _ capture: NikonMediaDeliveryCapture, configuration: NikonDeliveryConfiguration,
        admission: MonitorDeliveryAdmission
    ) -> MonitorDeliveryRemoteRun<MediaClip> {
        .init(
            progressCaption: "Uploading to Frame.io",
            upload: { [weak self] clip, url, progress in
                guard let self else { throw CancellationError() }
                try await self.uploadCapturedFrameio(
                    clip, source: url, capture: capture, admission: admission, progress: progress)
            },
            history: .init(
                wasUploaded: { clip in
                    let row = capture.store.list(cameraID: clip.cameraID).first { $0.id == clip.id }
                    return (row ?? clip).frameioStatus == .uploaded
                },
                // The upload itself records `.uploaded` on the clip.
                recordUploaded: { _ in }),
            reupload: configuration.forceReupload)
    }

    /// The popup's Frame.io service over the captured account.
    private func frameioRemote(
        _ capture: NikonMediaDeliveryCapture, current: MonitorDeliveryAdmission,
        internet: MonitorDeliveryInternetService<NikonHopToken>
    ) -> MonitorDeliveryRemoteService<FrameioProject, NikonFrameioProjectContext, NikonHopToken> {
        let choice: (FrameioProject) -> MonitorDeliveryProject<FrameioProject> = {
            .init(
                id: $0.id, name: $0.name, uploadable: $0.rootFolderID.map { _ in true }, payload: $0
            )
        }
        return .init(
            presentation: .init(displayName: "Frame.io", progressCaption: "Uploading to Frame.io"),
            observe: { [weak self] in
                let saved = capture.frameioDestination
                return .init(
                    configured: capture.frameioConfiguration != nil,
                    connected: self?.isFrameioConnected == true && capture.account.isCurrent,
                    onCameraNetwork: self?.isOnCameraAccessPoint == true,
                    savedProjectID: saved?.projectID, savedProjectName: saved?.projectName)
            },
            load: { [weak self] in
                guard let self else { throw CancellationError() }
                if let token = capture.internetLease {
                    guard await self.internetHop.waitForInternet(token), current.isCurrent()
                    else { throw CancellationError() }
                }
                let context = try await self.loadFrameioProjectListing(
                    captured: capture, admission: current)
                return .init(context: context, projects: context.listing.projects.map(choice))
            },
            create: { [weak self] name, context in
                guard let self else { throw CancellationError() }
                return choice(
                    try await self.createFrameioProject(
                        name: name, captured: capture, context: context, admission: current))
            },
            persist: { [weak self] project, context in
                self?.persistFrameioDestination(
                    project: project.payload, context: context, captured: capture)
            },
            internet: internet,
            transfer: { [weak self] token in
                guard current.isCurrent(), let next = self?.internetHop.transfer(token) else {
                    return nil
                }
                capture.internetLease = next
                return next
            }, skipsUploaded: true)
    }
}

/// One opened delivery popup: the captured selection, keyed for the popup's identity.
struct NikonDeliveryRequest: Identifiable {
    let id = UUID()
    let capture: NikonMediaDeliveryCapture

    /// The shared popup; `onDismiss` runs once it closes, after a begin or a cancel.
    @MainActor func popup(
        _ model: NativeAppModel, coordinator: MonitorDeliveryCoordinator,
        onDismiss: @escaping () -> Void
    ) -> NikonDeliveryPopup {
        NikonDeliveryPopup(
            selectionID: id,
            make: { model.deliveryPopup(capture, coordinator: coordinator) },
            onDismiss: onDismiss,
            remoteArtwork: { FrameioMark() }
        )
    }
}
