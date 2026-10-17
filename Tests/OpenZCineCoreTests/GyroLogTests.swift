import Foundation
import Testing

@testable import OpenZCineCore

@Test func gyroTakeIncludesPrerollAndPostrollUsingSensorTimestamps() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 8)
    #expect(session.ingest(samples(from: 8, count: 201)).isEmpty)
    var updates = observe(&session, true, at: 10)
    #expect(session.hasActiveTakes)
    updates += session.ingest(samples(from: 10.01, count: 100))
    updates += observe(&session, false, at: 11)
    updates += session.ingest(samples(from: 11.01, count: 201))
    let summary = try #require(summaries(updates).first)
    #expect(summary.sampleCount == 501)
    #expect(abs(summary.duration - 5) < 0.000_001)
    #expect(abs(summary.measuredRate - 100) < 0.000_001)
    #expect(summary.approximateStartOffset == 2)
    #expect(summary.termination == .normal)
    #expect(!summary.isPartial)
    #expect(!session.hasActiveTakes)
    let rows = dataRows(updates, id: summary.id)
    #expect(rows.first?.hasPrefix("0,") == true)
    #expect(rows.last?.hasPrefix("5000000,") == true)
}

@Test func gyroAdjacentTakesRemainSeparateAndShareOverlappingCoverage() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 9)
    _ = session.ingest(samples(from: 9, count: 101))
    var updates = observe(&session, true, at: 10)
    updates += observe(&session, false, at: 10.1)
    updates += observe(&session, true, at: 10.2)
    updates += observe(&session, false, at: 10.3)
    updates += session.ingest(samples(from: 10.01, count: 231))
    let finished = summaries(updates)
    #expect(finished.count == 2)
    let first = try #require(finished.first)
    let second = try #require(finished.last)
    #expect(first.id != second.id)
    #expect(first.filename != second.filename)
    #expect(first.sampleCount > 300)
    #expect(second.sampleCount > first.sampleCount)
    #expect(dataRows(updates, id: first.id).last?.hasPrefix("4100000,") == true)
    #expect(dataRows(updates, id: second.id).last?.hasPrefix("4100000,") == true)
}

@Test func gyroInitialRecordingObservationIsPartialAndDuplicatesDoNothing() throws {
    var session = GyroTakeSession()
    let updates = observe(&session, true, at: 10)
    let descriptor = try #require(descriptors(updates).first)
    #expect(descriptor.isPartial)
    #expect(observe(&session, true, at: 11).isEmpty)
    #expect(descriptors(updates).count == 1)
    let summary = try #require(summaries(session.finish(reason: .interrupted)).first)
    #expect(summary.isPartial)
}

@Test func gyroDelayedBatchBeforeObservedStartStillFitsTheFileOrigin() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 9)
    var updates = observe(&session, true, at: 10)
    updates += session.ingest(samples(from: 9.9, count: 21))
    updates += session.finish(reason: .normal)
    let summary = try #require(summaries(updates).first)
    #expect(summary.sampleCount == 21)
    #expect(summary.rejectedSampleCount == 0)
    #expect(abs(summary.approximateStartOffset - 0.1) < 0.000_001)
    #expect(dataRows(updates, id: summary.id).first?.hasPrefix("1900000,") == true)
}

@Test(arguments: [9.9, 10.1])
func gyroOffsetMatchesTheFirstRetainedSampleAfterImportAndRecovery(firstTimestamp: Double) throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 9)
    var updates = observe(&session, true, at: 10)
    updates += session.ingest(samples(from: firstTimestamp, count: 21))
    updates += session.finish(reason: .interrupted)
    let summary = try #require(summaries(updates).first)
    #expect(summary.descriptor.approximateStartOffset == 2)
    #expect(abs(summary.approximateStartOffset - (10 - firstTimestamp)) < 0.000_001)
    var recovery = GyroGCSVRecovery()
    for update in updates {
        if case .appended(_, let bytes) = update { try recovery.accept(bytes) }
    }
    let recovered = try recovery.finish(descriptor: summary.descriptor)
    #expect(abs(recovered.approximateStartOffset - summary.approximateStartOffset) < 0.000_001)
    let encoded = try JSONEncoder().encode(summary)
    #expect(try JSONDecoder().decode(GyroLogSummary.self, from: encoded) == summary)
}

