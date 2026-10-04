import Foundation
import OpenCineAppKit
import OpenCineMedia

/// Borrows the actual gallery lifetime and immutable caller playlist. PTP/cache/rating stay
/// on NativeAppModel; the shared model owns the logical player instead of a second view state.
@MainActor final class NikonPlaybackSession {
    let owner: MonitorMediaPlaybackModel<MediaClip, String>
    let native: NikonPlaybackNativePort

    init(
        clips: [MediaClip], startingAt clip: MediaClip, model: NativeAppModel,
        native: NikonPlaybackNativePort = NikonPlaybackNativePort()
    ) throws {
        guard let library = model.mediaLibrary else { throw MonitorPlaybackError.unavailable }
        let codec = NikonMediaLibraryCodec(
            store: model.mediaClipStore, bucket: clip.cameraID, service: nil,
            downloaded: { model.isClipDownloaded($0) })
        let records = try clips.map(codec.record)
        guard let first = records.first(where: { $0.payload.id == clip.id }) else {
            throw MonitorPlaybackError.unavailable
        }
        self.native = native
        owner = MonitorMediaPlaybackModel<MediaClip, String>(
            library: library, native: native, readyTimeout: nil, retryNativeFailures: false,
            startTiming: .afterNativeItemInstallation,
            candidates: { record in native.candidates(for: record.payload, model: model) })
        native.isScrubbing = { [weak owner] in owner?.scrubbing ?? true }
        owner.load(first, playlist: records)
    }
    struct DeliveryPause {
        let item: MonitorPlaybackItemToken
        let resume: Bool
    }

    func pauseForDelivery(playing: Bool) -> DeliveryPause? {
        guard owner.isActive else { return nil }
        let captured = DeliveryPause(item: owner.token, resume: playing)
        owner.setPlaying(false)
        return captured
    }

    func resumeAfterDelivery(_ captured: DeliveryPause) {
        guard captured.resume, owner.isActive, owner.token == captured.item else { return }
        owner.setPlaying(true)
    }

    func navigate(to clip: MediaClip, clips: [MediaClip], model: NativeAppModel) {
        guard owner.isActive else { return }
        let codec = NikonMediaLibraryCodec(
            store: model.mediaClipStore, bucket: clip.cameraID, service: nil,
            downloaded: { model.isClipDownloaded($0) })
        guard let records = try? clips.map(codec.record),
            let next = records.first(where: { $0.payload.id == clip.id })
        else { return }
        owner.load(next, playlist: records)
    }

}

/// Exact retained Nikon presentation policy. This does not change shared transport seek math.
struct NikonPlaybackTailPresentation {
    private(set) var reachedEnd = false
    mutating func ended() { reachedEnd = true }
    mutating func reset() { reachedEnd = false }
    mutating func seeking(to time: Double, duration: Double) {
        guard duration > 0 else { return }
        if time < duration - 0.25 { reachedEnd = false }
    }
}
