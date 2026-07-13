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
    let onBeginDelivery: (MediaDeliveryBeginRequest) -> Void
    let onDismiss: () -> Void

    @Environment(NativeAppModel.self) private var model

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
                    belowAnchorPanel(host: host, button: button, hasButton: hasButton)
                case .aboveAnchor:
                    aboveAnchorPanel(host: host, button: button, hasButton: hasButton)
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func belowAnchorPanel(host: CGRect, button: CGRect, hasButton: Bool) -> some View {
        let trailing = hasButton ? button.maxX : host.maxX - 24
        let leading = min(
            max(trailing - Self.width, host.minX + 12),
            host.maxX - Self.width - 12
        )
        let top = hasButton ? button.maxY + 8 : host.minY + 120
        let maxHeight = max(220, host.maxY - top - 24)

        panel(maxHeight: maxHeight)
            .frame(width: Self.width)
            .offset(x: leading - host.minX, y: top - host.minY)
    }

    @ViewBuilder
    private func aboveAnchorPanel(host: CGRect, button: CGRect, hasButton: Bool) -> some View {
        let trailingInset = hasButton ? host.maxX - button.maxX : 24
        let bottomInset = hasButton ? host.maxY - button.minY + 8 : 80
        let maxHeight = hasButton ? max(220, button.minY - host.minY - 24) : 520

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                panel(maxHeight: maxHeight)
                    .frame(width: Self.width)
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

    private enum DeliveryStep {
        case destination
        case options
    }

    init(
        clip: MediaClip,
        preferredDestination: MediaDeliveryDestination? = nil,
        onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.init(
            clips: [clip],
            preferredDestination: preferredDestination,
            onBeginDelivery: onBeginDelivery,
            onClose: onClose
        )
    }

    init(
        clips: [MediaClip],
        preferredDestination: MediaDeliveryDestination? = nil,
        onBeginDelivery: ((MediaDeliveryBeginRequest) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        // A preferred destination (post-hop resume) skips the destination picker and lands on
        // that destination's options step directly.
        _destination = State(initialValue: preferredDestination)
        _step = State(initialValue: preferredDestination == nil ? .destination : .options)
        self.clips = clips
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
        GlassPanel(
            padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summarySection
                        switch step {
                        case .destination:
                            destinationSection
                        case .options:
                            optionsSection
                        }
                        if let statusMessage { statusBanner(statusMessage) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                }

                if step == .options, !frameioHopGateActive {
                    optionsFooter
                        .padding(.top, 12)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            if !lutAvailable { configuration.bakeLUT = false }
            if let saved = FrameioDestination.loaded {
                selectedFrameioProjectID = saved.projectID
            }
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

    private var header: some View {
        Group {
            switch step {
            case .destination:
                destinationHeader
            case .options:
                optionsHeader
            }
        }
    }

    private var destinationHeader: some View {
        HStack(spacing: 10) {
            Label {
                Text("Share")
            } icon: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
            }
            .font(.system(size: 14, weight: .bold, design: .default))
            .kerning(1)
            .textCase(.uppercase)
            .foregroundStyle(LiveDesign.text)

            Spacer(minLength: 0)

            CloseButton(action: closePopup, size: 30)
        }
    }

    private var optionsHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                step = .destination
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiveDesign.accent)
            }
            .buttonStyle(.zcTapTarget)

            VStack(alignment: .leading, spacing: 2) {
                Text(destination?.title ?? "Share")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)
                    .lineLimit(1)
                Text("Options")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiveDesign.muted)
            }

            Spacer(minLength: 0)
        }
    }

    private var optionsFooter: some View {
        VStack(spacing: 10) {
            if destination == .nativeShare {
                Picker("Delivery action", selection: $shareAction) {
                    Text("Share").tag(MediaDeliveryPostExportAction.systemShare)
                    Text("Save to Photos").tag(MediaDeliveryPostExportAction.saveToPhotos)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Button {
                if destination == .nativeShare {
                    beginDelivery(postExportAction: shareAction)
                } else {
                    beginDelivery()
                }
            } label: {
                Text(footerActionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canContinue ? LiveDesign.text : LiveDesign.faint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        canContinue
                            ? LiveDesign.accent.opacity(0.22) : LiveDesign.hairline.opacity(0.25),
                        in: RoundedRectangle(
                            cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: DesignTokens.cornerRadius, style: .continuous
                        )
                        .strokeBorder(
                            canContinue
                                ? LiveDesign.accent.opacity(0.55)
                                : LiveDesign.hairline.opacity(0.35),
                            lineWidth: 1
                        )
                    )
            }
            .buttonStyle(.zcTapTarget)
            .disabled(!canContinue)
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
            // On-camera clips cache automatically when the camera is connected, so a selection
            // with nothing local yet is still deliverable.
            && (!downloadableClips.isEmpty || (model.isConnected && !clips.isEmpty))
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

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(clips.count) clip\(clips.count == 1 ? "" : "s")")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            if downloadableClips.count < clips.count {
                Text(
                    model.isConnected
                        ? "\(clips.count - downloadableClips.count) on-camera clip(s) will be cached from the camera first."
                        : "\(clips.count - downloadableClips.count) on-camera clip(s) will be skipped — reconnect the camera to cache them."
                )
                .font(.system(size: 12))
                .foregroundStyle(LiveDesign.muted)
            }
            if destination == .frameio, !model.isFrameioConfigured {
                Text("Frame.io isn't configured — see docs/frameio-setup.md.")
                    .font(.system(size: 12))
                    .foregroundStyle(LiveDesign.accent)
            } else if destination == .frameio, let projectName = frameioProjectSummaryName,
                step == .options
            {
                Text("Project: \(projectName)")
                    .font(.system(size: 12))
                    .foregroundStyle(LiveDesign.muted)
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            deliverySectionHeader("DESTINATION")
            ForEach(MediaDeliveryDestination.allCases) { candidate in
                destinationRow(candidate)
            }
        }
    }

    private func destinationRow(_ candidate: MediaDeliveryDestination) -> some View {
        let enabled = isDestinationEnabled(candidate)
        return Button {
            guard enabled else { return }
            destination = candidate
            step = .options
            if candidate == .frameio {
                Task { await loadFrameioProjects() }
            }
        } label: {
            HStack(spacing: 12) {
                destinationIcon(candidate)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(enabled ? LiveDesign.text : LiveDesign.faint)
                    Text(
                        candidate == .frameio && model.isFrameioConfigured
                            && !model.isFrameioConnected
                            ? "Sign in from Settings → Storage first."
                            : candidate.subtitle
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(LiveDesign.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LiveDesign.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                LiveDesign.hairline.opacity(0.35),
                in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.zcTapTarget)
        .disabled(!enabled)
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
        // On-camera clips cache automatically when the camera is connected.
        let hasDeliverableClips =
            !downloadableClips.isEmpty || (model.isConnected && !clips.isEmpty)
        switch candidate {
        case .nativeShare:
            return hasDeliverableClips
        case .frameio:
            // Sign-in lives in Settings → Storage; the card stays greyed until then.
            return model.isFrameioConfigured && model.isFrameioConnected && hasDeliverableClips
        }
    }

    private var frameioProjectPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                optionLabel(
                    "Project",
                    help: "Upload destination in your Frame.io workspace."
                )
                if let workspaceName = frameioListing?.workspaceName, !workspaceName.isEmpty {
                    HelpBadge(
                        text: "Projects are listed from workspace “\(workspaceName)”."
                    )
                }
            }

            if !model.isFrameioConnected {
                // Sign-in lives in Settings → Storage — the popup only configures the upload.
                // (Normally unreachable: the destination card is greyed out when signed out.)
                Text("Sign in to Frame.io from Settings → Storage to upload.")
                    .font(.system(size: 12))
                    .foregroundStyle(LiveDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // On the camera AP this picker isn't rendered — `frameioHopGate` gates the whole
            // option first (see optionsSection). Everything below assumes an internet path.
            if frameioProjectsLoading {
                HStack(spacing: 8) {
                    ProgressView().tint(LiveDesign.accent)
                    Text("Loading projects…")
                        .font(.system(size: 12))
                        .foregroundStyle(LiveDesign.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    LiveDesign.hairline.opacity(0.35),
                    in: RoundedRectangle(
                        cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                )
            } else if let frameioProjectsError {
                Text(frameioProjectsError)
                    .font(.system(size: 12))
                    .foregroundStyle(LiveDesign.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LiveDesign.hairline.opacity(0.35),
                        in: RoundedRectangle(
                            cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                    )
                Button("Retry") { Task { await loadFrameioProjects() } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiveDesign.accent)
            } else if frameioListing != nil {
                frameioProjectMenu

                Button {
                    newProjectName = ""
                    showCreateProjectAlert = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(LiveDesign.accent)
                        Text("Create new project")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LiveDesign.text)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        LiveDesign.hairline.opacity(0.35),
                        in: RoundedRectangle(
                            cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                    )
                }
                .buttonStyle(.zcTapTarget)
                .disabled(frameioProjectsLoading)

                if uploadableFrameioProjects.isEmpty {
                    Text("No projects yet — create one to upload.")
                        .font(.system(size: 12))
                        .foregroundStyle(LiveDesign.muted)
                }
            }
        }
    }

    /// Whether the Frame.io option is gated behind an internet hop. On the camera AP the whole
    /// flow — project pick, export config, upload — only makes sense once online, so the options
    /// step shows a single "Hop to internet" gate until the phone leaves the camera's Wi‑Fi.
    private var frameioHopGateActive: Bool {
        destination == .frameio && onCameraAP
    }

    /// Single entry point for Frame.io while on the camera's Wi‑Fi: one hop button (or a
    /// "switching networks" spinner) that leaves the AP; afterwards the normal project/export/
    /// upload options render via `optionsSection`.
    @ViewBuilder private var frameioHopGate: some View {
        Text(
            FrameioDestination.loaded.map {
                "Frame.io needs the internet. Hop off the camera's Wi‑Fi to pick a project (currently “\($0.projectName)”) and upload — the camera reconnects automatically when you're done."
            }
                ?? "Frame.io needs the internet. Hop off the camera's Wi‑Fi to sign in and pick a project — the camera reconnects automatically when you're done."
        )
        .font(.system(size: 13))
        .foregroundStyle(LiveDesign.muted)
        .fixedSize(horizontal: false, vertical: true)

        if isHoppingForFrameio {
            HStack(spacing: 8) {
                ProgressView().tint(LiveDesign.accent)
                Text("Switching networks…")
                    .font(.system(size: 13))
                    .foregroundStyle(LiveDesign.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                LiveDesign.hairline.opacity(0.35),
                in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
            )
        } else {
            Button {
                showFrameioHopConfirm = true
            } label: {
                Label("Hop to internet", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LiveDesign.accent.opacity(0.22),
                        in: RoundedRectangle(
                            cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: DesignTokens.cornerRadius, style: .continuous
                        )
                        .strokeBorder(LiveDesign.accent.opacity(0.55), lineWidth: 1)
                    )
            }
            .buttonStyle(.zcTapTarget)
        }
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

    private var frameioProjectMenu: some View {
        Menu {
            if uploadableFrameioProjects.isEmpty {
                Button("No projects") {}
                    .disabled(true)
            } else {
                ForEach(uploadableFrameioProjects) { project in
                    Button {
                        selectFrameioProject(project)
                    } label: {
                        if selectedFrameioProjectID == project.id {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(LiveDesign.muted)
                Text(selectedFrameioProject?.name ?? "Select a project")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        selectedFrameioProject != nil ? LiveDesign.text : LiveDesign.muted
                    )
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LiveDesign.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                LiveDesign.hairline.opacity(0.35),
                in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.zcTapTarget)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if destination == .frameio {
                VStack(alignment: .leading, spacing: 10) {
                    deliverySectionHeader(frameioHopGateActive ? "FRAME.IO" : "PROJECT")
                    if frameioHopGateActive {
                        frameioHopGate
                    } else {
                        frameioProjectPicker
                    }
                }
            }

            // On the camera AP the whole Frame.io option is gated behind the hop — export config
            // and the upload action only appear once online.
            if !frameioHopGateActive {
                exportSection
            }
        }
        // Kept at the options level (not on frameioProjectPicker, which isn't rendered while the
        // hop gate is up) so AP state keeps refreshing and the gate clears when the hop lands.
        .onAppear { onCameraAP = model.isOnCameraAccessPoint }
        .task {
            // Settle loop while Frame.io options are visible: flips the section to the online
            // project UI as a hop lands (AP state isn't observable), and lists projects the
            // moment a signed-in operator is online — the post-hop resume continues hands-free.
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
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                deliverySectionHeader("EXPORT")

                if let clip = clips.first, clips.count == 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Filename")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LiveDesign.muted)
                        Text(model.deliveryFilename(for: clip, configuration: configuration))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(LiveDesign.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LiveDesign.hairline.opacity(0.35),
                        in: RoundedRectangle(
                            cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                    )
                }

                deliveryToggleRow(
                    "Bake LUT",
                    help: lutAvailable
                        ? "Apply \(lutLabel) to exports."
                        : "No LUT selected — pick one in view assists.",
                    isOn: $configuration.bakeLUT,
                    disabled: !lutAvailable
                )

                if destination == .nativeShare {
                    VStack(alignment: .leading, spacing: 8) {
                        optionLabel(
                            "Format",
                            help:
                                "Export container for shared clips — MOV preserves quality; MP4 is more widely compatible."
                        )
                        Picker("Format", selection: $configuration.exportFormat) {
                            ForEach(MediaExportFormat.allCases) { format in
                                Text(format.label).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LiveDesign.hairline.opacity(0.35),
                        in: RoundedRectangle(
                            cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                    )
                }

                deliveryToggleRow(
                    "Include metadata",
                    help: "Filename, capture date, and size (best-effort JSON sidecar).",
                    isOn: $configuration.includeMetadata
                )

                if destination == .frameio {
                    deliveryToggleRow(
                        "Re-upload already uploaded",
                        help: "Skip clips already on Frame.io unless enabled.",
                        isOn: $configuration.forceFrameioReupload
                    )
                }
            }
        }
    }

    private func deliverySectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .kerning(0.6)
            .foregroundStyle(LiveDesign.faint)
    }

    private func deliveryToggleRow(
        _ title: String,
        help: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            optionLabel(title, help: help)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(LiveDesign.accent)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiveDesign.hairline.opacity(0.35),
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
        )
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    private func optionLabel(_ title: String, help: String) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HelpBadge(text: help)
        }
    }

    private var lutLabel: String {
        switch model.assistConfiguration.selectedLUT {
        case .builtIn(let look): look.rawValue
        case .stored(_, let name): (name as NSString).deletingPathExtension
        }
    }

    private func statusBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(LiveDesign.text)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LiveDesign.hairline.opacity(0.35),
                in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
            )
    }

    private func beginDelivery(postExportAction: MediaDeliveryPostExportAction = .systemShare) {
        guard let destination else { return }
        // On-camera clips cache automatically when the camera is connected, so an all-on-camera
        // selection is still deliverable.
        guard !downloadableClips.isEmpty || (model.isConnected && !clips.isEmpty) else {
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