@Test func gyroRejectsInvalidAndDuplicateSamplesWithoutPoisoningTheClock() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 10)
    _ = observe(&session, true, at: 10)
    _ = session.ingest([
        sample(10), sample(10), sample(9), sample(.nan),
        GyroSample(timestamp: 10.01, x: .infinity, y: 0, z: 0), sample(10.02),
    ])
    #expect(session.latestSampleTimestamp == 10.02)
    let summary = try #require(summaries(session.finish(reason: .normal)).first)
    #expect(summary.sampleCount == 2)
    #expect(summary.rejectedSampleCount == 4)
    #expect(summary.isPartial)
    #expect(abs(summary.measuredRate - 50) < 0.000_001)
}

@Test func gyroQuantizedTimestampsNeverProduceDuplicateRows() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 10)
    var updates = observe(&session, true, at: 10)
    updates += session.ingest([sample(10), sample(10.000_000_1), sample(10.01)])
    updates += session.finish(reason: .normal)
    let summary = try #require(summaries(updates).first)
    #expect(summary.sampleCount == 2)
    #expect(summary.rejectedSampleCount == 1)
    #expect(dataRows(updates, id: summary.id).count == 2)
}

@Test func gyroGapHealthAndStallWatchdogReportLostCoverage() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 10)
    _ = observe(&session, true, at: 10)
    _ = session.ingest([sample(10), sample(10.06)])
    #expect(session.hasGapWarning)
    #expect(session.poll(at: 10.5).isEmpty)
    let summary = try #require(summaries(session.poll(at: 10.57)).first)
    #expect(summary.termination == .sensorStalled)
    #expect(summary.hasGapWarning)
    #expect(summary.isPartial)
    #expect(session.isFinished)
    #expect(session.ingest([sample(11)]).isEmpty)
}

@Test func gyroWatchdogAlsoCatchesSensorsThatNeverStarted() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 10)
    _ = observe(&session, true, at: 10)
    #expect(session.poll(at: 10.49).isEmpty)
    let summary = try #require(summaries(session.poll(at: 10.5)).first)
    #expect(summary.sampleCount == 0)
    #expect(summary.termination == .sensorStalled)
}

@Test func gyroIdleWatchdogStartsAtFirstValidPollWithoutOpeningAFile() {
    var session = GyroTakeSession()
    #expect(session.termination == nil)
    #expect(session.poll(at: .nan).isEmpty)
    #expect(session.poll(at: -1).isEmpty)
    #expect(session.poll(at: 100).isEmpty)
    #expect(!session.isFinished)
    #expect(session.poll(at: 100.49).isEmpty)
    #expect(!session.isFinished)
    #expect(session.poll(at: 100.5).isEmpty)
    #expect(session.isFinished)
    #expect(session.termination == .sensorStalled)
    #expect(!session.hasActiveTakes)
}

@Test func gyroIdleObservationAnchorsTheWatchdogAndDuplicatesDoNotExtendIt() {
    var session = GyroTakeSession()
    #expect(observe(&session, false, at: 10).isEmpty)
    #expect(observe(&session, false, at: 10.4).isEmpty)
    #expect(session.poll(at: 10.5).isEmpty)
    #expect(session.isFinished)
    #expect(session.termination == .sensorStalled)
}

@Test func gyroIdleWatchdogUsesTheLastAcceptedSample() {
    var session = GyroTakeSession()
    _ = session.poll(at: 10)
    _ = session.ingest(samples(from: 10, count: 101))
    #expect(session.poll(at: 11.49).isEmpty)
    #expect(!session.isFinished)
    #expect(session.poll(at: 11.5).isEmpty)
    #expect(session.isFinished)
    #expect(session.termination == .sensorStalled)
    #expect(session.ingest([sample(12)]).isEmpty)
    #expect(session.finish(reason: .disabled).isEmpty)
    #expect(session.termination == .sensorStalled)
}

@Test func gyroExplicitIdleFinishPublishesItsTerminationWithoutFileUpdates() {
    var session = GyroTakeSession()
    #expect(session.finish(reason: .disabled).isEmpty)
    #expect(session.isFinished)
    #expect(session.termination == .disabled)
}

@Test func gyroPollingClosesPostrollWhenNoSampleFallsOnTheBoundary() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 8)
    _ = session.ingest(samples(from: 8, count: 200))
    _ = observe(&session, true, at: 10)
    _ = session.ingest(samples(from: 10, count: 101))
    _ = observe(&session, false, at: 11)
    _ = session.ingest(samples(from: 11.01, count: 199))
    let summary = try #require(summaries(session.poll(at: 13)).first)
    #expect(summary.termination == .normal)
    #expect(!summary.isPartial)
}

