import OpenZCineCore
import Testing

struct FocusControlModeTests {
    @Test func modeNamesAndWireValues() throws {
        #expect(FocusControlMode.nativeAF.title == "Native AF")
        #expect(FocusControlMode.timedRack.title == "Timed Rack")
        #expect(FocusControlMode(rawValue: "nativeAF") == .nativeAF)
        #expect(FocusControlMode(rawValue: "timedRack") == .timedRack)
    }

    @Test func nativeAFDoesNotDependOnTimedReferenceOrMarks() {
        var state = FocusRackState()
        state.phase = .uncertain
        state.referenceValid = false
        state.program.marks = [.init(id: "A", stepPosition: 0), .init(id: "B", stepPosition: 100)]
        #expect(!state.capabilities.canAutofocus)
        #expect(FocusControlModePolicy.allowsNativeAutofocus(mode: .nativeAF, rack: state))
        #expect(!FocusControlModePolicy.allowsNativeAutofocus(mode: .timedRack, rack: state))
        #expect(state.program.marks.count == 2)
    }

    @Test func activeAndUnconfirmedMovementCannotChangeModeOrAutofocus() {
        var state = FocusRackState()
        state.busy = true
        #expect(!FocusControlModePolicy.canChange(rack: state))
        #expect(!FocusControlModePolicy.allowsNativeAutofocus(mode: .nativeAF, rack: state))
        state.busy = false
        state.capabilities.canStop = true
        #expect(!FocusControlModePolicy.canChange(rack: state))
        state.capabilities.canStop = false
        state.phase = .stopUnconfirmed
        #expect(!FocusControlModePolicy.canChange(rack: state))
        #expect(!FocusControlModePolicy.allowsNativeAutofocus(mode: .nativeAF, rack: state))
    }

    @Test func pendingStopOrExternalCommandCannotChangeMode() {
        #expect(!FocusControlModePolicy.canChange(rack: nil, stopPending: true))
        #expect(!FocusControlModePolicy.canChange(rack: nil, externalFocusIdle: false))
        #expect(FocusControlModePolicy.canChange(rack: nil))
    }

    @Test func nativeAFRequiresReportedMovieAFF() {
        #expect(
            FocusControlModePolicy.nativeAFConfigured(movieFocusMode: "AF-F", photography: false))
        #expect(!FocusControlModePolicy.nativeAFConfigured(movieFocusMode: nil, photography: false))
        #expect(
            !FocusControlModePolicy.nativeAFConfigured(movieFocusMode: "AF-S", photography: false))
        #expect(
            !FocusControlModePolicy.nativeAFConfigured(movieFocusMode: "AF-F", photography: true))
    }
}
