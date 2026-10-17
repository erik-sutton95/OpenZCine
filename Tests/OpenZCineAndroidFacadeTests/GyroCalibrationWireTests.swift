import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct GyroCalibrationWireTests {
    @Test(arguments: [false, true])
    func pairedObservationsProduceOneValidatedOpaqueCalibration(invalidReadingBetweenPoses: Bool)
        throws
    {
        let wire = GyroCalibrationWire()
        let owner = wire.create()
        defer { wire.close(owner: owner) }
        var calibration: [String: Any]?
        let cameraDown = [
            GyroVector3(x: -1, y: 0, z: 0),
            GyroVector3(x: -sqrt(3.0) / 2, y: 0, z: 0.5),
            GyroVector3(x: -sqrt(3.0 / 8), y: sqrt(3.0 / 8), z: 0.5),
        ]
        for (step, gravity) in cameraDown.enumerated() {
            let base = 1 + Double(step) * 3
            if step == 1, invalidReadingBetweenPoses {
                let rejected = try object(
                    wire.add(
                        owner: owner,
                        observationJSON:
                            #"{"phoneDown":{"x":0,"y":-1,"z":0},"phoneTimestamp":3,"rollDegrees":90,"pitchDegrees":90,"cameraTimestamp":3}"#
                    ))
                #expect(rejected["poseCount"] as? Int == 1)
                #expect(rejected["error"] != nil)
                let unavailable = try object(wire.capture(owner: owner, timestamp: 3.01))
                #expect(unavailable["poseCount"] as? Int == 1)
                #expect(unavailable["error"] != nil)
            }
            for index in 0...24 {
                let observation: [String: Any] = [
                    "phoneDown": ["x": -gravity.y, "y": gravity.x, "z": gravity.z],
                    "phoneTimestamp": base + Double(index) * 0.05,
                    "rollDegrees": atan2(gravity.y, -gravity.x) * 180 / .pi,
                    "pitchDegrees": atan2(gravity.z, -gravity.x) * 180 / .pi,
                    "cameraTimestamp": base + Double(index / 2) * 0.1,
                ]
                let data = try JSONSerialization.data(withJSONObject: observation)
                _ = wire.add(owner: owner, observationJSON: String(decoding: data, as: UTF8.self))
            }
            let reply = try object(wire.capture(owner: owner, timestamp: base + 1.22))
            #expect(reply["error"] == nil)
            #expect(reply["poseCount"] as? Int == step + 1)
            calibration = reply["calibration"] as? [String: Any]
            #expect((calibration != nil) == (step == 2))
        }
        let value = try #require(calibration)
        let bytes = try JSONSerialization.data(withJSONObject: value)
        let json = String(decoding: bytes, as: UTF8.self)
        #expect(wire.validate(json))
        #expect(!wire.validate("{}"))
        let decoded = try JSONDecoder().decode(GyroMountCalibration.self, from: bytes)
        let rotated = decoded.applying(to: GyroSample(timestamp: 7, x: 1, y: 2, z: 3))
        #expect(abs(rotated.x - 2) < 1e-9)
        #expect(abs(rotated.y + 1) < 1e-9)
        #expect(abs(rotated.z - 3) < 1e-9)
        #expect(rotated.timestamp == 7)

        let logs = GyroLoggingWire()
        let logOwner = logs.create()
        defer { logs.close(owner: logOwner) }
        let opened = try object(
            logs.observe(
                owner: logOwner, recording: true, timestamp: 10, dateSeconds: 100,
                cameraLabel: "Camera", mountPreset: "rearDown", calibrationJSON: json))
        let updates = try #require(opened["updates"] as? [[String: Any]])
        let descriptor = try #require(updates.first?["descriptor"] as? [String: Any])
        #expect(descriptor["mountCalibration"] != nil)
        let encodedHeader = try #require(updates.last?["data"] as? String)
        let header = try #require(Data(base64Encoded: encodedHeader))
        let text = String(decoding: header, as: UTF8.self)
        #expect(text.contains("orientation,XYZ\n"))
        #expect(text.contains("orientation_status,calibrated\n"))
    }

    @Test func retiredAndMalformedCalibrationOwnersCannotBeUsed() throws {
        let wire = GyroCalibrationWire()
        let owner = wire.create()
        let rejected = try object(wire.add(owner: owner, observationJSON: "{}"))
        #expect(rejected["error"] as? String != nil)
        #expect(rejected["poseCount"] as? Int == 0)
        wire.close(owner: owner)
        #expect(wire.capture(owner: owner, timestamp: 1) == nil)
        #expect(wire.add(owner: owner, observationJSON: "{}") == nil)
    }

    private func object(_ json: String?) throws -> [String: Any] {
        let json = try #require(json)
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
