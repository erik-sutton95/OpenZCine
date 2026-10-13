import Foundation
import MonitorPresentation
import OpenCineCore
import OpenCineMulticam
import OpenZCineCore
import UIKit

/// What a member's pump needs from its link beyond the command side (`NikonControlTransport`).
/// `NativeCameraSession` provides it; tests script it.
protocol MulticamMemberLink: NikonControlTransport {
    var serialNumber: String { get }
    func configureMemberLiveView() async
    func startLiveView() async throws
    func stopLiveView() async
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame
    func readStorageInfo() async throws -> PTPStorageInfo?
    /// Graceful CloseSession, then the sockets. Never a record command.
    func shutdown() async
}

/// Operator-facing multicam sentences. Never "sync" or "genlock": a group press is coordinated
/// dispatch with per-camera confirmation, not synchronized recording.
enum MulticamCopy {
    static let sessionFull = "Multicam holds four cameras."
    static let alreadyMember = "That camera is already on the stage."
    static let cameraWiFi = "Camera Wi-Fi can't join a multicam session."
    static let hdmi = "HDMI isn't part of multicam."
    static let movieOnly = "Movie mode only."
    static let notReachable = "Not reachable."
    static let emptyPicker =
        "No other cameras reachable. Pair one, or plug USB-C / join the same network."
    static let couldntConnect = "Couldn't connect"
    static let lostConnection = "Connection lost"
    static let couldntRec = "Couldn't rec"
    static let changed = "Cameras changed. Try again."

    static func refusal(_ reason: NikonMulticamRefusal) -> String {
        switch reason {
        case .alreadyMember: alreadyMember
        case .cameraAccessPoint: cameraWiFi
        case .hdmiCapture: hdmi
        case .photographyMode: movieOnly
        case .notReachable: notReachable
        }
    }

    static func confirm(_ direction: RecordDirection, names: [String]) -> String {
        direction == .start
            ? "Start recording on \(names.joined(separator: ", "))?"
            : "Stop recording on \(names.count) \(names.count == 1 ? "camera" : "cameras")?"
    }

    /// `nil` when every addressed camera rolls.
    static func mixedStart(rolling: Int, total: Int, firstFailed: String) -> String? {
        rolling < total ? "\(rolling) of \(total) rolling. \(firstFailed) didn't start." : nil
    }

    static func notApplied(_ setting: String) -> String { "\(setting) not applied" }
}

/// One stage tile's camera: its saved path, its own link, pump and Nikon member control.
@MainActor
@Observable
final class MulticamMember: Identifiable {
    enum Status: Equatable {
        case connecting
        case live
        case failed(String)
    }

    let id = MonitorEntryID()
    /// Which of the four fixed tiles shows it (A-D). Kept while it stays.
    let slot: Int
    let record: PTPIPSavedCameraRecord
    var status = Status.connecting
    var frame: UIImage?
    var timecode: Timecode?
    /// Camera-reported (live-view header); `nil` until a frame says.
    var recording: Bool? {
        didSet {
            // Nikon reports no take length, so the tile times it from the first recording frame.
            if recording != true {
                recordingSince = nil
            } else if recordingSince == nil {
                recordingSince = Date()
            }
        }
    }
    private(set) var recordingSince: Date?
    /// Values exactly as read back from this camera.
    var properties = PTPCameraPropertySnapshot()
    var storage: PTPStorageInfo?
    /// The last command that did not land on this camera, shown on its tile.
    var note: String?
    /// The member identity: the body serial, from the saved record until the link reports one.
    var device: CameraDeviceID?

    @ObservationIgnored var link: (any MulticamMemberLink)?
    @ObservationIgnored var control: NikonMemberControl?
    @ObservationIgnored var pump: Task<Void, Never>?

    init(slot: Int, record: PTPIPSavedCameraRecord) {
        self.slot = slot
        self.record = record
        device = NikonMulticamPolicy.device(serialNumber: record.serialNumber)
    }

    var displayName: String { record.displayTitle }
    var letter: String { ["A", "B", "C", "D"][min(3, max(0, slot))] }
    var isLive: Bool { status == .live }
    var batteryReading: BatteryReading? { control?.session.refresh().power.batteryReading }

    var batteryPercent: Int? {
        properties.batteryPercent.flatMap { (0...100).contains($0) ? $0 : nil }
    }
}

