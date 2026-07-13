import Foundation

/// Projects available in a Frame.io workspace for the delivery-sheet picker.
struct FrameioProjectListing: Equatable, Sendable {
    var accountID: String
    var workspaceID: String
    var workspaceName: String
    var projects: [FrameioProject]
}

/// The chosen Frame.io upload destination, persisted in UserDefaults.
struct FrameioDestination: Codable, Equatable {
    var accountID: String
    var workspaceID: String?
    var projectID: String
    var projectName: String
    var folderID: String

    private static let userDefaultsName = "frameio.destination.v1"

    static var loaded: FrameioDestination? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsName) else { return nil }
        return try? JSONDecoder().decode(FrameioDestination.self, from: data)
    }

    static func persist(_ destination: FrameioDestination?) {
        if let destination, let data = try? JSONEncoder().encode(destination) {
            UserDefaults.standard.set(data, forKey: userDefaultsName)
        } else {
            UserDefaults.standard.removeObject(forKey: userDefaultsName)
        }
    }
}

extension NativeAppModel {
    var frameioConfiguration: FrameioConfiguration? { FrameioConfig.configuration }
    var isFrameioConfigured: Bool { frameioConfiguration != nil }
    /// Configured AND holding a token. The keychain token outlives app deletion, so a build
    /// without Frame.io config can still find one — reporting it as "connected" there showed a
    /// Log out button in a build that can't use (or clear) the session.
    var isFrameioConnected: Bool { isFrameioConfigured && FrameioTokenStore.isConnected }

    /// Connects via Adobe IMS OAuth (`ASWebAuthenticationSession` + PKCE) and loads the user.
    func connectFrameio() async throws {
        guard let config = frameioConfiguration else { throw FrameioError.notConfigured }
        frameioConnecting = true
        defer { frameioConnecting = false }
        _ = try await FrameioAuthCoordinator(config: config).signIn()
        frameioUser = try? await FrameioService(config: config).currentUser()
    }

    func disconnectFrameio() {
        // Clearing the stored token needs no OAuth config — never gate log-out on it, or an
        // unconfigured build can't shed a keychain session left by a previous install.
        FrameioTokenStore.clear()
        frameioUser = nil
        FrameioDestination.persist(nil)
    }

    /// Uploads a clip to Frame.io with delivery-sheet options (filename, optional LUT bake, metadata).
    func uploadClipToFrameio(
        _ clip: MediaClip,
        options: MediaDeliveryUploadOptions,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async {
        let needsPrepare = options.bakeLUT && options.cube != nil
        let prepared: URL?
        if needsPrepare, let onProgress {
            let prepareProgress: @Sendable (Double) -> Void = { fraction in
                onProgress(fraction * 0.45)
            }
            prepared = try? await prepareUploadSource(
                for: clip, options: options, onProgress: prepareProgress)
            let uploadProgress: @Sendable (Double) -> Void = { fraction in
                onProgress(0.45 + fraction * 0.55)
            }
            await uploadClipToFrameio(
                clip,
                sourceURL: prepared,
                uploadName: options.filename,
                forceReupload: options.forceReupload,
                metadata: options.metadata,
                onProgress: uploadProgress
            )
        } else {
            prepared = try? await prepareUploadSource(
                for: clip, options: options, onProgress: nil)
            await uploadClipToFrameio(
                clip,
                sourceURL: prepared,
                uploadName: options.filename,
                forceReupload: options.forceReupload,
                metadata: options.metadata,
                onProgress: onProgress
            )
        }
    }

    /// Uploads a clip to Frame.io: connect if needed, resolve a destination project (the saved one,
    /// else the first project on the first account), then upload the LUT-baked export if present, else
    /// the cached clip. Updates the clip's `frameioStatus`. Skips when already uploading or uploaded.
    func uploadClipToFrameio(_ clip: MediaClip) async {
        await uploadClipToFrameio(
            clip, sourceURL: nil, uploadName: nil, forceReupload: false, metadata: nil,
            onProgress: nil)
    }

    /// Uploads a clip, optionally from a prepared export URL and with forced re-upload.
    func uploadClipToFrameio(
        _ clip: MediaClip,
        sourceURL preparedURL: URL?,
        forceReupload: Bool,
        onProgress: (@Sendable (Double) -> Void)?
    ) async {
        await uploadClipToFrameio(
            clip, sourceURL: preparedURL, uploadName: nil, forceReupload: forceReupload,
            metadata: nil, onProgress: onProgress)
    }

    func uploadClipToFrameio(
        _ clip: MediaClip,
        sourceURL preparedURL: URL?,
        uploadName: String?,
        forceReupload: Bool,
        metadata: MediaClipDeliveryMetadata?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async {
        guard let config = frameioConfiguration else {
            frameioUploadError = FrameioError.notConfigured.errorDescription
            return
        }
        guard !frameioUploadInFlight.contains(clip.id) else { return }

        let currentStatus =
            mediaClips.first { $0.id == clip.id }?.frameioStatus ?? clip.frameioStatus
        guard currentStatus != .uploading else { return }
        if !forceReupload, currentStatus == .uploaded { return }

        frameioUploadInFlight.insert(clip.id)
        defer { frameioUploadInFlight.remove(clip.id) }

        do {
            if !isFrameioConnected { try await connectFrameio() }
            let service = FrameioService(config: config)
            if frameioUser == nil { frameioUser = try? await service.currentUser() }
            let destination = try await resolveDestination(using: service)

            guard
                let sourceURL = preparedURL ?? exportedClipURL(for: clip) ?? clipLocalURL(clip)
            else { throw FrameioError.unsafeMediaFilename }
            let size = (FileManager.default.attributesOfItemSize(sourceURL)) ?? 0
            let name = uploadName ?? sourceURL.lastPathComponent
            let mediaType = FrameioMediaType.forFilename(name)

            frameioUploadProgress[clip.id] = 0
            setClipFrameioStatus(.uploading, for: clip)
            let fileID = try await service.upload(
                fileURL: sourceURL, name: name, mediaType: mediaType,
                fileSize: size, accountID: destination.accountID, folderID: destination.folderID
            ) { [self] fraction in
                frameioUploadProgress[clip.id] = fraction
                onProgress?(fraction)
            }
            frameioUploadProgress[clip.id] = nil
            if metadata != nil {
                try? writeFrameioMetadataSidecar(metadata, nextTo: sourceURL)
            }
            setClipFrameioUploaded(fileID: fileID, for: clip)
        } catch {
            frameioUploadProgress[clip.id] = nil
            setClipFrameioStatus(.failed, for: clip)
            frameioUploadError = error.localizedDescription
        }
    }

    func setClipFrameioStatus(_ status: FrameioStatus, for clip: MediaClip) {
        mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
            $0.frameioStatus = status
        }
        refreshMediaClips()
    }

    func setClipFrameioUploaded(fileID: String, for clip: MediaClip) {
        mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
            $0.frameioStatus = .uploaded
            $0.frameioFileID = fileID
        }
        refreshMediaClips()
    }