@Test(arguments: [false, true])
func gyroShortPrerollAndMissingPostrollAreMarkedPartial(missingPreroll: Bool) throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 8)
    _ = session.ingest(samples(from: missingPreroll ? 9 : 8, count: missingPreroll ? 101 : 201))
    _ = observe(&session, true, at: 10)
    _ = observe(&session, false, at: 11)
    var updates = session.ingest(samples(from: 10.01, count: missingPreroll ? 300 : 289))
    updates += session.poll(at: 13)
    let summary = try #require(summaries(updates).first)
    #expect(summary.termination == .normal)
    #expect(summary.isPartial)
}

@Test func gyroFiftyMillisecondIntervalsDoNotRaiseFloatingPointGapWarnings() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 10)
    _ = observe(&session, true, at: 10)
    _ = session.ingest([sample(10), sample(10.05)])
    #expect(!session.hasGapWarning)
    let summary = try #require(summaries(session.finish(reason: .normal)).first)
    #expect(!summary.hasGapWarning)
}

@Test func gyroOversizedBatchesFinishWithoutPretendingTheyWereSaved() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 10)
    _ = observe(&session, true, at: 10)
    let summary = try #require(
        summaries(session.ingest(samples(from: 10, count: 513))).first)
    #expect(summary.termination == .bufferOverflow)
    #expect(summary.sampleCount == 0)
    #expect(summary.isPartial)
}

@Test func gyroPrerollStaysBoundedEvenWhenDeliveredFasterThanRequested() throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 10)
    for index in 0..<4 {
        _ = session.ingest(samples(from: 10 + Double(index) / 2, count: 500, step: 0.001))
    }
    _ = observe(&session, true, at: 12)
    let summary = try #require(summaries(session.finish(reason: .disabled)).first)
    #expect(summary.sampleCount == GyroTakeSession.maximumBufferedSamples)
}

@Test(arguments: [GyroLogTermination.disconnected, .backgrounded, .disabled, .writeFailure])
func gyroInterruptionsFinalizeEveryOpenTakeOnce(reason: GyroLogTermination) throws {
    var session = GyroTakeSession()
    _ = observe(&session, false, at: 10)
    _ = observe(&session, true, at: 10)
    _ = session.ingest([sample(10)])
    let summary = try #require(summaries(session.finish(reason: reason)).first)
    #expect(summary.termination == reason)
    #expect(summary.isPartial)
    #expect(session.finish(reason: reason).isEmpty)
}

@Test func gyroEncoderDeclaresUnverifiedAxesAndUsesRadiansAndMicroseconds() throws {
    let descriptor = makeDescriptor()
    let header = String(decoding: GyroGCSVEncoder.header(descriptor: descriptor), as: UTF8.self)
    #expect(header.hasPrefix("GYROFLOW IMU LOG\nversion,1.3\n"))
    #expect(header.contains("orientation,XYZ\norientation_status,unverified\n"))
    #expect(header.contains("tscale,0.000001\ngscale,1\nt,gx,gy,gz\n"))
    let row = try GyroGCSVEncoder.row(
        GyroSample(timestamp: 42.01, x: 1.25, y: -2.5, z: 3.75), origin: 42)
    #expect(String(decoding: row, as: UTF8.self) == "10000,1.250000000,-2.500000000,3.750000000\n")
    #expect(throws: GyroGCSVError.invalidSample) {
        try GyroGCSVEncoder.row(sample(.nan), origin: 42)
    }
}

@Test func gyroRecoveryRetainsOnlyCompleteMonotonicRowsAcrossChunkBoundaries() throws {
    let descriptor = makeDescriptor()
    var valid = GyroGCSVEncoder.header(descriptor: descriptor)
    valid += Data("0,1,2,3\n10000,1,2,3\n".utf8)
    var recovery = GyroGCSVRecovery()
    let input = valid + Data("20000,1,2".utf8)
    for byte in input { try recovery.accept(Data([byte])) }
    let summary = try recovery.finish(descriptor: descriptor)
    #expect(recovery.validByteCount == valid.count)
    #expect(summary.sampleCount == 2)
    #expect(summary.measuredRate == 100)
    #expect(summary.isPartial)
    #expect(summary.termination == .recovered)
}

