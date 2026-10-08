import Foundation
import OpenCineAppKit
import OpenCineFrameIO
import os

/// One instance account epoch. The native token transaction and retirement share this lock.
final class NikonFrameioAccount: @unchecked Sendable {
    struct Receipt: Sendable {
        fileprivate let owner: NikonFrameioAccount
        fileprivate let revision: UUID
        var identity: UUID { revision }
        var isCurrent: Bool { owner.revision.withLock { $0 == revision } }
        func perform<T: Sendable>(_ operation: @Sendable () -> T) -> T? {
            owner.revision.withLock { current in
                guard current == revision else { return nil }
                return operation()
            }
        }
    }
    private let revision = OSAllocatedUnfairLock(initialState: UUID())
    func capture() -> Receipt { revision.withLock { .init(owner: self, revision: $0) } }
    @discardableResult func retire() -> Receipt {
        revision.withLock {
            $0 = UUID()
            return .init(owner: self, revision: $0)
        }
    }
}

/// Synchronous credential IO never invokes a UI predicate from the shared client's executor.
struct NikonFrameioCapturedTokens: FrameioTokenStorage {
    let account: NikonFrameioAccount.Receipt
    let native: any FrameioTokenStorage
    init(
        account: NikonFrameioAccount.Receipt, native: any FrameioTokenStorage = FrameioTokenStore()
    ) {
        self.account = account
        self.native = native
    }
    func load() -> StoredFrameioToken? {
        guard !Task.isCancelled else { return nil }
        return account.perform { native.load() } ?? nil
    }
    func save(_ stored: StoredFrameioToken) {
        guard !Task.isCancelled else { return }
        _ = account.perform { native.save(stored) }
    }
    func clear() {
        guard !Task.isCancelled else { return }
        _ = account.perform { native.clear() }
    }
}

/// Same native transport; each first unsent request checks its captured operation on MainActor.
@MainActor struct NikonFrameioAdmittedTransport: FrameioHTTPTransport {
    let native: any FrameioHTTPTransport
    let admission: MonitorDeliveryAdmission
    func send(_ request: FrameioAPIRequest) async throws -> FrameioHTTPResponse {
        guard admission.isCurrent() else { throw CancellationError() }
        let response = try await native.send(request)
        guard admission.isCurrent() else { throw CancellationError() }
        return response
    }
}

struct NikonFrameioProjectContext: Sendable {
    let listing: FrameioProjectListing
    let account: NikonFrameioAccount.Receipt
}

