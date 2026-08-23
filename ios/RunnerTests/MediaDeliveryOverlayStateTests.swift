import Testing

@testable import Runner

@Suite("Media delivery overlay status")
struct MediaDeliveryOverlayStateTests {
    @Test("Save to Photos asks for access instead of freezing a percent")
    func awaitingPhotosAccessHasAWaitingStatus() {
        let state = MediaDeliveryOverlayState(
            destination: .nativeShare,
            totalClips: 1,
            clipIndex: 1,
            clipFraction: 0.75,
            postExportAction: .saveToPhotos,
            phase: .awaitingPhotosAccess
        )
        #expect(state.statusLine == "Waiting for Photos access…")
        #expect(state.showsBusySpinner)
        #expect(state.percentText.isEmpty)
    }

    @Test("Photos ingest keeps a spinner after export")
    func savingToPhotosKeepsBusyChrome() {
        let state = MediaDeliveryOverlayState(
            destination: .nativeShare,
            totalClips: 1,
            clipIndex: 1,
            clipFraction: 0.9,
            postExportAction: .saveToPhotos,
            phase: .savingToPhotos
        )
        #expect(state.statusLine == "Saving to Photos…")
        #expect(state.showsBusySpinner)
        #expect(state.percentText.isEmpty)
    }

    @Test("Save-to-Photos export uses the Android-matching verb")
    func saveToPhotosExportVerb() {
        let state = MediaDeliveryOverlayState(
            destination: .nativeShare,
            totalClips: 1,
            clipIndex: 1,
            clipFraction: 0.4,
            postExportAction: .saveToPhotos
        )
        #expect(state.statusLine.hasPrefix("Saving to Photos"))
        #expect(state.statusLine.contains("40%"))
        #expect(!state.showsBusySpinner)
    }
}
