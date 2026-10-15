import Observation
import OpenCineAppKit
import OpenCineCore
import OpenZCineCore
import Testing

@testable import Runner

/// Whether an observed property was written; the observation callback may run off the main actor.
private final class CoverWrite: @unchecked Sendable { var seen = false }

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
        model.operatorSettingsTab = .display
        model.operatorSession.settingsScrollOffsets[.display] = 180
        model.openStandaloneSettings()
        // A2-84: the shared landing rule, the operator's last tab and its scroll offset.
        #expect(model.isStandaloneSettingsPresented && model.operatorSettingsTab == .display)
        #expect(model.operatorSession.settingsScrollOffsets[.display] == 180)
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

    /// The open page keeps its identity through the hop (A2-07): the cover is never cleared, so
    /// the gallery's scroll, selection and open delivery popup survive the monitor leaving.
    @Test("An internet hop keeps the monitor's panel page without re-hosting it")
    func hopKeepsThePanelPage() async {
        for panel in [NativeAppModel.ActivePanel.settings, .media] {
            let model = NativeAppModel()
            model.hopNative = .init(
                currentSSID: { "SIMULATED-AP" }, leaveNetwork: { _ in }, rejoin: { _, _ in })
            model.shell.present(camera())
            model.isMonitorPresented = true
            model.activePanel = panel
            let cover = model.shell.cover
            let coverWritten = CoverWrite()
            withObservationTracking {
                _ = model.shell.cover
            } onChange: {
                coverWritten.seen = true
            }
            let token = model.internetHop.begin(model.hopRoute(rehostActivePanel: true))
            #expect(token != nil)
            for _ in 0..<500 where model.shell.monitor != nil { await Task.yield() }
            #expect(model.shell.monitor == nil && model.activePanel == nil)
            #expect(model.shell.cover == cover && !coverWritten.seen, "the page is never torn down")
            #expect(model.isStandaloneSettingsPresented == (panel == .settings))
            #expect(model.isStandaloneMediaLibraryPresented == (panel == .media))
            if let token { model.internetHop.end(token) }
        }
        let model = NativeAppModel()
        model.hopNative = .init(
            currentSSID: { "SIMULATED-AP" }, leaveNetwork: { _ in }, rejoin: { _, _ in })
        model.shell.present(camera())
        model.isMonitorPresented = true
        model.activePanel = .settings
        let token = model.internetHop.begin(model.hopRoute(rehostActivePanel: false))
        for _ in 0..<500 where model.shell.monitor != nil { await Task.yield() }
        #expect(model.shell.cover == nil, "a support link leaves nothing behind")
        if let token { model.internetHop.end(token) }
    }

    @Test("A pending common edit shows over the reported value without being written into it")
    func pendingEditsShowOverTheReport() {
        let reported = [
            CameraValue(label: "ISO", value: "800", isSettable: true),
            CameraValue(label: "WB", value: "5600K", isSettable: true),
            CameraValue(label: "FOCUS", value: "AF-C", isSettable: true),
        ]
        #expect(NativeAppModel.showing([:], over: reported) == reported)
        let shown = NativeAppModel.showing(
            [.iso: .iso(.manual(1600)), .whiteBalance: .whiteBalance(.auto)], over: reported)
        #expect(shown.map(\.value) == ["1600", "Auto", "AF-C"])
        #expect(shown.map(\.label) == reported.map(\.label))
    }

    @Test(
        "SIMULATED third scope stays active and inspectable while fit renders the first two eligible scopes"
    )
    func scopeSelectionDoesNotConfuseActivationWithFitPlacement() {
        let model = NativeAppModel()
        let saved = model.preferences
        let live = model.assist.liveTools
        let options = model.assist.configureTool
        defer {
            for tool in MonitorAssistTool.scopeTools {
                model.assist.set(tool, visible: live.contains(tool), context: .liveView)
            }
            model.preferences = saved
            model.assist.configureTool = options
        }
        model.isMonitorPresented = true
        model.setDisplayMode(.live)
        model.monitorIsPortrait = true
        model.preferences.portraitFeedAspect = .fit16x9
        for tool in MonitorAssistTool.scopeTools {
            model.assist.set(tool, visible: false, context: .liveView)
        }
        model.setAssist(.waveform, visible: true)
        model.setAssist(.histogram, visible: true)
        model.monitorNote = nil

        model.setAssist(.parade, visible: true)

        #expect(model.assist.liveTools.isSuperset(of: [.waveform, .histogram, .parade]))
        #expect(
            model.renderedFitScopes == [
                .waveform, .parade,
            ])
        #expect(model.monitorNote == nil)
        model.showAssist(.vectorscope)
        #expect(model.assist.configureTool == MonitorAssistTool.vectorscope.selection)
        model.toggleAssist(.vectorscope)
        #expect(model.assist.liveTools.contains(.vectorscope))
        #expect(
            model.renderedFitScopes == [
                .waveform, .parade,
            ])
        model.interfaceLocked = true
        model.toggleAssist(.vectorscope)
        #expect(model.assist.liveTools.contains(.vectorscope))
    }
}
