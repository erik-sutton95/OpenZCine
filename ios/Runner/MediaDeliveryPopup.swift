import MonitorPresentation
import MonitorUI
import OpenCineFrameIO
import OpenZCineCore
import SwiftUI
import UIKit

/// Drives delivery popup presentation from playback transport buttons.
struct MediaDeliveryPresentation: Identifiable {
    let id = UUID()
    let clip: MediaClip
    /// Opens the popup pre-set to this destination (post-hop resume lands straight on the
    /// Frame.io step instead of the destination picker).
    var preferredDestination: MediaDeliveryDestination? = nil
}

/// Drives delivery popup presentation from the media browser selection bar.
struct MediaDeliveryRequest: Identifiable {
    let id = UUID()
    let clips: [MediaClip]
    /// Opens the popup pre-set to this destination (see ``MediaDeliveryPresentation``).
    var preferredDestination: MediaDeliveryDestination? = nil
}

/// Where the delivery popup anchors relative to its trigger button.
enum MediaDeliveryPopupPlacement {
    case belowAnchor
    case aboveAnchor
}

/// Dimmed overlay + anchored `MediaDeliveryPopup` — mirrors `MediaFilterPopup` positioning.
struct MediaDeliveryPopupOverlay: View {
    let clips: [MediaClip]
    let anchorFrame: CGRect
    let placement: MediaDeliveryPopupPlacement
    var preferredDestination: MediaDeliveryDestination? = nil
    /// Safe area of the host surface — the popup itself is full-bleed.
    var safeArea: MonitorEdgeInsets = .zero
    let onBeginDelivery: (MediaDeliveryBeginRequest) -> Void
    let onDismiss: () -> Void

    @Environment(NativeAppModel.self) private var model

    /// Preferred, not guaranteed: `MediaPopupPlacement` shrinks it to fit a compact phone.
    static let width: CGFloat = 420

    var body: some View {
        GeometryReader { proxy in
            let host = proxy.frame(in: .global)
            let button = anchorFrame
            let hasButton = button.width > 1

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                switch placement {
                case .belowAnchor:
                    belowAnchorPanel(host: host, button: button)
                case .aboveAnchor:
                    aboveAnchorPanel(host: host, button: button, hasButton: hasButton)
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func belowAnchorPanel(host: CGRect, button: CGRect) -> some View {
        let place = MediaPopupPlacement.below(
            anchor: button, host: host, safeArea: safeArea,
            preferredWidth: Self.width, minimumHeight: 220)

        panel(maxHeight: place.maxHeight)
            .frame(width: place.width)
            .offset(x: place.x, y: place.y)
    }

    @ViewBuilder
    private func aboveAnchorPanel(host: CGRect, button: CGRect, hasButton: Bool) -> some View {
        // Same width/leading rule as every other media popup; only the vertical anchor differs
        // (the panel sizes to its content upwards, so it hangs off a bottom inset).
        let place = MediaPopupPlacement.fitted(
            anchor: button, host: host, safeArea: safeArea, preferredWidth: Self.width)
        let trailingInset = max(0, host.width - place.x - place.width)
        let bottomInset = hasButton ? host.maxY - button.minY + 8 : 80
        let maxHeight = hasButton ? max(220, button.minY - host.minY - 24) : 520

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                panel(maxHeight: maxHeight)
                    .frame(width: place.width)
            }
            .padding(.trailing, trailingInset)
            .padding(.bottom, bottomInset)
        }
        .frame(width: host.width, height: host.height)
    }

    private func panel(maxHeight: CGFloat) -> some View {
        MediaDeliveryPopup(
            clips: clips,
            preferredDestination: preferredDestination,
            maxCardHeight: maxHeight,
            onBeginDelivery: onBeginDelivery,
            onClose: onDismiss
        )
        .environment(model)
        .frame(maxHeight: maxHeight, alignment: .top)
    }
}

/// Delivery popup: pick destination → configure options (Frame.io project picker inline). Progress shows on the clip/grid.
struct MediaDeliveryPopup: View {
    let clips: [MediaClip]
    let maxCardHeight: CGFloat
    var onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)?
    let onClose: () -> Void

    @Environment(NativeAppModel.self) private var model

