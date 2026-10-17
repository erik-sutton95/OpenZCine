import Foundation
import Testing

@testable import OpenZCineCore

@Suite("Calibrated gyro export")
struct GyroCalibrationExportTests {
    @Test func frozenCalibrationRotatesOverlappingTakesExactlyOnceAndRecovers() throws {
        let calibration = try calibration()
        let identity = try self.calibration(identity: true)
        var session = GyroTakeSession()
        let date = Date(timeIntervalSince1970: 0)
        _ = session.observeRecording(false, at: 9, date: date, cameraLabel: "Test")
        _ = session.ingest([GyroSample(timestamp: 9.9, x: 1, y: 2, z: 3)])
        var updates = session.observeRecording(
            true, at: 10, date: date, cameraLabel: "Test",
            mountPreset: .rearDown, mountCalibration: calibration)
        #expect(
            session.observeRecording(
                true, at: 10.1, date: date, cameraLabel: "Test",
                mountCalibration: identity
            ).isEmpty)
        updates += session.observeRecording(false, at: 10.5, date: date, cameraLabel: "Test")
        updates += session.observeRecording(
            true, at: 10.6, date: date, cameraLabel: "Test",
            mountPreset: .frontDown, mountCalibration: identity)
        updates += session.ingest([GyroSample(timestamp: 10.7, x: 1, y: 2, z: 3)])
        updates += session.finish(reason: .interrupted)
        let descriptors = updates.compactMap { update -> GyroLogDescriptor? in
            if case .opened(let descriptor) = update { return descriptor }
            return nil
        }
        #expect(descriptors.count == 2)
        #expect(descriptors.map(\.mountCalibration) == [calibration, identity])
        for (index, descriptor) in descriptors.enumerated() {
            let bytes = updates.reduce(into: Data()) { bytes, update in
                if case .appended(let id, let data) = update, id == descriptor.id {
                    bytes.append(data)
                }
            }
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(text.contains("orientation,XYZ\norientation_status,calibrated\n"))
            #expect(descriptor.alignmentDetail == "Calibrated mount")
            let rows = text.split(separator: "\n").compactMap { line -> [Double]? in
                let parts = line.split(separator: ",")
                guard parts.count == 4, Double(parts[0]) != nil else { return nil }
                return parts.compactMap { Double($0) }
            }
            #expect(rows.count == 2)
            for row in rows {
                #expect(row[1] == (index == 0 ? -2 : 1))
                #expect(row[2] == (index == 0 ? 1 : 2))
                #expect(row[3] == 3)
            }
            let saved = try JSONEncoder().encode(descriptor)
            let loaded = try JSONDecoder().decode(GyroLogDescriptor.self, from: saved)
            #expect(loaded == descriptor)
            var recovery = GyroGCSVRecovery()
            try recovery.accept(bytes + Data("broken".utf8))
            let summary = try recovery.finish(descriptor: loaded)
            #expect(summary.sampleCount == 2)
            #expect(summary.descriptor.mountCalibration == descriptor.mountCalibration)
            #expect(recovery.validByteCount == bytes.count)
        }
    }

    @Test func manualAndLegacyLogsPreserveTheirRawAxesAndMetadata() throws {
        let manual = descriptor(mount: .rearDown)
        let header = String(decoding: GyroGCSVEncoder.header(descriptor: manual), as: UTF8.self)
        #expect(manual.orientation == "YxZ")
        #expect(header.contains("orientation,YxZ\norientation_status,operator_selected\n"))
        #expect(manual.alignmentDetail == manual.mount.detail)
        #expect(
            String(
                decoding: try GyroGCSVEncoder.row(
                    GyroSample(timestamp: 1, x: 1, y: 2, z: 3), origin: 1), as: UTF8.self)
                == "0,1.000000000,2.000000000,3.000000000\n")
        var legacyJSON = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(manual)) as? [String: Any])
        legacyJSON.removeValue(forKey: "mountPreset")
        legacyJSON.removeValue(forKey: "mountCalibration")
        let legacy = try JSONDecoder().decode(
            GyroLogDescriptor.self,
            from: JSONSerialization.data(withJSONObject: legacyJSON))
        #expect(legacy.mountCalibration == nil && legacy.orientation == "XYZ")
        #expect(
            String(decoding: GyroGCSVEncoder.header(descriptor: legacy), as: UTF8.self)
                .contains("orientation,XYZ\norientation_status,unverified\n"))
    }

    @Test func recoveryChecksTheEffectiveCalibrationOrientation() throws {
        let manual = descriptor(mount: .rearDown)
        let calibrated = descriptor(mount: .rearDown, calibration: try calibration())
        var recovery = GyroGCSVRecovery()
        try recovery.accept(GyroGCSVEncoder.header(descriptor: manual) + Data("0,1,2,3\n".utf8))
        #expect(throws: GyroGCSVError.invalidHeader) { try recovery.finish(descriptor: calibrated) }
        #expect(try recovery.finish(descriptor: manual).sampleCount == 1)
    }

    private func descriptor(mount: GyroMountPreset, calibration: GyroMountCalibration? = nil)
        -> GyroLogDescriptor
    {
        GyroLogDescriptor(
            cameraLabel: "Test camera", startDate: Date(timeIntervalSince1970: 0),
            approximateStartOffset: 2, isPartial: false, mountPreset: mount,
            mountCalibration: calibration)
    }

    private func calibration(identity: Bool = false) throws -> GyroMountCalibration {
        let vectors = [
            GyroVector3(x: -1, y: 0, z: 0),
            GyroVector3(x: -sqrt(0.75), y: 0, z: 0.5),
            GyroVector3(x: -0.75, y: sqrt(0.1875), z: 0.5),
        ]
        let poses = vectors.map { camera in
            GyroCalibrationPose(
                phoneDown: identity
                    ? camera
                    : GyroVector3(x: camera.y, y: -camera.x, z: camera.z), cameraDown: camera)
        }
        return try GyroMountCalibration.solve(
            first: poses[0], second: poses[1], validation: poses[2])
    }
}
