import Foundation
import Testing

@testable import OpenZCineCore

@Suite("Fixed phone mounts")
struct GyroMountTests {
    @Test func cameraUpMotionMatchesPhysicalPhoneEdges() throws {
        // Raw rotations around camera-up, derived from which phone edge points upward.
        let motions: [(GyroMountPreset, [Double], [Double])] = [
            (.rearDown, [0, 1, 0], [-1, 0, 0]), (.rearLeft, [-1, 0, 0], [0, -1, 0]),
            (.rearRight, [1, 0, 0], [0, 1, 0]), (.rearUp, [0, -1, 0], [1, 0, 0]),
            (.frontDown, [0, 1, 0], [1, 0, 0]), (.frontLeft, [1, 0, 0], [0, -1, 0]),
            (.frontRight, [-1, 0, 0], [0, 1, 0]), (.frontUp, [0, -1, 0], [-1, 0, 0]),
        ]
        for (mount, motion, cameraLeft) in motions {
            #expect(try remap(motion, orientation: mount.orientation) == [1, 0, 0])
            #expect(try remap(cameraLeft, orientation: mount.orientation) == [0, 1, 0])
            let towardOperator = mount.group == "Screen toward you" ? 1.0 : -1.0
            #expect(
                try remap([0, 0, towardOperator], orientation: mount.orientation) == [0, 0, 1])
        }
    }

    @Test(arguments: GyroMountPreset.allCases)
    func mountHeadersPreserveRawRowsAndRecoverTheSelectedAlignment(mount: GyroMountPreset) throws {
        let descriptor = descriptor(mount)
        let header = GyroGCSVEncoder.header(descriptor: descriptor)
        let text = String(decoding: header, as: UTF8.self)
        #expect(text.contains("orientation,\(mount.orientation)\n"))
        #expect(text.contains("mount_preset,\(mount.rawValue)\n"))
        #expect(text.contains(mount == .unconfigured ? "unverified" : "operator_selected"))
        let row = try GyroGCSVEncoder.row(GyroSample(timestamp: 10, x: 1, y: 2, z: 3), origin: 10)
        #expect(String(decoding: row, as: UTF8.self) == "0,1.000000000,2.000000000,3.000000000\n")
        var recovery = GyroGCSVRecovery()
        try recovery.accept(header + row + Data("10000,broken".utf8))
        let summary = try recovery.finish(descriptor: descriptor)
        #expect(summary.descriptor.mount == mount)
        #expect(summary.sampleCount == 1)
        #expect(summary.termination == .recovered)
    }

    @Test func adjacentTakesKeepTheirMountWhenTheNextSelectionChanges() throws {
        var session = GyroTakeSession()
        let date = Date(timeIntervalSince1970: 0)
        _ = session.observeRecording(false, at: 9, date: date, cameraLabel: "Test")
        var updates = session.observeRecording(
            true, at: 10, date: date, cameraLabel: "Test", mountPreset: .rearDown)
        #expect(
            session.observeRecording(
                true, at: 10.1, date: date, cameraLabel: "Test", mountPreset: .frontLeft
            ).isEmpty)
        updates += session.observeRecording(false, at: 11, date: date, cameraLabel: "Test")
        updates += session.observeRecording(
            true, at: 11.1, date: date, cameraLabel: "Test", mountPreset: .frontLeft)
        updates += session.ingest([GyroSample(timestamp: 11.2, x: 1, y: 2, z: 3)])
        updates += session.finish(reason: .interrupted)
        let finished = updates.compactMap { update -> GyroLogSummary? in
            if case .finished(let summary) = update { return summary }
            return nil
        }
        #expect(finished.map { $0.descriptor.mount } == [.rearDown, .frontLeft])
    }

    @Test func legacyDescriptorsAndPartialFilesRemainUnconfigured() throws {
        let encoder = JSONEncoder()
        var json = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(descriptor(.rearDown)))
                as? [String: Any])
        json.removeValue(forKey: "mountPreset")
        let legacy = try JSONDecoder().decode(
            GyroLogDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.mount == .unconfigured)
        #expect(legacy.mountPreset == nil)
        let oldFile = Data(
            "GYROFLOW IMU LOG\nversion,1.3\nid,OpenZCine\norientation,XYZ\n"
                .appending("tscale,0.000001\ngscale,1\nt,gx,gy,gz\n0,1,2,3\n").utf8)
        var recovery = GyroGCSVRecovery()
        try recovery.accept(oldFile)
        #expect(try recovery.finish(descriptor: legacy).sampleCount == 1)
    }

    @Test func recoveryRejectsAnAlignmentMismatchOrUnsupportedPermutation() throws {
        let descriptor = descriptor(.rearDown)
        var recovery = GyroGCSVRecovery()
        try recovery.accept(GyroGCSVEncoder.header(descriptor: descriptor) + Data("0,1,2,3\n".utf8))
        #expect(throws: GyroGCSVError.invalidHeader) {
            try recovery.finish(descriptor: self.descriptor(.frontDown))
        }
        let invalid = String(
            decoding: GyroGCSVEncoder.header(descriptor: descriptor), as: UTF8.self
        )
        .replacingOccurrences(of: "orientation,YxZ", with: "orientation,XXZ")
        var damaged = GyroGCSVRecovery()
        #expect(throws: GyroGCSVError.invalidHeader) { try damaged.accept(Data(invalid.utf8)) }
    }

    private func descriptor(_ mount: GyroMountPreset) -> GyroLogDescriptor {
        GyroLogDescriptor(
            cameraLabel: "Test camera", startDate: Date(timeIntervalSince1970: 0),
            approximateStartOffset: 2, isPartial: false, mountPreset: mount)
    }

    private func remap(_ input: [Double], orientation: String) throws -> [Double] {
        let axes = ["x": input[0], "y": input[1], "z": input[2]]
        return try orientation.map { character in
            let key = String(character)
            let value = try #require(axes[key.lowercased()])
            return key == key.uppercased() ? value : -value
        }
    }
}
