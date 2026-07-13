import Foundation
import Testing

@testable import OpenZCineCore

@Test func durationEstimatorEstimatesMinutesFromFreeSpaceAndBitrate() {
    // 6K R3D NE at 25p ≈ high bitrate. 521 GB free should yield a positive, plausible duration.
    let minutes = RecordDurationEstimator.minutesRemaining(
        codec: "R3D NE", resolutionWidth: 6048, resolutionHeight: 3402, frameRate: 25,
        gigabytesFree: 521
    )
    #expect(minutes > 0)
    // Sanity bound: a half-terabyte at any reasonable codec should give at least several minutes.
    #expect(minutes > 5)
}

@Test func durationEstimatorHigherResolutionYieldsFewerMinutes() {
    // 8K should fit fewer minutes than 4K at the same codec/fps/free space.
    let minutes4K = RecordDurationEstimator.minutesRemaining(
        codec: "R3D NE", resolutionWidth: 3840, resolutionHeight: 2160, frameRate: 25,
        gigabytesFree: 521
    )
    let minutes8K = RecordDurationEstimator.minutesRemaining(
        codec: "R3D NE", resolutionWidth: 7680, resolutionHeight: 4320, frameRate: 25,
        gigabytesFree: 521
    )
    #expect(minutes8K < minutes4K)
}

@Test func durationEstimatorUnknownCodecFallsBackGracefully() {
    // An unknown codec shouldn't crash or return 0 minutes — it should use a conservative fallback.
    let minutes = RecordDurationEstimator.minutesRemaining(
        codec: "Mystery Codec", resolutionWidth: 3840, resolutionHeight: 2160, frameRate: 25,
        gigabytesFree: 100
    )
    #expect(minutes > 0)
}

@Test func durationEstimatorHigherFrameRateYieldsFewerMinutes() {
    let minutes24 = RecordDurationEstimator.minutesRemaining(
        codec: "ProRes RAW HQ", resolutionWidth: 3840, resolutionHeight: 2160, frameRate: 24,
        gigabytesFree: 100
    )
    let minutes60 = RecordDurationEstimator.minutesRemaining(
        codec: "ProRes RAW HQ", resolutionWidth: 3840, resolutionHeight: 2160, frameRate: 60,
        gigabytesFree: 100
    )
    #expect(minutes60 < minutes24)
}

@Test func durationEstimatorVariesByCodec() {
    // Same resolution / fps / free space, different codecs → different estimates. Confirms the
    // remaining time is a function of the selected codec (a lighter codec fits more minutes).
    func minutes(_ codec: String) -> Int {
        RecordDurationEstimator.minutesRemaining(
            codec: codec, resolutionWidth: 3840, resolutionHeight: 2160, frameRate: 24,
            gigabytesFree: 521)
    }
    #expect(minutes("H.264") > minutes("ProRes 422 HQ"))
    #expect(minutes("ProRes 422 HQ") > minutes("ProRes RAW HQ"))
}

@Test func durationEstimatorCodecLabelsHitTheTable() {
    // The exact labels `MonitorTextFormat.codecShortLabel` emits for every ZR codec must resolve to
    // a real per-codec bitrate, not the unknown-codec fallback — otherwise the readout silently
    // estimates every codec the same.
    let fallback = RecordDurationEstimator.bitrateMbps(
        codec: "\u{0}unknown", resolutionWidth: 3840, resolutionHeight: 2160, frameRate: 24)
    for raw in [
        "H.264 8-bit MP4", "H.265 10-bit MP4", "N-RAW 12-bit NEV",
        "ProRes 422 HQ 10-bit MOV", "ProRes RAW HQ 12-bit MOV", "R3D NE 10-bit R3D",
    ] {
        let label = MonitorTextFormat.codecShortLabel(raw)
        let rate = RecordDurationEstimator.bitrateMbps(
            codec: label, resolutionWidth: 3840, resolutionHeight: 2160, frameRate: 24)
        #expect(rate != fallback, "codec label \"\(label)\" fell back to the unknown bitrate")
    }
}

@Test func durationEstimatorR3DNE6K25pMatchesNikonPublishedBitrate() {
    // Nikon ZR specs: R3D NE 6048×3402 @ 25p ≈ 1590 Mbps. At 429 GB free the camera LCD shows ~36 min.
    let minutes = RecordDurationEstimator.minutesRemaining(
        codec: "R3D NE", resolutionWidth: 6048, resolutionHeight: 3402, frameRate: 25,
        gigabytesFree: 429
    )
    #expect(minutes >= 34 && minutes <= 38)
}

@Test func durationEstimatorZeroFreeSpaceReturnsZero() {
    let minutes = RecordDurationEstimator.minutesRemaining(
        codec: "R3D NE", resolutionWidth: 6048, resolutionHeight: 3402, frameRate: 25,
        gigabytesFree: 0
    )
    #expect(minutes == 0)
}

@Test func durationEstimatorUnknownResolutionOrFrameRateReturnsZero() {
    // Right after a reconnect, resolution/fps are momentarily 0 (the property snapshot is cleared).
    // bitrate then collapses to 0, so the estimate must NOT divide by zero into an infinite Int
    // (that crashed: "Double value cannot be converted to Int because it is either infinite or NaN").
    #expect(
        RecordDurationEstimator.minutesRemaining(
            codec: "R3D NE", resolutionWidth: 0, resolutionHeight: 0, frameRate: 0,
            gigabytesFree: 440) == 0)
    #expect(
        RecordDurationEstimator.minutesRemaining(
            codec: "R3D NE", resolutionWidth: 6048, resolutionHeight: 3400, frameRate: 0,
            gigabytesFree: 440) == 0)
    #expect(
        RecordDurationEstimator.minutesRemaining(
            codec: "R3D NE", resolutionWidth: 0, resolutionHeight: 3400, frameRate: 25,
            gigabytesFree: 440) == 0)
}