/// OpenZCine multicam on the shared engine: up to four Nikon bodies on four fixed tiles. The
/// engine (`MulticamGroup`, `RecordPlan`, `EditorLeases`, `ResourceAdmission`) decides membership,
/// group record targets and per-camera results; OpenCineNikon decides which paths may join and
/// owns each member's command queue; this type runs one pump per member and keeps tile state.
@MainActor
@Observable
final class MulticamCoordinator {
    /// App qualification policy (engine-port's tested product limit), not an engine constant.
    static let budget = ResourceBudget(qualifiedEntries: 4)
    static var tileCount: Int {
        guard let count = budget.qualifiedEntries else {
            preconditionFailure("Multicam requires a finite app qualification budget")
        }
        return count
    }

    var isPresented = false
    var arrangement = MultiviewPresentationLayout.Arrangement.centerStage
    /// The selected tile; its member is the program camera (assists, values, Live View).
    var focusedSlot = 0
    var toast: String?
    private(set) var members: [MulticamMember] = []
    private(set) var groupBusy = false
    /// The member lent to the single-camera Live View, if any.
    private(set) var lentMember: MonitorEntryID?
    /// Engine membership: members with a live control session, in tile order.
    private(set) var group = MulticamGroup()
    @ObservationIgnored private var leases = EditorLeases()

    /// Opens one member's own link (the app model's establish path). Set before `begin`.
    @ObservationIgnored var connect:
        @MainActor (PTPIPSavedCameraRecord) async throws -> any MulticamMemberLink = { _ in
            throw CancellationError()
        }
    @ObservationIgnored private let isCameraRefusal: @Sendable (any Error) -> Bool
    /// Seconds between member polls; the app sheds non-program cadence under thermal load.
    @ObservationIgnored var pollInterval: @MainActor (_ isProgram: Bool, _ base: Double) -> Double =
        { _, base in base }
    @ObservationIgnored var whiteBalancePresets: [String] = []
    @ObservationIgnored var frameDeadline: Duration = .seconds(10)
    @ObservationIgnored var recordObservationTimeout: Duration = .seconds(5)

    init(isCameraRefusal: @escaping @Sendable (any Error) -> Bool) {
        self.isCameraRefusal = isCameraRefusal
    }

    // MARK: Tiles

    func member(atSlot slot: Int) -> MulticamMember? { members.first { $0.slot == slot } }
    func member(_ id: MonitorEntryID) -> MulticamMember? { members.first { $0.id == id } }
    var program: MulticamMember? { member(atSlot: focusedSlot) }
    var anyRecording: Bool { members.contains { $0.recording == true } }
    var canRecord: Bool { !group.entries.isEmpty && !groupBusy }

    func begin() {
        end()
        isPresented = true
        arrangement = .centerStage
        focusedSlot = 0
    }

    /// Closes every member link (CloseSession). Never stops a recording.
    func end() {
        for member in members { stop(member) }
        members = []
        group = MulticamGroup()
        leases.closeAll()
        lentMember = nil
        groupBusy = false
        toast = nil
        isPresented = false
    }

    // MARK: Adding cameras

    /// Why `record` cannot join now, as operator copy, or `nil` when it may.
    func refusal(for record: PTPIPSavedCameraRecord, reachable: Bool) -> String? {
        guard let reason = admission(record, reachable: reachable).first else { return nil }
        switch reason {
        case .integrationRefused(.alreadyMember): return MulticamCopy.alreadyMember
        case .integrationRefused(.unsupportedConfiguration): return MulticamCopy.cameraWiFi
        case .integrationRefused(.operationUnavailable):
            return record.path?.kind == .hdmiCapture ? MulticamCopy.hdmi : MulticamCopy.movieOnly
        case .integrationRefused(.notReachable): return MulticamCopy.notReachable
        case .qualificationUnknown: return "Multicam support is not known for this setup."
        default: return MulticamCopy.sessionFull
        }
    }

    /// Adds a saved body on `slot` when that tile is empty, else on the first empty tile.
    @discardableResult
    func add(_ record: PTPIPSavedCameraRecord, reachable: Bool, slot: Int? = nil) -> MulticamMember?
    {
        if let reason = refusal(for: record, reachable: reachable) {
            toast = reason
            return nil
        }
        let taken = Set(members.map(\.slot))
        guard
            let target = slot.flatMap({ taken.contains($0) ? nil : $0 })
                ?? (0..<Self.tileCount).first(where: { !taken.contains($0) })
        else {
            toast = MulticamCopy.sessionFull
            return nil
        }
        let member = MulticamMember(slot: target, record: record)
        if program == nil { focusedSlot = target }
        members.append(member)
        start(member)
        return member
    }

