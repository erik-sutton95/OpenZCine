import Testing

@testable import Runner

/// The crash this pins: TestFlight 0.2.5 (253) on an iPad16,5 died with
/// `-[__NSArrayM insertObject:atIndex:]: object cannot be nil` thrown from inside
/// `-[VTFrameProcessor processWithCommandBuffer:parameters:]`. The filter honoured the
/// configuration's future-frame count and never read its PAST-frame count, so it handed the
/// processor at most one previous reference however many it had been configured for — and passed
/// ZERO on the first frame after any restart. A temporal processor fills a missing reference with
/// nil, and that throw is Objective-C, so there is nothing Swift can catch.
struct LiveFeedNoiseFilterWindowTests {
    @Test("Both reference windows must be exactly full")
    func bothWindowsMustBeFull() {
        #expect(
            LiveFeedNoiseFilter.canRun(
                past: 2, previousWanted: 2, futures: 2, futureWanted: 2))

        // The shipped bug, in both of its shapes.
        #expect(
            !LiveFeedNoiseFilter.canRun(
                past: 1, previousWanted: 2, futures: 2, futureWanted: 2),
            "one reference against a two-frame configuration is the iPad16,5 crash")
        #expect(
            !LiveFeedNoiseFilter.canRun(
                past: 0, previousWanted: 1, futures: 2, futureWanted: 2),
            "the first frame after a restart had an empty past window and ran anyway")
    }

    /// A processor that wants no references of a kind is satisfied by having none.
    @Test("A zero-length window is full when it is empty")
    func zeroLengthWindowIsSatisfied() {
        #expect(
            LiveFeedNoiseFilter.canRun(
                past: 0, previousWanted: 0, futures: 0, futureWanted: 0))
        #expect(
            LiveFeedNoiseFilter.canRun(
                past: 1, previousWanted: 1, futures: 0, futureWanted: 0))
    }

    /// Too MANY is refused as well. The count is a contract, not a floor — a processor handed an
    /// unexpected extra reference is being told about a frame it never agreed to see.
    @Test("An over-full window is refused too")
    func overFullWindowIsRefused() {
        #expect(
            !LiveFeedNoiseFilter.canRun(
                past: 3, previousWanted: 2, futures: 2, futureWanted: 2))
        #expect(
            !LiveFeedNoiseFilter.canRun(
                past: 2, previousWanted: 2, futures: 3, futureWanted: 2))
    }
}
