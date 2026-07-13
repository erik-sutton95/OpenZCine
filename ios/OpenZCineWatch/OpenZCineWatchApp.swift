import SwiftUI

/// OpenZCine watchOS companion. Mirrors the iPhone monitor on the wrist: a 16:9 preview feed, a
/// Record button, and a top bar with timecode + storage + camera battery. The iPhone owns the
/// camera session; this app is a WatchConnectivity remote.
@main
struct OpenZCineWatchApp: App {
    @State private var controller = WatchSessionController()

    var body: some Scene {
        WindowGroup {
            WatchMonitorView()
                .environment(controller)
                .onAppear { controller.activate() }
        }
    }
}
