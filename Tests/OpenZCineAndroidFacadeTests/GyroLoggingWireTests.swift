import Foundation
import Testing

@testable import OpenZCineAndroidFacade

@Suite("Android gyro wire")
struct GyroLoggingWireTests {
    @Test func numericBatchesPreserveTheSensorClockAndOwnerIsolation() throws {
        let wire = GyroLoggingWire()
        let owner = wire.create()
        let other = wire.create()
        defer {
            wire.close(owner: owner)
            wire.close(owner: other)
        }
        _ = wire.ingest(owner: owner, bytes: batch(0..<200))
        _ = wire.observe(
            owner: owner, recording: false, timestamp: 2,
            dateSeconds: 123, cameraLabel: "Test camera")
        let opened = try object(
            wire.observe(
                owner: owner, recording: true, timestamp: 2,
                dateSeconds: 123, cameraLabel: "Test camera"))
        let updates = try #require(opened["updates"] as? [[String: Any]])
        let descriptor = try #require(updates.first?["descriptor"] as? [String: Any])
        #expect(descriptor["startDate"] as? Double == 123_000)
        let appended = updates.filter { $0["kind"] as? String == "appended" }
        let data = try appended.map { update in
            let encoded = try #require(update["data"] as? String)
            return try #require(Data(base64Encoded: encoded))
        }.reduce(Data(), +)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("tscale,0.000001"))
        #expect(text.contains("10000,1.000000000,2.000000000,3.000000000"))
        let isolated = try object(wire.poll(owner: other, timestamp: 2.1))
        #expect(isolated["active"] as? Bool == false)
        _ = wire.ingest(owner: owner, bytes: batch(200..<300))
        _ = wire.observe(
            owner: owner, recording: false, timestamp: 3,
            dateSeconds: 124, cameraLabel: "Test camera")
        let final = try object(wire.ingest(owner: owner, bytes: batch(300..<501)))
        let finalUpdates = try #require(final["updates"] as? [[String: Any]])
        let summary = try #require(finalUpdates.last?["summary"] as? [String: Any])
        #expect(summary["sampleCount"] as? Int == 501)
        #expect(summary["duration"] as? Double == 5)
        #expect(summary["termination"] as? String == "normal")
    }

    @Test func invalidBatchAndRetiredOwnerAreRejected() {
        let wire = GyroLoggingWire()
        let owner = wire.create()
        #expect(wire.ingest(owner: owner, bytes: [0]) == nil)
        #expect(wire.ingest(owner: owner, bytes: Array(repeating: 0, count: 513 * 32)) == nil)
        wire.close(owner: owner)
        #expect(wire.poll(owner: owner, timestamp: 1) == nil)
        #expect(wire.finish(owner: owner, reason: "not-a-reason", timestamp: 1) == nil)
    }

    @Test func streamingRecoveryReturnsActualCompleteRows() throws {
        let wire = GyroLoggingWire()
        let owner = wire.create()
        defer { wire.close(owner: owner) }
        _ = wire.observe(
            owner: owner, recording: false, timestamp: 2,
            dateSeconds: 123, cameraLabel: "Test camera")
        _ = wire.ingest(owner: owner, bytes: batch(0..<200))
        let reply = try object(
            wire.observe(
                owner: owner, recording: true, timestamp: 2,
                dateSeconds: 123, cameraLabel: "Test camera"))
        let updates = try #require(reply["updates"] as? [[String: Any]])
        let descriptor = try #require(updates.first?["descriptor"] as? [String: Any])
        let descriptorData = try JSONSerialization.data(withJSONObject: descriptor)
        let descriptorJSON = try #require(String(data: descriptorData, encoding: .utf8))
        let chunks = try updates.filter { $0["kind"] as? String == "appended" }.map {
            let encoded = try #require($0["data"] as? String)
            return try #require(Data(base64Encoded: encoded))
        }
        var data = chunks.reduce(Data(), +)
        let validCount = data.count
        data.append(Data("2000000,broken".utf8))
        let recovery = wire.recoveryCreate()
        #expect(wire.recoveryAccept(owner: recovery, bytes: Array(data)) == Int64(validCount))
        let summary = try object(
            wire.recoveryFinish(owner: recovery, descriptorJSON: descriptorJSON))
        #expect(summary["sampleCount"] as? Int == 200)
        #expect(summary["termination"] as? String == "recovered")
        #expect(summary["isPartial"] as? Bool == true)
        #expect(wire.recoveryAccept(owner: recovery, bytes: []) == nil)
    }

    private func batch(_ indices: Range<Int>) -> [UInt8] {
        indices.flatMap { index in
            [Double(index) / 100, 1, 2, 3].flatMap { value in
                let bits = value.bitPattern
                return (0..<8).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
            }
        }
    }

    private func object(_ text: String?) throws -> [String: Any] {
        let text = try #require(text)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
