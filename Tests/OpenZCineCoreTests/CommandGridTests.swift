import Testing

@testable import OpenZCineCore

@Suite("Command grid order")
struct CommandGridTests {
    @Test("The default order is every tile in canonical order")
    func defaultOrder() {
        #expect(CommandGridOrder.default == CommandTileKind.allCases)
        #expect(CommandGridOrder.default.count == 8)
    }

    @Test("Reconcile drops duplicates/unknowns and appends any missing tiles")
    func reconcile() {
        // A persisted order missing the last three tiles, with one duplicate.
        let stored: [CommandTileKind] = [.iso, .mode, .iso, .shutter, .iris, .whiteBalance]
        let reconciled = CommandGridOrder.reconciled(stored)
        // Deduped, kept order, then the missing tiles appended in canonical order.
        #expect(
            reconciled == [
                .iso, .mode, .shutter, .iris, .whiteBalance, .resolutionFramerate, .codec, .ibis,
            ])
        #expect(Set(reconciled) == Set(CommandTileKind.allCases))
        // An empty/garbage order falls back to the full canonical set.
        #expect(CommandGridOrder.reconciled([]) == CommandTileKind.allCases)
    }

    @Test("Moving a tile re-inserts it at the clamped target index")
    func moving() {
        let order = CommandTileKind.allCases  // mode, iso, shutter, iris, wb, rf, codec, ibis
        // Move codec (index 6) to the front.
        #expect(
            CommandGridOrder.moving(.codec, to: 0, in: order)
                == [
                    .codec, .mode, .iso, .shutter, .iris, .whiteBalance, .resolutionFramerate,
                    .ibis,
                ])
        // Move mode (index 0) to the end (clamped to count after removal).
        #expect(
            CommandGridOrder.moving(.mode, to: 99, in: order)
                == [
                    .iso, .shutter, .iris, .whiteBalance, .resolutionFramerate, .codec, .ibis,
                    .mode,
                ])
        // Moving to its own slot is a no-op.
        #expect(CommandGridOrder.moving(.iso, to: 1, in: order) == order)
    }
}
