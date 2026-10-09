import Observation
import Testing

@testable import Runner

/// SIMULATED actual model publication, without a native camera or connection.
@MainActor
struct WhiteBalanceTintPublicationTests {
    @Test func completePairIsVisibleAtTheFirstAmberBlueNotification() {
        let model = simulatedModel()
        let probe = TintObservationProbe()
        withObservationTracking {
            _ = model.whiteBalanceTintAB
        } onChange: {
            MainActor.assumeIsolated { probe.pairs.append(TintPair(model)) }
        }
        model.publishWhiteBalanceTint(amberBlue: 3, greenMagenta: -2)
        #expect(probe.pairs == [TintPair(3, -2)])
        #expect(TintPair(model) == TintPair(3, -2))
    }

    @Test func completePairIsVisibleAtTheFirstGreenMagentaNotification() {
        let model = simulatedModel()
        let probe = TintObservationProbe()
        withObservationTracking {
            _ = model.whiteBalanceTintGM
        } onChange: {
            MainActor.assumeIsolated { probe.pairs.append(TintPair(model)) }
        }
        model.publishWhiteBalanceTint(amberBlue: 3, greenMagenta: -2)
        #expect(probe.pairs == [TintPair(3, -2)])
        #expect(TintPair(model) == TintPair(3, -2))
    }

    @Test func reentrantPublicationDuringAmberBlueNotificationPreservesTheSuccessor() {
        let model = simulatedModel()
        let probe = TintObservationProbe()
        withObservationTracking {
            _ = model.whiteBalanceTintAB
        } onChange: {
            MainActor.assumeIsolated {
                probe.pairs.append(TintPair(model))
                if probe.pairs.count == 1 {
                    model.publishWhiteBalanceTint(amberBlue: -4, greenMagenta: 5)
                }
            }
        }
        model.publishWhiteBalanceTint(amberBlue: 3, greenMagenta: -2)
        #expect(probe.pairs == [TintPair(3, -2)], "A one-shot callback must not recursively reenter")
        #expect(TintPair(model) == TintPair(-4, 5), "The outgoing read cannot overwrite its successor")
    }

    @Test func reentrantPublicationDuringGreenMagentaNotificationPreservesTheSuccessor() {
        let model = simulatedModel()
        let probe = TintObservationProbe()
        withObservationTracking {
            _ = model.whiteBalanceTintGM
        } onChange: {
            MainActor.assumeIsolated {
                probe.pairs.append(TintPair(model))
                if probe.pairs.count == 1 {
                    model.publishWhiteBalanceTint(amberBlue: -4, greenMagenta: 5)
                }
            }
        }
        model.publishWhiteBalanceTint(amberBlue: 3, greenMagenta: -2)
        #expect(probe.pairs == [TintPair(3, -2)])
        #expect(TintPair(model) == TintPair(-4, 5))
    }

    @Test func reentrantWritableCoordinatesRetainTheOperatorValues() {
        let model = simulatedModel()
        let probe = TintObservationProbe()
        withObservationTracking {
            _ = model.whiteBalanceTintAB
        } onChange: {
            MainActor.assumeIsolated {
                probe.pairs.append(TintPair(model))
                if probe.pairs.count == 1 {
                    model.whiteBalanceTintAB = 6
                    model.whiteBalanceTintGM = 1
                }
            }
        }
        model.publishWhiteBalanceTint(amberBlue: 3, greenMagenta: -2)
        #expect(probe.pairs == [TintPair(3, -2)])
        #expect(TintPair(model) == TintPair(6, 1))
    }

    @Test func writableCoordinatesNotifyTheirCommittedValueAndKeepTheOtherCoordinate() {
        let model = simulatedModel()
        model.publishWhiteBalanceTint(amberBlue: 2, greenMagenta: -3)
        let probe = TintObservationProbe()
        withObservationTracking {
            _ = model.whiteBalanceTintAB
        } onChange: {
            MainActor.assumeIsolated { probe.pairs.append(TintPair(model)) }
        }
        model.whiteBalanceTintAB = 4
        #expect(probe.pairs == [TintPair(4, -3)])
        withObservationTracking {
            _ = model.whiteBalanceTintGM
        } onChange: {
            MainActor.assumeIsolated { probe.pairs.append(TintPair(model)) }
        }
        model.whiteBalanceTintGM = 5
        #expect(probe.pairs == [TintPair(4, -3), TintPair(4, 5)])
    }

    @Test func observerRearmedAfterReentryReceivesTheQueuedSuccessorNotification() {
        let model = simulatedModel()
        let probe = TintObservationProbe()
        withObservationTracking {
            _ = model.whiteBalanceTintAB
        } onChange: {
            MainActor.assumeIsolated {
                probe.pairs.append(TintPair(model))
                if probe.pairs.count == 1 {
                    model.publishWhiteBalanceTint(amberBlue: -4, greenMagenta: 5)
                    withObservationTracking {
                        _ = model.whiteBalanceTintAB
                    } onChange: {
                        MainActor.assumeIsolated { probe.pairs.append(TintPair(model)) }
                    }
                }
            }
        }
        model.publishWhiteBalanceTint(amberBlue: 3, greenMagenta: -2)
        #expect(probe.pairs == [TintPair(3, -2), TintPair(-4, 5)])
        #expect(TintPair(model) == TintPair(-4, 5))
    }

    private func simulatedModel() -> NativeAppModel {
        let model = NativeAppModel()
        model.isDemoSession = true
        return model
    }
}

@MainActor
private final class TintObservationProbe {
    var pairs: [TintPair] = []
}

private struct TintPair: Equatable {
    let amberBlue: Int
    let greenMagenta: Int
    init(_ amberBlue: Int, _ greenMagenta: Int) {
        self.amberBlue = amberBlue; self.greenMagenta = greenMagenta
    }
    @MainActor init(_ model: NativeAppModel) {
        amberBlue = model.whiteBalanceTintAB; greenMagenta = model.whiteBalanceTintGM
    }
}
