import Testing

@testable import OpenZCineCore

@Suite("Audio meter dBFS conversion")
struct AudioMeterDecibelTests {
    @Test func fullScaleReadsZeroDB() {
        #expect(AudioMeterBallistics.decibels(fromLinear: 1) == 0)
    }

    @Test func halfAmplitudeReadsMinusSixDB() {
        #expect(abs(AudioMeterBallistics.decibels(fromLinear: 0.5) - (-6.0206)) < 0.01)
    }

    @Test func silenceAndOverdriveClampToTheScale() {
        #expect(AudioMeterBallistics.decibels(fromLinear: 0) == AudioMeterBallistics.floorDB)
        #expect(AudioMeterBallistics.decibels(fromLinear: -1) == AudioMeterBallistics.floorDB)
        #expect(AudioMeterBallistics.decibels(fromLinear: 0.000_01) == AudioMeterBallistics.floorDB)
        #expect(AudioMeterBallistics.decibels(fromLinear: 2) == 0)
    }
}

@Suite("Audio meter ballistics")
struct AudioMeterBallisticsTests {
    @Test func attackIsInstant() {
        let next = AudioMeterBallistics.step(.silent, peakLinear: 1, dt: 0.04)
        #expect(next.levelDB == 0)
        #expect(next.peakDB == 0)
        #expect(next.peakAge == 0)
    }

    @Test func levelDecaysAtTheDocumentedRate() {
        let loud = AudioMeterBallistics.step(.silent, peakLinear: 1, dt: 0.04)
        let dt = 0.5
        let next = AudioMeterBallistics.step(loud, peakLinear: 0, dt: dt)
        #expect(abs(next.levelDB - (-AudioMeterBallistics.levelDecayPerSecond * dt)) < 1e-9)
    }

    @Test func levelNeverFallsBelowTheFloor() {
        var channel = AudioMeterBallistics.step(.silent, peakLinear: 1, dt: 0.04)
        for _ in 0..<100 {
            channel = AudioMeterBallistics.step(channel, peakLinear: 0, dt: 0.5)
        }
        #expect(channel.levelDB == AudioMeterBallistics.floorDB)
        #expect(channel.peakDB == AudioMeterBallistics.floorDB)
    }

    @Test func peakHoldsThroughTheHoldWindowThenDecays() {
        var channel = AudioMeterBallistics.step(.silent, peakLinear: 1, dt: 0.04)
        // Within the hold window: the marker stays pinned while the bar falls.
        channel = AudioMeterBallistics.step(channel, peakLinear: 0, dt: 1.0)
        #expect(channel.peakDB == 0)
        #expect(channel.levelDB < 0)
        // Past the hold window: the marker starts falling too.
        channel = AudioMeterBallistics.step(channel, peakLinear: 0, dt: 1.0)
        #expect(channel.peakAge > AudioMeterBallistics.peakHoldSeconds)
        #expect(channel.peakDB < 0)
    }

    @Test func newMaximaRestartTheHold() {
        var channel = AudioMeterBallistics.step(.silent, peakLinear: 0.5, dt: 0.04)
        channel = AudioMeterBallistics.step(channel, peakLinear: 0, dt: 1.0)
        #expect(channel.peakAge == 1.0)
        channel = AudioMeterBallistics.step(channel, peakLinear: 0.9, dt: 0.04)
        #expect(channel.peakAge == 0)
        #expect(abs(channel.peakDB - AudioMeterBallistics.decibels(fromLinear: 0.9)) < 1e-9)
    }

    @Test func peakMarkerNeverReadsBelowTheBar() {
        var channel = AudioMeterBallistics.step(.silent, peakLinear: 0.1, dt: 0.04)
        // Long quiet stretch lets the peak decay; a fresh transient lifts the bar above it.
        for _ in 0..<20 {
            channel = AudioMeterBallistics.step(channel, peakLinear: 0, dt: 0.5)
        }
        channel = AudioMeterBallistics.step(channel, peakLinear: 0.8, dt: 0.04)
        #expect(channel.peakDB >= channel.levelDB)
    }
}
