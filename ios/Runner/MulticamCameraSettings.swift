import Foundation
import MonitorUI
import OpenCineAppKit
import OpenCineCore
import OpenCineMulticam
import OpenZCineCore
import SwiftUI

/// A presentation receipt can retire on Main while a native transaction is waiting off Main.
private final class MulticamEditorReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func retire() { lock.withLock { active = false } }
}

/// A borrowed control surface over the member's existing session. Closing it retires only the
/// editor; accepted commands and the member's picture/connection retain their original owner.
@MainActor
final class MulticamEditorSession: CameraSession {
    nonisolated let id: CameraSessionID
    private let source: NikonCameraSession
    private let owner: NikonCommandOwner
    private let receipt = MulticamEditorReceipt()
    private let isCurrent: @MainActor () -> Bool
    private var rejected: [OperationID: CommandReceipt] = [:]
    private var subscribers: [UUID: AsyncStream<CameraSnapshot>.Continuation] = [:]
    private var feed: Task<Void, Never>?
    private var final: CameraSnapshot?

    init(
        source: NikonCameraSession, owner: NikonCommandOwner,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        id = source.id
        self.source = source
        self.owner = owner
        self.isCurrent = isCurrent
    }

    func snapshots() -> AsyncStream<CameraSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: CameraSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(final ?? source.refresh())
        guard final == nil else {
            continuation.finish()
            return stream
        }
        let token = UUID()
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[token] = nil }
        }
        if feed == nil {
            feed = Task { [weak self, source] in
                for await snapshot in source.snapshots() {
                    guard !Task.isCancelled, let self, self.final == nil else { return }
                    for continuation in self.subscribers.values { continuation.yield(snapshot) }
                }
            }
        }
        return stream
    }

    func submit(_ command: CameraCommand) -> CommandReceipt {
        if let known = rejected[command.operation] ?? source.receipt(of: command.operation) {
            return known
        }
        guard final == nil, receipt.isActive, isCurrent() else {
            let result = CommandReceipt(
                operation: command.operation, session: id, intent: command.intent,
                stage: .rejected(.authorityExpired))
            rejected[command.operation] = result
            return result
        }
        // Publish current facts before entering a transport queue. The native predicate only
        // copies an immutable snapshot and evaluates Core admission; no actor hop or I/O.
        source.refresh()
        let token = receipt
        let source = source
        let admission = NikonCommandAdmission(owner: owner) {
            token.isActive && source.commandSnapshot.rejection(of: command, at: .now()) == nil
        }
        return source.submit(command, admission: admission)
    }

    func receipt(of operation: OperationID) -> CommandReceipt? {
        rejected[operation] ?? source.receipt(of: operation)
    }

    func outcome(of operation: OperationID) async -> CommandReceipt? {
        if let denied = rejected[operation] { return denied }
        return await source.outcome(of: operation)
    }

    func close(_ reason: SessionCloseReason) {
        guard final == nil else { return }
        receipt.retire()
        feed?.cancel()
        feed = nil
        var closed = source.refresh()
        closed.connection = .disconnected(reason)
        closed.authority = .unavailable(.authority)
        closed.revision = closed.revision.next()
        final = closed
        for continuation in subscribers.values {
            continuation.yield(closed)
            continuation.finish()
        }
        subscribers.removeAll()
    }
}

@MainActor
@Observable
final class MulticamCameraEditor: Identifiable {
    let id: EditorLeaseID
    let lease: EditorLease
    let member: MonitorEntryID
    let control = MonitorControlModel()
    @ObservationIgnored let session: MulticamEditorSession

    init(
        member: MonitorEntryID, lease: EditorLease, source: NikonCameraSession,
        owner: NikonCommandOwner, isCurrent: @escaping @MainActor () -> Bool
    ) {
        id = lease.id
        self.lease = lease
        self.member = member
        session = MulticamEditorSession(source: source, owner: owner, isCurrent: isCurrent)
        control.bind(session)
    }

    func retire() {
        session.close(.requested)
        control.unbind()
    }
}

/// The shared inspector and typed capture drums, bound only to the selected member's editor.
struct MulticamCameraSettings: View {
    @Bindable var coordinator: MulticamCoordinator
    let editor: MulticamCameraEditor
    let viewport: MultiviewStageViewport
    private let fields: [SettingKey] = [
        .iso, .shutter, .aperture, .whiteBalance, .exposureCompensation, .focusMode, .frameRate,
    ]

    var body: some View {
        MonitorInspector(
            title: "Camera", viewport: viewport.size, safeArea: viewport.safeArea,
            hasNavigation: false, closeIdentifier: "monitor.capture.close",
            onClose: coordinator.closeCameraSettings
        ) {
            EmptyView()
        } content: {
            VStack(spacing: 12) {
                MonitorCaptureTabs(
                    options: coordinator.members.filter {
                        coordinator.cameraSettingsSlots.contains($0.slot)
                    }.map(\.slot),
                    selection: coordinator.member(editor.member)?.slot,
                    title: { coordinator.member(atSlot: $0)?.letter ?? "" },
                    identifier: { "multiview.settings.camera.\($0)" },
                    select: coordinator.openCameraSettings)
                if let image = coordinator.member(editor.member)?.frame {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 180).accessibilityIdentifier("multiview.settings.preview")
                }
                ForEach(fields, id: \.self) { key in
                    if let field = editor.control.captureField(key) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.title).font(MonitorTheme.font(11, weight: .semibold))
                                .foregroundStyle(MonitorTheme.muted)
                            MonitorCaptureDrum(control: editor.control, field: field)
                                .id(field.editor)
                                .accessibilityIdentifier("multiview.settings.\(key.rawValue)")
                        }
                    }
                }
            }
        } footer: {
            EmptyView()
        }
        .accessibilityIdentifier("multiview.settings.panel")
    }
}
