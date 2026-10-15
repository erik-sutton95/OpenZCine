import Foundation
import OpenCineAppKit
import OpenCineFrameIO
import OpenCineFrameIOApple
import OpenCineMedia
import OpenZCineCore
import os

/// OpenZCine's Frame.io namespaces over the shared Apple host (A2-57). The keychain service and
/// destination key are unchanged, so saved sign-ins and the remembered project keep working.
enum NikonFrameio {
    static var tokens: FrameioKeychainTokenStore { .init(service: "OpenZCine.frameio") }
    static var destinations: FrameioDestinationStore { .init(key: "frameio.destination.v1") }
    static let logger = Logger(subsystem: "OpenZCine", category: "frameio")
}

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
        account: NikonFrameioAccount.Receipt, native: any FrameioTokenStorage = NikonFrameio.tokens
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
    var frameioConfiguration: FrameioConfiguration? { FrameioAppConfiguration.read() }
    var isFrameioConfigured: Bool { frameioConfiguration != nil }
    /// Configured AND holding a token. The keychain token outlives app deletion, so a build
    /// without Frame.io config can still find one; reporting it as "connected" there showed a
    /// Log out button in a build that can't use (or clear) the session.
    var isFrameioConnected: Bool { isFrameioConfigured && NikonFrameio.tokens.load() != nil }

    /// The settings task retains the exact account receipt it presented before native sign-in.
    func connectFrameio(captured account: NikonFrameioAccount.Receipt) async throws {
        guard let config = frameioConfiguration else { throw FrameioError.notConfigured }
        guard account.isCurrent, !Task.isCancelled else { throw CancellationError() }
        _ = try await FrameioWebAuthenticator(
            config: config,
            transport: NikonFrameioAdmittedTransport(
                native: FrameioURLSessionTransport(session: .shared),
                admission: .init { account.isCurrent }),
            tokens: NikonFrameioCapturedTokens(account: account)
        ).signIn()
        guard account.isCurrent, !Task.isCancelled else { throw CancellationError() }
    }

    func disconnectFrameio() {
        // Clearing the stored token needs no OAuth config. Never gate log-out on it, or an
        // unconfigured build can't shed a keychain session left by a previous install.
        _ = frameioAccount.retire()
        NikonFrameio.tokens.clear()
        NikonFrameio.destinations.persist(nil)
    }

    func loadFrameioProjectListing(
        captured: NikonMediaDeliveryCapture, admission: MonitorDeliveryAdmission
    ) async throws -> NikonFrameioProjectContext {
        // Every request of the shared listing passes the captured transport's admission.
        let listing = try await captured.frameioClient(admission: admission)
            .firstWorkspaceProjects()
        guard admission.isCurrent(), captured.account.isCurrent else { throw CancellationError() }
        return .init(listing: listing, account: captured.account)
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
        guard context.account.isCurrent, captured.account.isCurrent, captured.isCurrent,
            let destination = FrameioDestination(project: project, in: context.listing)
        else { return }
        captured.frameioDestination = destination
        NikonFrameio.destinations.persist(destination)
    }
    func uploadCapturedFrameio(
        _ clip: MediaClip, source: URL,
        capture: NikonMediaDeliveryCapture,
        admission supplied: MonitorDeliveryAdmission,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let admission = MonitorDeliveryAdmission {
            supplied.isCurrent() && capture.account.isCurrent
        }
        guard admission.isCurrent() else { throw CancellationError() }
        guard frameioUploadInFlight[clip.id] == nil else { throw FrameioError.uploadIncomplete }
        let ticket = UUID()
        frameioUploadInFlight[clip.id] = ticket
        defer {
            if frameioUploadInFlight[clip.id] == ticket { frameioUploadInFlight[clip.id] = nil }
        }
        let service = try capture.frameioClient(admission: admission)
        let destination: FrameioDestination
        if let saved = capture.frameioDestination {
            destination = saved
        } else {
            let context = try await loadFrameioProjectListing(
                captured: capture, admission: admission)
            guard let project = context.listing.projects.first,
                let first = FrameioDestination(project: project, in: context.listing)
            else { throw FrameioError.noProject }
            guard admission.isCurrent() else { throw CancellationError() }
            destination = first
            capture.frameioDestination = first
            NikonFrameio.destinations.persist(first)
        }
        try MonitorMediaShareStaging.validateShareableFile(at: source)
        let size =
            (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?
            .intValue ?? 0
        guard size > 0, admission.isCurrent() else { throw CancellationError() }
        capture.update(clip) { $0.frameioStatus = .uploading }
        let name = source.lastPathComponent
        do {
            let fileID = try await service.upload(
                fileURL: source, name: name,
                mediaType: FrameioMediaType.forFilename(name), fileSize: size,
                accountID: destination.accountID, folderID: destination.folderID
            ) { fraction in
                await MainActor.run {
                    guard admission.isCurrent(), self.frameioUploadInFlight[clip.id] == ticket
                    else { return }
                    progress(fraction)
                }
            }
            guard admission.isCurrent(), frameioUploadInFlight[clip.id] == ticket else {
                throw CancellationError()
            }
            NikonFrameio.logger.info(
                "uploaded \(name, privacy: .private(mask: .hash)) → file \(fileID, privacy: .private(mask: .hash))"
            )
            capture.update(clip) {
                $0.frameioStatus = .uploaded
                $0.frameioFileID = fileID
            }
        } catch {
            if admission.isCurrent(), frameioUploadInFlight[clip.id] == ticket {
                capture.update(clip) { $0.frameioStatus = .failed }
            }
            throw error
        }
    }
}
