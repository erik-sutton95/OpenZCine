import OpenCineMedia
import OpenZCineCore
import Testing

/// Behavior audit ZIA-035/ZIA-216: the photo SHOTS pill flips to the card's free space and free
/// percentage ("905GB 47%"), never to a recording time. Android shows the same photo form
/// (`MonitorScreen`, "free percent"). Hardware pass 7.5: one precision in both orientations.
struct LiveMediaReadoutTests {
    @Test func photoStorageShowsFreeSpaceAndPercentNeverMinutes() {
        let card = StorageReadout(freeBytes: 904_750_000_000, totalBytes: 1_920_000_000_000)
        #expect(LiveMediaReadout.photoStorage(card) == "905GB 47%")
        let noCapacity = StorageReadout(freeBytes: 904_750_000_000, totalBytes: nil)
        #expect(LiveMediaReadout.photoStorage(noCapacity) == "905GB")
        #expect(LiveMediaReadout.photoStorage(nil) == StorageReadout.unavailable)
    }
}
