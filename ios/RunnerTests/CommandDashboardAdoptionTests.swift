import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenZCineCore
import Testing

@testable import Runner

/// DISP 3 through the shared command dashboard: the order store keeps an operator's existing
/// arrangement, a move on the visible grid leaves hidden tiles in place, and the Nikon projection
/// supplies only tile kinds, values and the pickers they open.
@MainActor @Suite struct CommandDashboardAdoptionTests {
    private func withStorage(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SIMULATED.CommandGrid.\(UUID().uuidString)"
        let storage = try #require(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        try body(storage)
    }

    /// The bytes the retired `PreferencesStore.save(_:)` wrote under `commandGridOrder.v1`.
    @Test func anArrangementStoredBeforeTheSharedOwnerLoadsAndStaysReadable() throws {
        try withStorage { storage in
            let stored: [CommandTileKind] = [.codec, .iso, .mode, .shutter, .iris, .whiteBalance]
            storage.set(try JSONEncoder().encode(stored), forKey: "commandGridOrder.v1")
            let store = PreferencesStore.commandTileOrder(storage: storage)
            // The tiles the stored order lacks join at the end in their declared order.
            #expect(store.load() == stored + [.resolutionFramerate, .ibis])
            store.save(
                moveMonitorCommandTile(
                    store.load(), .ibis, targetIndex: 0, all: CommandTileKind.allCases))
            let reread = try JSONDecoder().decode(
                [CommandTileKind].self, from: #require(storage.data(forKey: "commandGridOrder.v1")))
            #expect(reread == [.ibis] + stored + [.resolutionFramerate])
        }
    }

    @Test func aFreshInstallStartsFromTheDeclaredOrderWithoutWriting() throws {
        try withStorage { storage in
            #expect(
                PreferencesStore.commandTileOrder(storage: storage).load()
                    == CommandTileKind.allCases)
            #expect(storage.object(forKey: "commandGridOrder.v1") == nil)
        }
    }

    @Test func aMoveOnTheVisibleGridKeepsAHiddenTileInPlace() {
        let order = CommandTileKind.allCases  // mode, iso, shutter, iris, wb, rf, codec, ibis
        let hidden: Set<CommandTileKind> = [.mode]
        // Visible slot 1 is the shutter's: the ISO tile moves after it, Mode stays first.
        #expect(
            NikonCommandGridOrder.moving(.iso, to: 1, in: order, hidden: hidden)
                == [
                    .mode, .shutter, .iso, .iris, .whiteBalance, .resolutionFramerate, .codec,
                    .ibis,
                ])
        #expect(
            NikonCommandGridOrder.moving(.codec, to: 0, in: order, hidden: hidden)
                == [
                    .mode, .codec, .iso, .shutter, .iris, .whiteBalance, .resolutionFramerate,
                    .ibis,
                ])
        // A hidden tile cannot be dragged, so asking to move it changes nothing.
        #expect(NikonCommandGridOrder.moving(.mode, to: 4, in: order, hidden: hidden) == order)
        // With nothing hidden the visible slot is the order's slot.
        #expect(
            NikonCommandGridOrder.moving(.mode, to: 99, in: order, hidden: [])
                == [
                    .iso, .shutter, .iris, .whiteBalance, .resolutionFramerate, .codec, .ibis,
                    .mode,
                ])
    }

    @Test func videoTilesFollowTheVisibleOrderAndOpenTheirPickers() throws {
        let model = NativeAppModel()
        let tiles = model.commandDashboardTiles
        #expect(tiles.map(\.kind) == model.visibleCommandGridOrder.map(Optional.some))
        let pickers: [CommandTileKind: CameraPicker] = [
            .mode: .mode, .iso: .iso, .shutter: .shutter, .iris: .iris,
            .whiteBalance: .whiteBalance,
            .resolutionFramerate: .resolution, .codec: .codec, .ibis: .stabilization,
        ]
        for tile in tiles {
            let kind = try #require(tile.kind)
            #expect(tile.request == pickers[kind].map { NikonCommandRequest(picker: $0) })
        }
        #expect(tiles.first { $0.kind == .ibis }?.title == "VR / e-VR")
        #expect(tiles.first { $0.kind == .resolutionFramerate }?.title == "Resolution Framerate")
    }

    @Test func theSideColumnKeepsItsSectionsCellsAndTabs() {
        let model = NativeAppModel()
        let sections = model.commandDashboardSections
        #expect(sections.map(\.title) == ["Image", "Focus", "Audio", "Monitor"])
        #expect(
            sections.map { $0.cells.map(\.title) } == [
                ["Tone", "Picture Profile"], ["Mode", "Area", "Subject"],
                ["Sens", "32-bit Float", "Input", "Wind", "Atten"], ["Grid"],
            ])
        let focus = sections[1].cells.map(\.request)
        #expect(focus == [0, 1, 2].map { NikonCommandRequest(picker: .focus, mode: $0) })
        let audio = sections[2].cells.map { $0.request?.mode }
        #expect(audio == [0, 4, 1, 2, 3])
        // Tone and Grid read camera settings this monitor does not write; the profile is a placeholder.
        #expect(sections[0].cells.allSatisfy { $0.request == nil })
        #expect(sections[0].cells[1].muted)
        #expect(sections[3].cells[0].request == nil)
    }

    @Test func theHealthStripReadsTheCameraState() {
        let model = NativeAppModel()
        let health = model.commandDashboardHealth
        #expect(health.temperature == model.cameraState.temperature)
        #expect(health.temperatureOk == model.cameraState.temperature.hasPrefix("OK"))
        #expect(health.storage == model.liveMediaReadout)
        #expect(health.camera == model.cameraState.cameraName)
        #expect(health.lens == model.cameraState.lens)
    }
}