    /// The saved destination, or the first account's first project (auto-picked + saved).
    private func resolveDestination(using service: FrameioService) async throws
        -> FrameioDestination
    {
        if let saved = FrameioDestination.loaded { return saved }
        guard let account = try await service.accounts().first else { throw FrameioError.noProject }
        guard let workspace = try await service.workspaces(accountID: account.id).first else {
            throw FrameioError.noProject
        }
        guard
            let project = try await service.projects(
                accountID: account.id, workspaceID: workspace.id
            ).first,
            let folderID = project.rootFolderID
        else { throw FrameioError.noProject }
        let destination = FrameioDestination(
            accountID: account.id, workspaceID: workspace.id, projectID: project.id,
            projectName: project.name, folderID: folderID)
        FrameioDestination.persist(destination)
        return destination
    }

    /// Lists projects in the first account/workspace for the delivery-sheet picker.
    func loadFrameioProjectListing() async throws -> FrameioProjectListing {
        guard let config = frameioConfiguration else { throw FrameioError.notConfigured }
        if !isFrameioConnected { try await connectFrameio() }
        let service = FrameioService(config: config)
        if frameioUser == nil { frameioUser = try? await service.currentUser() }
        guard let account = try await service.accounts().first else { throw FrameioError.noProject }
        guard let workspace = try await service.workspaces(accountID: account.id).first else {
            throw FrameioError.noProject
        }
        let projects = try await service.projects(
            accountID: account.id, workspaceID: workspace.id)
        return FrameioProjectListing(
            accountID: account.id,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            projects: projects)
    }

    /// Creates a project in the given workspace and returns it.
    func createFrameioProject(
        name: String, accountID: String, workspaceID: String
    ) async throws -> FrameioProject {
        guard let config = frameioConfiguration else { throw FrameioError.notConfigured }
        if !isFrameioConnected { try await connectFrameio() }
        let service = FrameioService(config: config)
        return try await service.createProject(
            accountID: accountID, workspaceID: workspaceID, name: name)
    }

    /// Saves the operator's Frame.io upload target for subsequent uploads.
    func persistFrameioDestination(
        project: FrameioProject, accountID: String, workspaceID: String
    ) {
        guard let folderID = project.rootFolderID else { return }
        let destination = FrameioDestination(
            accountID: accountID,
            workspaceID: workspaceID,
            projectID: project.id,
            projectName: project.name,
            folderID: folderID)
        FrameioDestination.persist(destination)
    }

    private func exportedClipURL(for clip: MediaClip) -> URL? {
        guard clip.exportStatus == .exported else { return nil }
        let stem = (clip.filename as NSString).deletingPathExtension
        let exports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exports", isDirectory: true)
        let candidates = [
            exports.appendingPathComponent("\(stem).mov"),
            exports.appendingPathComponent("\(stem)_LUT.mov"),
            exports.appendingPathComponent("\(stem)_graded.mov"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func prepareUploadSource(
        for clip: MediaClip,
        options: MediaDeliveryUploadOptions,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        guard let localURL = clipLocalURL(clip) else {
            throw FrameioError.unsafeMediaFilename
        }
        guard options.bakeLUT, let cube = options.cube else { return localURL }

        let ext = (options.filename as NSString).pathExtension.lowercased()
        let format: MediaExportFormat = ext == "mp4" || ext == "m4v" ? .mp4 : .mov
        let result = try await MediaLUT.export(
            sourceURL: localURL,
            outputFilename: options.filename,
            format: format,
            cube: cube,
            metadata: nil
        ) { fraction in onProgress?(fraction) }
        setClipExportStatus(.exported, for: clip)
        return result.videoURL
    }

    private func writeFrameioMetadataSidecar(
        _ metadata: MediaClipDeliveryMetadata?, nextTo videoURL: URL
    ) throws {
        guard let metadata else { return }
        let url = videoURL.deletingPathExtension().appendingPathExtension("meta.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }
}

extension FileManager {
    fileprivate func attributesOfItemSize(_ url: URL) -> Int? {
        (try? attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}
