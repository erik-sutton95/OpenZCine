import OpenCineMedia
import OpenZCineCore
import Testing

/// Behavior audit ZIA-035/ZIA-216: the photo SHOTS pill flips to the card's free space and free
/// percentage ("521 GB 47%"), never to a recording time, whatever the MEDIA cell showed in video.
/// Android shows the same photo form (`MonitorScreen`, "free percent").
struct LiveMediaReadoutTests {
    private let card = StorageReadout(freeBytes: 904_750_000_000, totalBytes: 1_920_000_000_000)

    @Test func photoStorageShowsFreeSpaceAndPercentNeverMinutes() {
        for prefersDuration in [false, true] {
            #expect(
                LiveMediaReadout.label(
                    card, recordingTime: "~47 Min", portrait: false,
                    prefersDuration: prefersDuration, photo: true) == "\(card.free) 47%")
            #expect(
                LiveMediaReadout.label(
                    card, recordingTime: "~47 Min", portrait: true,
                    prefersDuration: prefersDuration, photo: true) == "905GB 47%")
        }
        let noCapacity = StorageReadout(freeBytes: 904_750_000_000, totalBytes: nil)
        #expect(
            LiveMediaReadout.label(
                noCapacity, recordingTime: nil, portrait: false,
                prefersDuration: true, photo: true) == noCapacity.free)
        #expect(
            LiveMediaReadout.label(
                nil, recordingTime: "~47 Min", portrait: false,
                prefersDuration: true, photo: true) == StorageReadout.unavailable)
    }

    @Test func videoKeepsTheMediaCellPreference() {
        #expect(
            LiveMediaReadout.label(
                card, recordingTime: "~47 Min", portrait: false,
                prefersDuration: true, photo: false) == "~47 Min")
        #expect(
            LiveMediaReadout.label(
                card, recordingTime: nil, portrait: false,
                prefersDuration: true, photo: false) == "-- Min")
        #expect(
            LiveMediaReadout.label(
                card, recordingTime: "~47 Min", portrait: false,
                prefersDuration: false, photo: false) == card.free)
        #expect(
            LiveMediaReadout.label(
                card, recordingTime: nil, portrait: true,
                prefersDuration: false, photo: false) == "905GB")
    }

    /// Hardware pass 3.4: the video MEDIA cell steps free space, free percentage, then the
    /// estimated time, the shared surface's order in Pocket and Insta.
    @Test func videoFormsStepFreePercentThenTime() {
        #expect(
            LiveMediaReadout.videoForms(card, recordingTime: "~47 Min", portrait: false)
                == [card.free, "47%", "~47 Min"])
        #expect(
            LiveMediaReadout.videoForms(card, recordingTime: "~47 Min", portrait: true)
                == ["905GB", "47%", "~47 Min"])
        #expect(
            LiveMediaReadout.videoForms(card, recordingTime: nil, portrait: false) == [
                card.free, "47%",
            ])
        let noCapacity = StorageReadout(freeBytes: 904_750_000_000, totalBytes: nil)
        #expect(
            LiveMediaReadout.videoForms(noCapacity, recordingTime: "~47 Min", portrait: false)
                == [noCapacity.free, "~47 Min"])
        #expect(
            LiveMediaReadout.videoForms(nil, recordingTime: nil, portrait: false)
                == [StorageReadout.unavailable])
    }
}
