import SwiftUI

/// OpenZCine watchOS companion. Mirrors the iPhone monitor on the wrist: a 16:9 preview feed, a
/// Record button, and a top bar with timecode + storage + camera battery. The iPhone owns the
/// camera session; this app is a WatchConnectivity remote.
@main
struct OpenZCineWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = WatchSessionController()

    var body: some Scene {
        WindowGroup {
            WatchMonitorView()
                .environment(controller)
                .onAppear { controller.activate() }
                // A dimmed display suspends the app without re-running `onAppear`, so returning to
                // active is the only signal that the link needs re-arming (#187).
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { controller.resume() }
                }
        }
    }
}