extension NativeAppModel {
    func loadFrameioProjectListing(
        captured: NikonMediaDeliveryCapture,
        admission: MonitorDeliveryAdmission
    ) async throws -> NikonFrameioProjectContext {
        let service = try captured.frameioClient(admission: admission)
        guard admission.isCurrent() else { throw CancellationError() }
        guard let account = try await service.accounts().first else { throw FrameioError.noProject }
        guard admission.isCurrent() else { throw CancellationError() }
        guard let workspace = try await service.workspaces(accountID: account.id).first else {
            throw FrameioError.noProject
        }
        guard admission.isCurrent() else { throw CancellationError() }
        let projects = try await service.projects(accountID: account.id, workspaceID: workspace.id)
        guard admission.isCurrent(), captured.account.isCurrent else { throw CancellationError() }
        return .init(
            listing: .init(
                accountID: account.id, workspaceID: workspace.id,
                workspaceName: workspace.name, projects: projects), account: captured.account)
    }
    func createFrameioProject(
        name: String, captured: NikonMediaDeliveryCapture,
        context: NikonFrameioProjectContext, admission: MonitorDeliveryAdmission
    ) async throws -> FrameioProject {
        guard context.account.isCurrent, captured.account.isCurrent, admission.isCurrent() else {
            throw CancellationError()
        }
        let service = try captured.frameioClient(admission: admission)
        let project = try await service.createProject(
            accountID: context.listing.accountID,
            workspaceID: context.listing.workspaceID, name: name)
        guard context.account.isCurrent, captured.account.isCurrent, admission.isCurrent() else {
            throw CancellationError()
        }
        return project
    }
    func persistFrameioDestination(
        project: FrameioProject, context: NikonFrameioProjectContext,
        captured: NikonMediaDeliveryCapture
    ) {
        guard context.account.isCurrent, captured.account.isCurrent, captured.isCurrent else {
            return
        }
        guard let folder = project.rootFolderID else { return }
        let destination = FrameioDestination(
            accountID: context.listing.accountID, workspaceID: context.listing.workspaceID,
            projectID: project.id, projectName: project.name, folderID: folder)
        captured.frameioDestination = destination
        FrameioDestination.persist(destination)
    }
    func uploadCapturedFrameio(
        _ clip: MediaClip, source: URL, metadata: MediaClipDeliveryMetadata?,
        capture: NikonMediaDeliveryCapture,
        admission supplied: MonitorDeliveryAdmission,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        uploadName: String? = nil, existingTicket: UUID? = nil
    ) async throws {
        let admission = MonitorDeliveryAdmission {
            supplied.isCurrent() && capture.account.isCurrent && supplied.isCurrent()
                && capture.account.isCurrent
        }
        guard admission.isCurrent(), capture.account.isCurrent else { throw CancellationError() }
        let ticket: UUID
        if let existingTicket {
            guard frameioUploadInFlight[clip.id] == existingTicket else {
                throw CancellationError()
            }
            ticket = existingTicket
        } else {
            guard frameioUploadInFlight[clip.id] == nil else { throw FrameioError.uploadIncomplete }
            ticket = UUID()
            frameioUploadInFlight[clip.id] = ticket
        }
        defer {
            if existingTicket == nil, frameioUploadInFlight[clip.id] == ticket {
                frameioUploadInFlight[clip.id] = nil
            }
        }
        let service = try capture.frameioClient(admission: admission)
        let destination: FrameioDestination
        if let saved = capture.frameioDestination {
            destination = saved
        } else {
            let context = try await loadFrameioProjectListing(
                captured: capture, admission: admission)
            guard let project = context.listing.projects.first,
                let folder = project.rootFolderID
            else { throw FrameioError.noProject }
            destination = .init(
                accountID: context.listing.accountID, workspaceID: context.listing.workspaceID,
                projectID: project.id, projectName: project.name, folderID: folder)
            guard admission.isCurrent() else { throw CancellationError() }
            capture.frameioDestination = destination
            FrameioDestination.persist(destination)
        }
        try MediaShareStaging.validateReadableFile(at: source)
        let size =
            (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?
            .intValue ?? 0
        guard size > 0, admission.isCurrent() else { throw CancellationError() }
        frameioUploadProgress[clip.id] = 0
        capture.update(clip) { $0.frameioStatus = .uploading }
        let name = uploadName ?? source.lastPathComponent
        do {
            let fileID = try await service.upload(
                fileURL: source, name: name,
                mediaType: FrameioMediaType.forFilename(name), fileSize: size,
                accountID: destination.accountID, folderID: destination.folderID
            ) { fraction in
                await MainActor.run {
                    guard admission.isCurrent(), self.frameioUploadInFlight[clip.id] == ticket
                    else { return }
                    self.frameioUploadProgress[clip.id] = fraction
                    progress(fraction)
                }
            }
            guard admission.isCurrent(), frameioUploadInFlight[clip.id] == ticket else {
                throw CancellationError()
            }
            frameioLogger.info(
                "uploaded \(name, privacy: .private(mask: .hash)) → file \(fileID, privacy: .private(mask: .hash))"
            )
            frameioUploadProgress[clip.id] = nil
            if metadata != nil { try? writeFrameioMetadataSidecar(metadata, nextTo: source) }
            capture.update(clip) {
                $0.frameioStatus = .uploaded
                $0.frameioFileID = fileID
            }
        } catch {
            if admission.isCurrent(), frameioUploadInFlight[clip.id] == ticket {
                frameioUploadProgress[clip.id] = nil
                capture.update(clip) { $0.frameioStatus = .failed }
            }
            throw error
        }
    }
}
