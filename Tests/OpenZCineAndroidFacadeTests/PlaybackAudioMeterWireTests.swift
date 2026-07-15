import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

@Suite("Android playback audio meter wire")
struct PlaybackAudioMeterWireTests {
    @Test func emptyStateStartsSilent() {
        let wire = PlaybackAudioMeterWire.advance(
            previousPayload: [],
            leftPeakLinear: 0,
            rightPeakLinear: 0,
            deltaTimeSeconds: 0.042
        )

        #expect(wire.levels == .silent)
        #expect(wire.payload.count == PlaybackAudioMeterWire.scalarCount)
    }

    @Test func linearPeaksAttackThroughSharedDBConversion() {
        let wire = PlaybackAudioMeterWire.advance(
            previousPayload: PlaybackAudioMeterWire.silent.payload,
            leftPeakLinear: 1,
            rightPeakLinear: 0.5,
            deltaTimeSeconds: 0.042
        )

        #expect(wire.levels.left.levelDB == 0)
        #expect(wire.levels.left.peakDB == 0)
        #expect(
            abs(
                wire.levels.right.levelDB
                    - AudioMeterBallistics.decibels(fromLinear: 0.5)
            ) < 1e-9
        )
        #expect(wire.levels.right.peakDB == wire.levels.right.levelDB)
    }

    @Test func levelDecayUsesRetainedWireState() {
        let loud = PlaybackAudioMeterWire.advance(
            previousPayload: [],
            leftPeakLinear: 1,
            rightPeakLinear: 1,
            deltaTimeSeconds: 0.042
        )
        let decayed = PlaybackAudioMeterWire.advance(
            previousPayload: loud.payload,
            leftPeakLinear: 0,
            rightPeakLinear: 0,
            deltaTimeSeconds: 0.5
        )

        let expected = -AudioMeterBallistics.levelDecayPerSecond * 0.5
        #expect(abs(decayed.levels.left.levelDB - expected) < 1e-6)
        #expect(abs(decayed.levels.right.levelDB - expected) < 1e-6)
    }

    @Test func encodedPeakAgesPreserveHoldAcrossPolls() {
        let attack = PlaybackAudioMeterWire.advance(
            previousPayload: [],
            leftPeakLinear: 1,
            rightPeakLinear: 0.5,
            deltaTimeSeconds: 0.042
        )
        let held = PlaybackAudioMeterWire.advance(
            previousPayload: attack.payload,
            leftPeakLinear: 0,
            rightPeakLinear: 0,
            deltaTimeSeconds: 1
        )
        let released = PlaybackAudioMeterWire.advance(
            previousPayload: held.payload,
            leftPeakLinear: 0,
            rightPeakLinear: 0,
            deltaTimeSeconds: 1
        )

        #expect(held.levels.left.peakDB == 0)
        #expect(held.levels.left.peakAge == 1)
        #expect(released.levels.left.peakAge == 2)
        #expect(released.levels.left.peakDB < held.levels.left.peakDB)
        #expect(released.levels.right.peakDB < held.levels.right.peakDB)
    }

    @Test func malformedPriorPayloadRestartsBeforeAttack() {
        let wire = PlaybackAudioMeterWire.advance(
            previousPayload: [.nan, 0, 0],
            leftPeakLinear: 0.25,
            rightPeakLinear: 0,
            deltaTimeSeconds: 0.042
        )

        #expect(
            abs(
                wire.levels.left.levelDB
                    - AudioMeterBallistics.decibels(fromLinear: 0.25)
            ) < 1e-9
        )
        #expect(wire.levels.right == .silent)
    }

    @Test func decoderRejectsImpossibleOrNonFiniteState() {
        #expect(PlaybackAudioMeterWire(payload: [0]) == nil)
        #expect(
            PlaybackAudioMeterWire(
                payload: [-12, -6, 0, -.infinity, -6, 0]
            ) == nil
        )
        #expect(
            PlaybackAudioMeterWire(
                payload: [-6, -12, 0, -6, -6, 0]
            ) == nil
        )
        #expect(
            PlaybackAudioMeterWire(
                payload: [-6, -6, -1, -6, -6, 0]
            ) == nil
        )
    }

    @Test func nonFinitePollInputsCannotPoisonThePayload() {
        let wire = PlaybackAudioMeterWire.advance(
            previousPayload: [],
            leftPeakLinear: .nan,
            rightPeakLinear: .infinity,
            deltaTimeSeconds: .infinity
        )

        #expect(wire == .silent)
        #expect(wire.payload.allSatisfy { $0.isFinite })
    }
}
