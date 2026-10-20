import AVFoundation
import Foundation
import OpenCineApple
import OpenCineHostedTestSupport
import OpenZCineCore
import XCTest

@testable import Runner

/// SIMULATED native audio through the same shared owner constructed by MediaPlayerView.
@MainActor
final class PlaybackAudioMeterAdoptionTests: XCTestCase {
    func testActualTapMeasuresAudioAndReplacementDiscardsHeldPeaks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SIMULATED-playback-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tone = directory.appendingPathComponent("tone.caf")
        let silence = directory.appendingPathComponent("silence.caf")
        try Self.writeAudio(to: tone, amplitude: 0.5)
        try Self.writeAudio(to: silence, amplitude: 0)

        let runtime = MonitorPlaybackAudioMeterRuntime()
        let player = AVPlayer()
        player.isMuted = true
        var latest: MonitorAudioMeterLevels?
        var sawAbsent = false
        runtime.startPolling { levels in
            latest = levels
            if levels == nil { sawAbsent = true }
        }
        defer {
            runtime.detach(from: player.currentItem)
            runtime.close()
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        try await Self.waitUntil { sawAbsent }
        let first = AVPlayerItem(url: tone)
        runtime.attach(to: first)
        try await Self.waitUntil { first.audioMix != nil }
        player.replaceCurrentItem(with: first)
        player.play()
        try await Self.waitUntil { (latest?.left.levelDB ?? -60) > -20 }
        XCTAssertGreaterThan(try XCTUnwrap(latest).right.levelDB, -20)

        player.pause()
        runtime.detach(from: first)
        XCTAssertNil(first.audioMix)
        try await Self.waitUntil { latest == nil }
        let second = AVPlayerItem(url: silence)
        runtime.attach(to: second)
        try await Self.waitUntil { second.audioMix != nil }
        player.replaceCurrentItem(with: second)
        player.play()
        try await Self.waitUntil { latest != nil }
        XCTAssertEqual(try XCTUnwrap(latest).left, .silent)
        XCTAssertEqual(try XCTUnwrap(latest).right, .silent)
        XCTAssertNil(first.audioMix)
    }

    func testCancelledTrackAttachAndNoAudioRemainAbsent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SIMULATED-playback-audio-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tone = directory.appendingPathComponent("tone.caf")
        try Self.writeAudio(to: tone, amplitude: 0.5)
        let item = AVPlayerItem(url: tone)
        let runtime = MonitorPlaybackAudioMeterRuntime()
        defer { runtime.close() }
        runtime.attach(to: item)
        runtime.detach(from: item)
        _ = try await item.asset.loadTracks(withMediaType: .audio)
        XCTAssertNil(item.audioMix)
        let noAudio = AVPlayerItem(asset: AVMutableComposition())
        runtime.attach(to: noAudio)
        var absentSamples = 0
        runtime.startPolling { levels in
            XCTAssertNil(levels)
            absentSamples += 1
        }
        try await Self.waitUntil { absentSamples >= 3 }
        XCTAssertNil(item.audioMix)
        XCTAssertNil(noAudio.audioMix)
        runtime.detach(from: noAudio)
    }

    private static func writeAudio(to url: URL, amplitude: Float) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = buffer.frameCapacity
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            let value = amplitude * sin(Float(frame) * 2 * .pi * 440 / 48_000)
            channels[0][frame] = value
            channels[1][frame] = value
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Readiness only: the shared hang guard (`HostedCondition`) instead of an 8 s window,
    /// which a loaded hosted runner overran.
    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        if !(await HostedCondition.wait(until: condition)) {
            XCTFail("SIMULATED native audio deadline expired")
            throw NSError(domain: "PlaybackAudioMeterAdoptionTests", code: 1)
        }
    }
}