    func retry(_ id: MonitorEntryID) {
        guard let member = member(id) else { return }
        stop(member)
        member.status = .connecting
        member.note = nil
        start(member)
    }

    /// Removes one camera and closes its link. Never stops its recording.
    func remove(_ id: MonitorEntryID) {
        guard let member = member(id) else { return }
        if lentMember == id { lentMember = nil }
        stop(member)
        members.removeAll { $0.id == id }
        if member.slot == focusedSlot, let next = members.min(by: { $0.slot < $1.slot }) {
            focusedSlot = next.slot
        }
    }

    func select(slot: Int) {
        focusedSlot = slot
        if let id = member(atSlot: slot)?.id, group[id] != nil { try? group.setStage(id) }
    }

    // MARK: Group record

    /// The group start (nothing rolling) or stop over every connected member. Nikon keeps its
    /// mixed-result default: command the eligible cameras and show the rest.
    func groupPlan() -> RecordPlan {
        plan(entries: group.entries.map(\.id))
    }

    /// One camera's own start or stop (its tile menu, or a "Couldn't rec" retry).
    func plan(for id: MonitorEntryID) -> RecordPlan { plan(entries: [id]) }

    func names(_ plan: RecordPlan) -> [String] {
        plan.targets.flatMap(\.entries).compactMap { member($0)?.displayName }
    }

    func run(_ plan: RecordPlan) async {
        guard !groupBusy else { return }
        groupBusy = true
        defer { groupBusy = false }
        let sessions = sessionMap()
        let submission: RecordSubmission
        do {
            submission = try await plan.submit(in: group, at: engineState(), sessions: sessions)
        } catch {
            if error == .stale { toast = MulticamCopy.changed }
            return
        }
        apply(await submission.finished(sessions: sessions))
    }

    private func plan(entries: [MonitorEntryID]) -> RecordPlan {
        let rolling = entries.contains { member($0)?.recording == true }
        return RecordPlan.make(
            rolling ? .stop : .start, policy: .eligibleSubset, entries: entries, in: group,
            at: engineState())
    }

    private func apply(_ result: RecordResult) {
        let plan = result.plan
        var failed: [MulticamMember] = []
        for target in plan.targets {
            let confirmed = result.outcomes[target.session] == .confirmed
            for id in target.entries {
                guard let member = member(id), member.control?.session.id == target.session
                else { continue }  // replaced meanwhile: this result is not about it
                member.note = confirmed ? nil : MulticamCopy.couldntRec
                if !confirmed { failed.append(member) }
            }
        }
        // A camera shown but not sent (no live view, closed link) did not start either; one
        // lent to Live View is simply elsewhere.
        let excluded = plan.exclusions.filter { $0.reason != .busy }.compactMap { member($0.entry) }
        for member in excluded { member.note = MulticamCopy.couldntRec }
        guard plan.direction == .start else { return }
        let total = plan.targets.count + plan.satisfied.count + excluded.count
        let notRolling = failed + excluded
        if let first = notRolling.first,
            let sentence = MulticamCopy.mixedStart(
                rolling: total - notRolling.count, total: total, firstFailed: first.displayName)
        {
            toast = sentence
        }
    }

    // MARK: Camera values (per-member write queue with readback)

    func descriptor(_ key: SettingKey, of member: MulticamMember) -> SettingDescriptor? {
        member.control?.session.refresh().capabilities[key]
    }

    /// Sends a value to this member only; its pump writes it at the next safe point and the
    /// camera's readback decides what the tile shows. A value that does not land is noted.
    func set(_ value: SettingValue, on id: MonitorEntryID, label: String) {
        guard let member = member(id), let session = member.control?.session else { return }
        let receipt = session.request(.set(value))
        guard !receipt.isFinished else {
            member.note = MulticamCopy.notApplied(label)
            return
        }
        Task { [weak member] in
            let outcome = await session.outcome(of: receipt.operation)
            guard let member else { return }
            switch outcome?.stage {
            case .confirmed?, .failed(.superseded)?:
                if member.note == MulticamCopy.notApplied(label) { member.note = nil }
            default:
                member.note = MulticamCopy.notApplied(label)
            }
        }
    }

    // MARK: Live View loan