    @State private var step: DeliveryStep = .destination
    @State private var destination: MediaDeliveryDestination?
    @State private var configuration = MediaDeliveryConfiguration()
    @State private var statusMessage: String?

    @State private var frameioListing: FrameioProjectListing?
    @State private var frameioProjectsLoading = false
    @State private var frameioProjectsError: String?
    @State private var selectedFrameioProjectID: String?
    @State private var showCreateProjectAlert = false
    @State private var newProjectName = ""
    /// Consent alert before leaving the camera's Wi‑Fi for Frame.io setup.
    @State private var showFrameioHopConfirm = false
    /// True while iOS settles on an internet network after the consented hop.
    @State private var isHoppingForFrameio = false
    /// Whether THIS popup started the active hop — dismissing without delivering then rejoins
    /// the camera (a delivery hands the hop to the runner instead).
    @State private var popupStartedHop = false
    /// Live camera-AP state for the Frame.io section. Polled: AP detection is address-based
    /// (not observable), so nothing else re-renders the section when the hop settles.
    @State private var onCameraAP = false
    @State private var shareAction: MediaDeliveryPostExportAction = .systemShare

    private enum DeliveryStep: Hashable {
        case destination
        case options
    }

    init(
        clip: MediaClip,
        preferredDestination: MediaDeliveryDestination? = nil,
        maxCardHeight: CGFloat = 520,
        onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.init(
            clips: [clip],
            preferredDestination: preferredDestination,
            maxCardHeight: maxCardHeight,
            onBeginDelivery: onBeginDelivery,
            onClose: onClose
        )
    }

    init(
        clips: [MediaClip],
        preferredDestination: MediaDeliveryDestination? = nil,
        maxCardHeight: CGFloat = 520,
        onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        // A preferred destination (post-hop resume) skips the destination picker and lands on
        // that destination's options step directly.
        _destination = State(initialValue: preferredDestination)
        _step = State(initialValue: preferredDestination == nil ? .destination : .options)
        self.clips = clips
        self.maxCardHeight = maxCardHeight
        self.onBeginDelivery = onBeginDelivery
        self.onClose = onClose
    }

    private var lutAvailable: Bool { model.currentLUTCube() != nil }
    private var downloadableClips: [MediaClip] {
        clips.filter { model.isClipDownloaded($0) }
    }

    private var selectedFrameioProject: FrameioProject? {
        guard let listing = frameioListing, let id = selectedFrameioProjectID else { return nil }
        return listing.projects.first { $0.id == id }
    }

    private var frameioProjectSummaryName: String? {
        selectedFrameioProject?.name ?? FrameioDestination.loaded?.projectName
    }

    private var uploadableFrameioProjects: [FrameioProject] {
        frameioListing?.projects.filter { $0.rootFolderID != nil } ?? []
    }