@Test(arguments: ["10000,1,2,3\n", "20000,nan,2,3\n", "20000,1,2\n"])
func gyroRecoveryStopsAtTheFirstInvalidRow(row: String) throws {
    let descriptor = makeDescriptor()
    let valid = GyroGCSVEncoder.header(descriptor: descriptor) + Data("0,1,2,3\n10000,1,2,3\n".utf8)
    var recovery = GyroGCSVRecovery()
    try recovery.accept(valid + Data((row + "30000,1,2,3\n").utf8))
    #expect(recovery.validByteCount == valid.count)
    let summary = try recovery.finish(descriptor: descriptor)
    #expect(summary.sampleCount == 2)
    #expect(summary.rejectedSampleCount == 1)
}

@Test func gyroRecoveryRejectsHeadersWithWrongUnits() throws {
    let descriptor = makeDescriptor()
    let header = String(decoding: GyroGCSVEncoder.header(descriptor: descriptor), as: UTF8.self)
        .replacingOccurrences(of: "gscale,1", with: "gscale,0.001")
    var recovery = GyroGCSVRecovery()
    #expect(throws: GyroGCSVError.invalidHeader) { try recovery.accept(Data(header.utf8)) }
}

@Test(arguments: [Data([255, 10]), Data(repeating: 49, count: 4_097)])
func gyroRecoveryBoundsDamagedRowsAndCountsTheirRejection(row: Data) throws {
    let descriptor = makeDescriptor()
    let valid = GyroGCSVEncoder.header(descriptor: descriptor) + Data("0,1,2,3\n".utf8)
    var recovery = GyroGCSVRecovery()
    try recovery.accept(valid + row)
    let summary = try recovery.finish(descriptor: descriptor)
    #expect(recovery.validByteCount == valid.count)
    #expect(summary.sampleCount == 1)
    #expect(summary.rejectedSampleCount == 1)
}

@Test func gyroMetadataRoundTripsAndSanitizesTheCSVLabel() throws {
    let descriptor = GyroLogDescriptor(
        cameraLabel: "Camera,\nA", startDate: Date(timeIntervalSince1970: 0),
        approximateStartOffset: 2, isPartial: false)
    #expect(descriptor.filename.hasPrefix("OpenZCine-19700101T000000Z-"))
    #expect(descriptor.filename.hasSuffix(".gcsv"))
    #expect(!descriptor.filename.contains("/"))
    let bytes = try JSONEncoder().encode(descriptor)
    #expect(try JSONDecoder().decode(GyroLogDescriptor.self, from: bytes) == descriptor)
    let header = String(decoding: GyroGCSVEncoder.header(descriptor: descriptor), as: UTF8.self)
    #expect(header.contains("camera,Camera  A\n"))
}

private func sample(_ timestamp: Double) -> GyroSample {
    GyroSample(timestamp: timestamp, x: 1, y: 2, z: 3)
}

private func samples(from start: Double, count: Int, step: Double = 0.01) -> [GyroSample] {
    (0..<count).map { sample(start + Double($0) * step) }
}

private func observe(_ session: inout GyroTakeSession, _ recording: Bool, at timestamp: Double)
    -> [GyroLogUpdate]
{
    session.observeRecording(
        recording, at: timestamp, date: Date(timeIntervalSince1970: timestamp),
        cameraLabel: "Camera")
}

private func descriptors(_ updates: [GyroLogUpdate]) -> [GyroLogDescriptor] {
    updates.compactMap { if case .opened(let descriptor) = $0 { descriptor } else { nil } }
}

private func summaries(_ updates: [GyroLogUpdate]) -> [GyroLogSummary] {
    updates.compactMap { if case .finished(let summary) = $0 { summary } else { nil } }
}

private func dataRows(_ updates: [GyroLogUpdate], id: UUID) -> [String] {
    let data = updates.reduce(into: Data()) { data, update in
        if case .appended(let target, let bytes) = update, target == id { data += bytes }
    }
    return String(decoding: data, as: UTF8.self).split(separator: "\n")
        .filter { $0.first?.isNumber == true }.map(String.init)
}

private func makeDescriptor() -> GyroLogDescriptor {
    GyroLogDescriptor(
        cameraLabel: "Camera", startDate: Date(timeIntervalSince1970: 0), approximateStartOffset: 2,
        isPartial: false)
}