    /// Lends one member's open link to the single-camera Live View: its stage pump stops (the
    /// Live View pumps the link now), it holds an editor lease and is `busy` for group plans.
    /// Returns the link to hand to the monitor, or `nil` when it cannot be lent.
    func lend(_ id: MonitorEntryID) -> (any MulticamMemberLink)? {
        guard lentMember == nil, let member = member(id), member.isLive, let link = member.link,
            let control = member.control,
            (try? leases.open(id, in: group, at: engineState())) != nil
        else { return nil }
        member.pump?.cancel()
        member.pump = nil
        control.lend()
        lentMember = id
        return link
    }

    /// The Live View stood down without closing the link. `link` is what the monitor holds now:
    /// the lent link (the member resumes on the same session), a replacement a recovery opened
    /// (the member gets a new control session, so earlier plans go stale), or `nil` (failed).
    func reclaim(_ link: (any MulticamMemberLink)?) {
        guard let id = lentMember, let member = member(id) else {
            lentMember = nil
            return
        }
        lentMember = nil
        leases.close(id)
        guard let link else {
            fail(member, MulticamCopy.lostConnection)
            return
        }
        if link === member.link, let control = member.control {
            control.reclaim()
            runPump(member, restartLiveView: true)
        } else {
            member.link = link
            attach(member, link: link)
        }
    }

    // MARK: Engine input

    func engineState() -> MulticamSnapshot {
        MulticamSnapshot(
            cameras: members.compactMap { $0.control?.session.refresh() },
            busy: lentMember.map { [$0] } ?? [])
    }

    private func sessionMap() -> [CameraSessionID: any CameraSession] {
        Dictionary(
            members.compactMap {
                $0.control.map { ($0.session.id, $0.session as any CameraSession) }
            }
        ) { first, _ in first }
    }

    private func admission(_ record: PTPIPSavedCameraRecord, reachable: Bool) -> [AdmissionReason] {
        func request(
            _ entry: MonitorEntryID, _ record: PTPIPSavedCameraRecord, _ device: CameraDeviceID?
        )
            -> ResourceRequest
        {
            // ponytail: only USB interfaces are claimed. The engine-port qualified USB-C, router and
            // hotspot members together; network conflicts are added once a mix is device-tested.
            ResourceRequest(
                entry: entry, device: device,
                claims: record.path?.kind == .usbC ? [.usbInterface(record.host)] : [])
        }
        return ResourceAdmission.reasons(
            admitting: request(
                MonitorEntryID(), record,
                NikonMulticamPolicy.device(serialNumber: record.serialNumber)),
            qualification: NikonMulticamPolicy.qualification(
                path: record.path, reachable: reachable,
                isPhotography: nil,  // saved-path admission; mode is checked again after connect
                device: NikonMulticamPolicy.device(serialNumber: record.serialNumber),
                members: members.compactMap(\.device)),
            alongside: members.map { request($0.id, $0.record, $0.device) }, budget: Self.budget)
    }

    // MARK: Member links and pumps

    private func start(_ member: MulticamMember) {
        member.pump = Task { [weak self, weak member] in
            guard let self, let member else { return }
            do {
                let link = try await connect(member.record)
                guard members.contains(where: { $0 === member }), !Task.isCancelled else {
                    await link.shutdown()
                    return
                }
                // The member is the body serial. A path saved before the serial stamp is checked
                // again here, so one body can never hold two stage links.
                let device = NikonMulticamPolicy.device(serialNumber: link.serialNumber)
                if let device,
                    members.contains(where: { $0 !== member && $0.device == device })
                {
                    await link.shutdown()
                    toast = MulticamCopy.alreadyMember
                    remove(member.id)
                    return
                }
                member.device = device ?? member.device
                member.link = link
                attach(member, link: link)
            } catch {
                guard members.contains(where: { $0 === member }) else { return }
                member.status = .failed(MulticamCopy.couldntConnect)
            }
        }
    }

    /// A fresh control session over `link` (a new session ID: earlier plans go stale).
    private func attach(_ member: MulticamMember, link: any MulticamMemberLink) {
        member.control?.session.close(.replaced)
        let control = NikonMemberControl(
            serialNumber: link.serialNumber,
            facts: NikonControlFacts(whiteBalancePresets: whiteBalancePresets),
            recordObservationTimeout: recordObservationTimeout, isCameraRefusal: isCameraRefusal)
        member.control = control
        let entry = MonitorEntryDescriptor(
            id: member.id, name: member.displayName, device: member.device,
            cameraSession: control.session.id, telemetry: .cameraSession, controlAuthority: .owner)
        if group[member.id] == nil {
            let index = group.entries.filter { (self.member($0.id)?.slot ?? 0) < member.slot }.count
            try? group.add(entry, at: index)
        } else {
            try? group.update(entry)
        }
        if member.slot == focusedSlot { try? group.setStage(member.id) }
        runPump(member, restartLiveView: false)
    }