    var body: some View {
        MonitorMediaDeliveryPanel(
            value: deliveryValue,
            maxCardHeight: maxCardHeight,
            action: handleDeliveryAction,
            destinationIcon: { id in
                if let destination = MediaDeliveryDestination(rawValue: id) {
                    destinationIcon(destination)
                }
            }
        )
        .onAppear {
            if step == .options { onCameraAP = model.isOnCameraAccessPoint }
            if !lutAvailable { configuration.bakeLUT = false }
            if let saved = FrameioDestination.loaded {
                selectedFrameioProjectID = saved.projectID
            }
        }
        .onChange(of: step) { _, next in
            if next == .options { onCameraAP = model.isOnCameraAccessPoint }
        }
        .task(id: step) {
            guard step == .options else { return }
            onCameraAP = model.isOnCameraAccessPoint
            while !Task.isCancelled {
                onCameraAP = model.isOnCameraAccessPoint
                if destination == .frameio, model.isFrameioConfigured, model.isFrameioConnected,
                    !onCameraAP, frameioListing == nil, !frameioProjectsLoading,
                    frameioProjectsError == nil
                {
                    await loadFrameioProjects()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .alert("Leave camera Wi‑Fi?", isPresented: $showFrameioHopConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Hop") { startFrameioHop() }
        } message: {
            Text(
                "We'll hop to home Wi‑Fi or cellular so you can sign in and pick a project. The camera reconnects automatically when you're done."
            )
        }
        .alert("New Frame.io project", isPresented: $showCreateProjectAlert) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) { newProjectName = "" }
            Button("Create") {
                let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                newProjectName = ""
                guard !name.isEmpty else { return }
                Task { await createFrameioProject(named: name) }
            }
            .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Creates a blank project in your workspace.")
        }
    }

    private var deliveryValue: MonitorMediaDeliveryValue {
        var notices: [MonitorMediaDeliveryValue.Notice] = []
        if downloadableClips.count < clips.count {
            notices.append(
                .init(
                    model.isConnected
                        ? "\(clips.count - downloadableClips.count) on-camera clip(s) will be cached from the camera first."
                        : "\(clips.count - downloadableClips.count) on-camera clip(s) will be skipped - reconnect the camera to cache them."
                ))
        }
        if destination == .frameio, !model.isFrameioConfigured {
            notices.append(
                .init("Frame.io isn't configured - see docs/frameio-setup.md.", accented: true))
        } else if destination == .frameio, let projectName = frameioProjectSummaryName,
            step == .options
        {
            notices.append(.init("Project: \(projectName)"))
        }
        let configuring = step == .options && !frameioHopGateActive
        return .init(
            step: step == .destination ? .destination : .options,
            title: destination?.title ?? "Share",
            selectionLabel: "\(clips.count) clip\(clips.count == 1 ? "" : "s")",
            notices: notices,
            destinations: MediaDeliveryDestination.allCases.map { candidate in
                .init(
                    id: candidate.rawValue,
                    title: candidate.title,
                    subtitle: candidate == .frameio && model.isFrameioConfigured
                        && !model.isFrameioConnected
                        ? "Sign in from Settings → Storage first." : candidate.subtitle,
                    enabled: isDestinationEnabled(candidate)
                )
            },
            service: destination == .frameio ? frameioService : nil,
            export: configuring
                ? MediaDeliveryPanelValue.export(
                    configuration: configuration,
                    lutAvailable: lutAvailable,
                    lutLabel: lutLabel,
                    filename: clips.count == 1
                        ? clips.first.map {
                            model.deliveryFilename(for: $0, configuration: configuration)
                        } : nil,
                    destination: destination
                ) : nil,
            footer: configuring
                ? .init(
                    postExport: destination == .nativeShare
                        ? MediaDeliveryPanelValue.postExport(shareAction) : nil,
                    actionTitle: footerActionTitle,
                    enabled: canContinue
                ) : nil,
            status: statusMessage
        )
    }

    private var frameioService: MonitorMediaDeliveryValue.Service {
        if frameioHopGateActive {
            return .internetGate(
                heading: "FRAME.IO",
                message: FrameioDestination.loaded.map {
                    "Frame.io needs the internet. Hop off the camera's Wi‑Fi to pick a project (currently “\($0.projectName)”) and upload - the camera reconnects automatically when you're done."
                }
                    ?? "Frame.io needs the internet. Hop off the camera's Wi‑Fi to sign in and pick a project - the camera reconnects automatically when you're done.",
                busy: isHoppingForFrameio
            )
        }
        let workspaceHelp =
            frameioListing.flatMap { $0.workspaceName.isEmpty ? nil : $0.workspaceName }.map {
                " Projects are listed from workspace “\($0)”."
            } ?? ""
        return .projects(
            heading: "PROJECT",
            help: "Upload destination in your Frame.io workspace." + workspaceHelp,
            signInNotice: model.isFrameioConnected
                ? nil : "Sign in to Frame.io from Settings → Storage to upload.",
            loading: frameioProjectsLoading,
            error: frameioProjectsError,
            choices: frameioListing.map { _ in
                uploadableFrameioProjects.map { .init(id: $0.id, label: $0.name) }
            },
            selectedID: selectedFrameioProjectID,
            selectedLabel: selectedFrameioProject?.name
                ?? FrameioDestination.loaded.flatMap {
                    $0.projectID == selectedFrameioProjectID ? $0.projectName : nil
                }
        )
    }

    private func handleDeliveryAction(_ action: MonitorMediaDeliveryValue.Action) {
        switch action {
        case .close: closePopup()
        case .back: step = .destination
        case .begin:
            beginDelivery(
                postExportAction: destination == .nativeShare ? shareAction : .systemShare)
        case .hopToInternet: showFrameioHopConfirm = true
        case .retryProjects: Task { await loadFrameioProjects() }
        case .createProject:
            newProjectName = ""
            showCreateProjectAlert = true
        case .destination(let id):
            guard let candidate = MediaDeliveryDestination(rawValue: id),
                isDestinationEnabled(candidate)
            else { return }
            destination = candidate
            step = .options
            if candidate == .frameio { Task { await loadFrameioProjects() } }
        case .option(let option, let enabled):
            switch option {
            case .bakeLUT: configuration.bakeLUT = enabled
            case .includeMetadata: configuration.includeMetadata = enabled
            case .reupload: configuration.forceFrameioReupload = enabled
            case .convertLog, .bakeExposure: break
            }
        case .selection(let selection, let id):
            switch selection {
            case .format:
                if let format = MediaExportFormat(rawValue: id) {
                    configuration.exportFormat = format
                }
            case .postExport:
                if id == "systemShare" {
                    shareAction = .systemShare
                } else if id == "saveToPhotos" {
                    shareAction = .saveToPhotos
                }
            case .project:
                if let project = uploadableFrameioProjects.first(where: { $0.id == id }) {
                    selectFrameioProject(project)
                }
            case .outputCurve: break
            }
        }
    }

    private var footerActionTitle: String {
        switch destination {
        case .nativeShare:
            shareAction == .saveToPhotos ? "Save to Photos" : "Share"
        case .frameio:
            destination?.actionTitle ?? "Upload"
        case .none:
            "Continue"
        }
    }

    private var canContinue: Bool {
        destination != nil
            && MediaDeliveryEligibility.canDeliver(
                localCount: downloadableClips.count,
                totalCount: clips.count,
                cameraConnected: model.isConnected)
            && !(configuration.bakeLUT && !lutAvailable)
            && !(destination == .frameio && !frameioProjectReady)
    }

    /// Frame.io upload is allowed once a project with a root folder is selected and persisted.
    private var frameioProjectReady: Bool {
        guard destination == .frameio else { return true }
        // Sign-in lives in Settings → Storage; no upload without it.
        guard model.isFrameioConnected else { return false }
        if selectedFrameioProject?.rootFolderID != nil { return true }
        if FrameioDestination.loaded != nil { return true }
        // On the camera AP the project list is unreachable — the delivery runner hops to the
        // internet, signs in if needed, and auto-picks (and persists) the first project.
        return model.isOnCameraAccessPoint
    }

    @ViewBuilder
    private func destinationIcon(_ candidate: MediaDeliveryDestination) -> some View {
        switch candidate {
        case .nativeShare:
            Image(systemName: candidate.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(LiveDesign.text)
        case .frameio:
            Image("IconFrameio")
                .resizable()
                .scaledToFit()
                .foregroundStyle(
                    model.isFrameioConfigured ? LiveDesign.text : LiveDesign.faint)
        }
    }

    private func isDestinationEnabled(_ candidate: MediaDeliveryDestination) -> Bool {
        let hasDeliverableClips = MediaDeliveryEligibility.canDeliver(
            localCount: downloadableClips.count,
            totalCount: clips.count,
            cameraConnected: model.isConnected)
        switch candidate {
        case .nativeShare:
            return hasDeliverableClips
        case .frameio:
            // Sign-in lives in Settings → Storage; the card stays greyed until then.
            return model.isFrameioConfigured && model.isFrameioConnected && hasDeliverableClips
        }
    }

    /// Whether the Frame.io option is gated behind an internet hop. On the camera AP the whole
    /// flow — project pick, export config, upload — only makes sense once online, so the options
    /// step shows a single "Hop to internet" gate until the phone leaves the camera's Wi‑Fi.
    private var frameioHopGateActive: Bool {
        destination == .frameio && onCameraAP
    }

    /// Consented Frame.io setup hop: leave the camera AP, wait for a real internet path, then
    /// run the normal project load (which presents the Adobe sign-in when needed). Once off-AP
    /// the picker renders its regular sign-in / project UI.
    private func startFrameioHop() {
        isHoppingForFrameio = true
        popupStartedHop = true
        // If the hop re-hosts the browser (monitor media panel), this view's state dies with
        // it — stash the share context so the standalone browser can land the operator back.
        model.pendingHopShareResumeClips = clips
        model.beginInternetHop()
        Task {
            let online = await model.waitForInternetPath(timeoutSeconds: 30)
            isHoppingForFrameio = false
            if online {
                await loadFrameioProjects()
            } else {
                frameioProjectsError =
                    "Couldn't reach the internet after leaving the camera's Wi‑Fi. Check cellular or home Wi‑Fi."
            }
        }
    }

    /// Popup dismissal that abandons an in-popup network hop: if the operator hopped for
    /// Frame.io setup but never began a delivery, rejoin the camera on the way out.
    private func closePopup() {
        if popupStartedHop {
            model.endInternetHop()
        }
        onClose()
    }

    private var lutLabel: String {
        switch model.assistConfiguration.selectedLUT {
        case .builtIn(let look): look.rawValue
        case .stored(_, let name): (name as NSString).deletingPathExtension
        }
    }

    private func beginDelivery(postExportAction: MediaDeliveryPostExportAction = .systemShare) {
        guard let destination else { return }
        guard
            MediaDeliveryEligibility.canDeliver(
                localCount: downloadableClips.count,
                totalCount: clips.count,
                cameraConnected: model.isConnected)
        else {
            statusMessage = MediaDeliveryError.emptySelection.localizedDescription
            return
        }
        // An in-popup setup hop hands over to the delivery runner, which rejoins the camera
        // once the upload finishes — closing the popup must not rejoin mid-delivery.
        popupStartedHop = false
        if configuration.bakeLUT, !lutAvailable {
            statusMessage = MediaDeliveryError.noLUTSelected.localizedDescription
            return
        }
        if destination == .frameio, !model.isFrameioConfigured {
            statusMessage = "Frame.io isn't configured in this build."
            return
        }
        if destination == .frameio, !frameioProjectReady {
            statusMessage = FrameioError.noProject.errorDescription
            return
        }

        let request = MediaDeliveryBeginRequest(
            clips: clips,
            destination: destination,
            configuration: configuration,
            postExportAction: postExportAction
        )
        onBeginDelivery?(request)
        onClose()
    }

    private func loadFrameioProjects() async {
        guard model.isFrameioConfigured else {
            frameioProjectsError = FrameioError.notConfigured.errorDescription
            return
        }
        frameioProjectsLoading = true
        frameioProjectsError = nil
        defer { frameioProjectsLoading = false }
        do {
            let listing = try await model.loadFrameioProjectListing()
            frameioListing = listing
            if selectedFrameioProjectID == nil,
                let saved = FrameioDestination.loaded,
                listing.projects.contains(where: { $0.id == saved.projectID })
            {
                selectedFrameioProjectID = saved.projectID
            } else if selectedFrameioProjectID == nil,
                let first = listing.projects.first(where: { $0.rootFolderID != nil })
            {
                selectFrameioProject(first)
            } else if let project = selectedFrameioProject {
                persistFrameioProject(project)
            }
        } catch {
            frameioProjectsError = error.localizedDescription
        }
    }

    private func createFrameioProject(named name: String) async {
        guard let listing = frameioListing else {
            frameioProjectsError = FrameioError.noProject.errorDescription
            return
        }
        frameioProjectsLoading = true
        frameioProjectsError = nil
        defer { frameioProjectsLoading = false }
        do {
            let project = try await model.createFrameioProject(
                name: name, accountID: listing.accountID, workspaceID: listing.workspaceID)
            var updated = listing
            updated.projects.insert(project, at: 0)
            frameioListing = updated
            selectFrameioProject(project)
        } catch {
            frameioProjectsError = error.localizedDescription
        }
    }

    private func selectFrameioProject(_ project: FrameioProject) {
        guard project.rootFolderID != nil else { return }
        selectedFrameioProjectID = project.id
        persistFrameioProject(project)
    }

    private func persistFrameioProject(_ project: FrameioProject) {
        guard let listing = frameioListing else { return }
        model.persistFrameioDestination(
            project: project, accountID: listing.accountID, workspaceID: listing.workspaceID)
    }
}
