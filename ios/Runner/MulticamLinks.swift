import Foundation
import OpenZCineCore
import UIKit

/// A real member link: the same PTP session type the single-camera monitor runs.
extension NativeCameraSession: MulticamMemberLink {
    var serialNumber: String { identity.serialNumber }
    func configureMemberLiveView() async { await configureLiveView() }
}

/// A scripted Z body for the demo stage (`ZC_DEMO_MULTICAM`) and the coordinator tests. It answers
/// like a body on its own link: writes land and read back, record flips the frame header.
final class DemoMulticamLink: MulticamMemberLink, @unchecked Sendable {
    struct Refusal: Error {}

    let serialNumber: String
    private let lock = NSLock()
    private var properties: [PTPPropertyCode: Data]
    private var recording = false
    private var log: [String] = []
    private var frames = 0
    private let jpeg: Data
    /// Scripting for tests: the body refuses record, or stops answering frames.
    var refusesRecord = false
    var dropsFrames = false
    var frameInterval: Duration = .milliseconds(40)

    init(serialNumber: String, iso: UInt32 = 800, battery: UInt8 = 80, recording: Bool = false) {
        self.serialNumber = serialNumber
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
        ]
    }

    /// Every command this body received, in order.
    var received: [String] { lock.withLock { log } }
    var isRecording: Bool { lock.withLock { recording } }
    var frameCount: Int { lock.withLock { frames } }

    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {
        lock.withLock {
            log.append("write \(write.property)")
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
    func shutdown() async { lock.withLock { log.append("shutdown") } }

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
