import UIKit

/// Decodes Nikon live-view JPEG frames to fully-realized bitmaps **off the main actor**.
///
/// `UIImage(data:)` only wraps the JPEG — the actual decode is deferred to draw time, which lands on
/// the main thread when `UIImageView`/Core Image first touches the image. `preparingForDisplay()`
/// forces that decode now (and preserves EXIF orientation/scale, unlike a raw `CGImageSource` path),
/// so the main thread only ever composites an already-decoded frame.
///
/// A single long-lived actor keeps the work off main without spawning a task per frame: the
/// streaming loop is already serial, so it simply `await`s each decode.
actor FrameDecoder {
    /// Returns `jpeg` decoded into a display-ready `UIImage`, or `nil` if it isn't a readable image.
    /// The result is `sending` — freshly created and not retained here, so it transfers safely back
    /// to the caller's actor.
    func decode(_ jpeg: Data) -> sending UIImage? {
        autoreleasepool { UIImage(data: jpeg)?.preparingForDisplay() }
    }
}
