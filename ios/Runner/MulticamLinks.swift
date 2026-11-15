import Foundation
import OpenZCineCore
import UIKit

/// One member's PTP session as the shared Multiview's Nikon link runs it: the app's real
/// `NativeCameraSession`, or a scripted body in the demo stage and the tests. One box per opened
/// session, so the link can tell the session it lent to Live View from a replacement.
final class ZCineMemberTransport: NikonMultiviewTransport, @unchecked Sendable {
    // SAFETY: `@unchecked Sendable`: immutable; `base` is itself Sendable.
    let base: any NikonMultiviewTransport

    init(_ base: any NikonMultiviewTransport) { self.base = base }

    /// The real session behind the box, for the single-camera Live View the member is lent to.
    var session: NativeCameraSession? { base as? NativeCameraSession }

    /// The camera model GetDeviceInfo reported (the tile's subtitle, as Pocket shows it).
    var model: String {
        if let session { return session.identity.model }
        return (base as? DemoMulticamLink)?.model ?? ""
    }

    var serialNumber: String { base.serialNumber }
    var commandOwner: NikonCommandOwner? { base.commandOwner }
    func configureMemberLiveView() async { await base.configureMemberLiveView() }
    func startLiveView() async throws { try await base.startLiveView() }
    func stopLiveView() async { await base.stopLiveView() }
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame {
        try await base.liveViewFrame(deadline: deadline)
    }
    func readStorageInfo() async throws -> PTPStorageInfo? { try await base.readStorageInfo() }
    func shutdown() async { await base.shutdown() }
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data {
        try await base.readCameraProperty(property)
    }
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {
        try await base.writeCameraProperty(write)
    }
    func writeCameraProperty(_ write: PTPCameraPropertyWrite, admission: NikonCommandAdmission)
        async throws
    {
        try await base.writeCameraProperty(write, admission: admission)
    }
    func startRecording() async throws { try await base.startRecording() }
    func startRecording(admission: NikonCommandAdmission) async throws {
        try await base.startRecording(admission: admission)
    }
    func stopRecording() async throws { try await base.stopRecording() }
    func stopRecording(admission: NikonCommandAdmission) async throws {
        try await base.stopRecording(admission: admission)
    }
}

/// A scripted Z body for the demo stage (`ZC_DEMO_MULTICAM`) and the host tests. It answers like a
/// body on its own link: writes land and read back, record flips the frame header.
final class DemoMulticamLink: NikonMultiviewTransport, @unchecked Sendable {
    struct Refusal: Error {}

    let serialNumber: String
    let model: String
    let commandOwner: NikonCommandOwner? = NikonCommandOwner()
    private let lock = NSLock()
    private var properties: [PTPPropertyCode: Data]
    private var recording = false
    private var log: [String] = []
    private var frames = 0
    private let jpeg: Data
    /// Scripting for tests: the body refuses record, or stops answering frames.
    var refusesRecord = false
    var refusesWrites = false
    var dropsFrames = false
    var frameInterval: Duration = .milliseconds(40)

    init(
        serialNumber: String, model: String = "ZR", iso: UInt32 = 800, battery: UInt8 = 80,
        recording: Bool = false, nLog: Bool = false
    ) {
        self.serialNumber = serialNumber
        self.model = model
        self.recording = recording
        jpeg = UIImage(named: "MockFeed")?.jpegData(compressionQuality: 0.6) ?? Data()
        let colorTemp = PTPCameraPropertyDecoders.wbModeCode(for: "Color temp") ?? 0
        properties = [
            .batteryLevel: Data([battery]),
            .liveViewSelector: Data([1]),
            .exposureProgramMode: Data(ByteCoding.uint16LE(1)),
            .isoControlSensitivity: Data(ByteCoding.uint32LE(iso)),
            .movieISOAutoControl: Data([0]),
            .movieShutterMode: Data([2]),
            .movieShutterAngle: Data(ByteCoding.int32LE(18_000)),
            .movieWhiteBalance: Data(ByteCoding.uint16LE(colorTemp)),
            .movieWBColorTemp: Data(ByteCoding.uint16LE(5600)),
            .movieFocusMode: Data([1]),
            // H.265 10-bit with its tone property: N-Log (1) or SDR (0).
            .movieFileType: Data(ByteCoding.uint32LE(0x0001_0A00)),
            .movieH265ToneMode: Data([nLog ? 1 : 0]),
        ]
    }

    /// Every command this body received, in order.
    var received: [String] { lock.withLock { log } }
    var isRecording: Bool { lock.withLock { recording } }
    var frameCount: Int { lock.withLock { frames } }

    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {
        try lock.withLock {
            log.append("write \(write.property)")
            if refusesWrites { throw Refusal() }
            properties[write.property] = write.data
            // The movie ISO write moves the effective ISO the poll reads.
            if write.property == .movieExposureIndex {
                properties[.isoControlSensitivity] = write.data
            }
        }
    }

    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data {
        guard let data = lock.withLock({ properties[property] }) else { throw Refusal() }
        return data
    }

    func startRecording() async throws { try record(true) }
    func stopRecording() async throws { try record(false) }

    private func record(_ start: Bool) throws {
        try lock.withLock {
            log.append(start ? "start" : "stop")
            if refusesRecord { throw Refusal() }
            recording = start
        }
    }

    func configureMemberLiveView() async {}
    func startLiveView() async throws { lock.withLock { log.append("startLiveView") } }
    func stopLiveView() async { lock.withLock { log.append("stopLiveView") } }
    func shutdown() async {
        commandOwner?.retire()
        lock.withLock { log.append("shutdown") }
    }

    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame {
        try await Task.sleep(for: frameInterval)
        if dropsFrames { throw Refusal() }
        return lock.withLock {
            frames += 1
            return PTPLiveViewFrame(
                jpeg: jpeg,
                timecode: Timecode(on: true, hour: 14, minute: 32, second: 8, frame: 12),
                isRecording: recording)
        }
    }

    func readStorageInfo() async throws -> PTPStorageInfo? {
        var dataset = [UInt8](repeating: 0, count: 22)
        dataset.replaceSubrange(6..<14, with: ByteCoding.uint64LE(512_000_000_000))
        dataset.replaceSubrange(14..<22, with: ByteCoding.uint64LE(96_000_000_000))
        return PTPStorageInfo(dataset)
    }
}
