import OpenCineWatch
import SwiftUI

/// OpenZCine watchOS companion. Mirrors the iPhone monitor on the wrist: a 16:9 preview feed, a
/// Record button, and a top bar with timecode + storage + camera battery. The iPhone owns the
/// camera session; this app is a WatchConnectivity remote. The shared scene owns the receiver's
/// activation and its re-arm on return to active (#187).
@main
struct OpenZCineWatchApp: App {
    var body: some Scene {
        WatchReceiverScene(receiver: WatchSessionController()) { _ in
            WatchMonitorView()
        }
    }
}
