import OpenCineAppKit
import OpenCineCore
import Testing

@testable import Runner

/// The Nikon root on the shared `ShellModel`: which cover shows and how a connect and the monitor
/// treat it. SIMULATED sessions; nothing dials a camera.
@MainActor
@Suite("Shell covers")
struct ShellAdoptionTests {
    private func camera() -> ConnectedCamera {
        ConnectedCamera(
            saved: SavedCamera(
                id: "SIMULATED-shell", integration: IntegrationID("org.opencapture.nikon-ptp"),
                advertisedName: "SIMULATED camera", model: "SIMULATED"),
            session: NikonPictureLifetimeSession())
    }

    @Test("A fresh launch shows no cover")
    func launchStartsUncovered() {
        let model = NativeAppModel()
        #expect(!model.isStandaloneMediaLibraryPresented && !model.isStandaloneSettingsPresented)
        #expect(model.shell.cover == nil && model.shell.monitor == nil)
    }

    @Test("The cameras page's Media and Settings open standalone and close")
    func standaloneCoversOpenAndClose() {
        let model = NativeAppModel()
        model.openCachedMediaLibrary()
        #expect(model.isStandaloneMediaLibraryPresented && model.mediaBrowserSource == .camera)
        model.dismissMediaLibrary()
        #expect(!model.isStandaloneMediaLibraryPresented && !model.isStandaloneSettingsPresented)
        model.openStandaloneSettings()
        #expect(model.isStandaloneSettingsPresented && model.operatorSettingsTab == .storage)
        model.dismissMediaLibrary()
        #expect(!model.isStandaloneSettingsPresented)
    }

    /// Intended change (the shared shell): one cover at a time.
    @Test("Settings opened over Media replaces it")
    func oneCoverAtATime() {
        let model = NativeAppModel()
        model.openCachedMediaLibrary()
        model.openStandaloneSettings()
        #expect(model.isStandaloneSettingsPresented)
        #expect(!model.isStandaloneMediaLibraryPresented)
    }

    /// Intended change (the shared shell): a connect shows the monitor, never a leftover page.
    @Test("A connect closes a standalone cover")
    func connectClosesStandaloneCover() {
        let model = NativeAppModel()
        model.openStandaloneSettings()
        model.shell.present(camera())
        #expect(!model.isStandaloneSettingsPresented)
        model.shell.close()
    }

    @Test("The monitor's Settings and Media are its panels, not standalone covers")
    func monitorPanelsAreNotStandalone() {
        let model = NativeAppModel()
        model.shell.present(camera())
        model.isMonitorPresented = true
        for panel in [NativeAppModel.ActivePanel.settings, .media] {
            model.activePanel = panel
            #expect(model.shell.cover == (panel == .settings ? .settings : .media))
            #expect(!model.isStandaloneMediaLibraryPresented)
            #expect(!model.isStandaloneSettingsPresented)
            model.activePanel = nil
            #expect(model.shell.cover == nil)
        }
        model.shell.close()
    }

    @Test("The shell's monitor is the camera monitor while it shows")
    func shellMonitorFollowsTheCameraMonitor() {
        let model = NativeAppModel()
        let session = NikonPictureLifetimeSession()
        model.shell.present(
            ConnectedCamera(
                saved: SavedCamera(
                    id: "SIMULATED-shell", integration: IntegrationID("org.opencapture.nikon-ptp"),
                    advertisedName: "SIMULATED camera", model: "SIMULATED"),
                session: session))
        model.isMonitorPresented = true
        #expect(model.shell.monitor != nil)
        model.isMonitorPresented = false
        #expect(model.shell.monitor == nil)
    }

    /// The Frame.io sign-in and the RED LUT download keep their surface through the hop.
    @Test("An internet hop re-hosts the monitor's panel once the monitor has gone")
    func hopRehostsThePanel() {
        for panel in [NativeAppModel.ActivePanel.settings, .media] {
            let model = NativeAppModel()
            model.shell.present(camera())
            model.isMonitorPresented = true
            model.activePanel = panel
            model.leaveMonitorForInternetHop(rehostActivePanel: true)
            #expect(model.shell.monitor == nil && model.activePanel == nil)
            #expect(model.isStandaloneSettingsPresented == (panel == .settings))
            #expect(model.isStandaloneMediaLibraryPresented == (panel == .media))
        }
        let model = NativeAppModel()
        model.shell.present(camera())
        model.isMonitorPresented = true
        model.activePanel = .settings
        model.leaveMonitorForInternetHop(rehostActivePanel: false)
        #expect(model.shell.cover == nil)
    }
}