    private func runPump(_ member: MulticamMember, restartLiveView: Bool) {
        member.pump?.cancel()
        member.pump = Task { [weak self, weak member] in
            guard let self, let member else { return }
            await pump(member, restartLiveView: restartLiveView)
        }
    }

    /// Movie values the stage shows per member, battery first (the tile's health readout).
    private static let polledProperties: [PTPPropertyCode] = [
        .batteryLevel, .liveViewSelector, .isoControlSensitivity, .movieISOSensitivity,
        .movieISOAutoControl, .movieShutterMode, .movieShutterAngle, .movieShutterSpeed,
        .movieWhiteBalance, .movieWBColorTemp, .movieFocusMode, .movieRecordScreenSize,
        .movieFileType, .exposureProgramMode,
    ]

    private func pump(_ member: MulticamMember, restartLiveView: Bool) async {
        guard let link = member.link, let control = member.control else { return }
        do {
            if restartLiveView { await link.stopLiveView() }
            await link.configureMemberLiveView()
            try await link.startLiveView()
        } catch {
            if !Task.isCancelled { fail(member, MulticamCopy.couldntConnect) }
            return
        }
        member.status = .live
        member.note = nil
        var nextPoll = ContinuousClock.now
        var misses = 0
        while !Task.isCancelled, member.control === control, !control.isLent {
            let isProgram = member.slot == focusedSlot
            // Safe point between frames: this member's queued writes and record, on its link
            // only. Each outcome lands on the member's receipts (`set` shows the ones that fail).
            await control.service(link)
            member.properties = control.nikonControlFacts.reported
            do {
                let frame = try await link.liveViewFrame(deadline: frameDeadline)
                misses = 0
                // ponytail: UIImage decodes lazily at draw on the main thread; move decode off-main
                // if four 24 fps tiles show up in a profile.
                member.frame = UIImage(data: frame.jpeg)
                member.timecode = frame.timecode
                member.recording = frame.isRecording
                control.update {
                    $0.liveViewReady = true
                    $0.recording = frame.isRecording
                }
                if ContinuousClock.now >= nextPoll {
                    await poll(member, control: control, link: link, recording: frame.isRecording)
                    nextPoll = .now + .seconds(pollInterval(isProgram, 5))
                }
            } catch {
                if Task.isCancelled || control.isLent { return }
                misses += 1
                control.update { $0.liveViewReady = false }
                // Three missed frames at the frame deadline: the link is gone, not slow.
                if misses >= 3 {
                    fail(member, MulticamCopy.lostConnection)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            try? await Task.sleep(for: .seconds(pollInterval(isProgram, 1.0 / 24.0)))
        }
    }

    private func poll(
        _ member: MulticamMember, control: NikonMemberControl, link: any MulticamMemberLink,
        recording: Bool
    ) async {
        // During a take only battery: the header already carries record state and timecode.
        let codes = recording ? [PTPPropertyCode.batteryLevel] : Self.polledProperties
        var reads: [(PTPPropertyCode, Data)] = []
        for code in codes {
            // Telemetry only: a value that does not read stays unknown, never invented.
            if let data = try? await link.readCameraProperty(code) { reads.append((code, data)) }
        }
        control.update { facts in
            facts.reported = reads.reduce(facts.reported) {
                $0.applying(property: $1.0, data: $1.1)
            }
            facts.whiteBalancePresets = PTPCameraPropertyDecoders.whiteBalanceOptions(
                advertised: whiteBalancePresets, codec: facts.reported.fileType)
        }
        member.properties = control.nikonControlFacts.reported
        if !recording, let storage = try? await link.readStorageInfo() { member.storage = storage }
    }

    /// The tile keeps its camera with a Retry; the engine stops addressing it.
    private func fail(_ member: MulticamMember, _ reason: String) {
        member.status = .failed(reason)
        member.recording = nil
        member.control?.update { $0.liveViewReady = false }
        member.control?.session.close(.linkLost)
        group.remove(member.id)
        let link = member.link
        member.link = nil
        Task { await link?.shutdown() }
    }

    private func stop(_ member: MulticamMember) {
        member.pump?.cancel()
        member.pump = nil
        member.control?.reset()
        member.control?.session.close(.requested)
        group.remove(member.id)
        leases.close(member.id)
        let link = member.link
        member.link = nil
        Task {
            await link?.stopLiveView()
            await link?.shutdown()
        }
    }
}
