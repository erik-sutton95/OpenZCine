import Foundation
import OpenCineAppKit
import OpenZCineCore
import Testing

@testable import Runner

@MainActor @Suite struct SettingsPreferenceMigrationTests {
    private let legacy = "operatorPreferences.v1"
    private let awake = "OpenZCine.KeepScreenAwake"
    private let record = "OpenZCine.RecordConfirmation"
    private let haptics = "OpenZCine.HapticsEnabled"
    private let remote = "OpenZCine.RemoteShutter"

    private func legacyFields(_ storage: UserDefaults) throws -> [String: Any] {
        let data = try #require(storage.data(forKey: legacy))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func withStorage(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SIMULATED.Z1.Preferences.\(UUID().uuidString)"
        let storage = try #require(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        try body(storage)
    }

    @Test func independentlySeedsValidLegacyFieldsAndKeepsExistingDestinations() throws {
        try withStorage { storage in
            let data = Data(
                #"{"keepScreenAwake":false,"recordConfirmationEnabled":false,"hapticsEnabled":false,"futureChoice":{"mode":"unknown"}}"#
                    .utf8)
            storage.set(data, forKey: legacy)
            storage.set(true, forKey: record)
            let loaded = PreferencesStore.loadPreferences(storage: storage)
            #expect(!loaded.keepScreenAwake)
            #expect(loaded.recordConfirmationEnabled)
            #expect(!loaded.hapticsEnabled)
            #expect(storage.object(forKey: awake) as? Bool == false)
            #expect(storage.object(forKey: record) as? Bool == true)
            #expect(storage.object(forKey: haptics) as? Bool == false)
            #expect(storage.data(forKey: legacy) == data)
            let snapshot = storage.dictionaryRepresentation() as NSDictionary
            #expect(PreferencesStore.loadPreferences(storage: storage) == loaded)
            #expect(snapshot.isEqual(to: storage.dictionaryRepresentation()))
            #expect(storage.object(forKey: "OpenZCine.HDRDisplay") == nil)
            #expect(storage.object(forKey: "OpenZCine.CacheFullResolution") == nil)
        }
    }

    @Test func malformedKnownValuesDoNotPreventOtherFieldsOrOverwriteExplicitFalse() throws {
        try withStorage { storage in
            storage.set(
                Data(
                    #"{"keepScreenAwake":1,"hapticsEnabled":false,"recordConfirmationEnabled":"future","recordHoldEnabled":false}"#
                        .utf8), forKey: legacy)
            storage.set(false, forKey: awake)
            let loaded = PreferencesStore.loadPreferences(storage: storage)
            #expect(!loaded.keepScreenAwake)
            #expect(!loaded.recordConfirmationEnabled)
            #expect(!loaded.hapticsEnabled)
            #expect(storage.object(forKey: awake) as? Bool == false)
            #expect(storage.object(forKey: record) as? Bool == false)
            #expect(storage.object(forKey: haptics) as? Bool == false)
            storage.removeObject(forKey: awake)
            #expect(PreferencesStore.loadPreferences(storage: storage).keepScreenAwake)
            #expect(storage.object(forKey: awake) == nil, "A JSON number is not a legacy Bool")
        }
    }

    @Test func commonOnlyEditsPersistSharedKeysWithoutChangingTheLegacyBytes() throws {
        try withStorage { storage in
            let data = Data(
                #"{ "keepScreenAwake": false, "hapticsEnabled": false, "streamPreset": "future-stream", "future": [1,2,3] }"#
                    .utf8)
            storage.set(data, forKey: legacy)
            let before = PreferencesStore.loadPreferences(storage: storage)
            var next = before
            next.keepScreenAwake = true
            next.hapticsEnabled = true
            next.recordConfirmationEnabled = false
            PreferencesStore.save(next, previous: before, storage: storage)
            #expect(storage.data(forKey: legacy) == data)
            #expect(storage.object(forKey: awake) as? Bool == true)
            #expect(storage.object(forKey: record) as? Bool == false)
            #expect(storage.object(forKey: haptics) as? Bool == true)
            #expect(PreferencesStore.loadPreferences(storage: storage) == next)
        }
    }

    @Test func nikonEditsRetainUnknownLegacyFieldsAndExistingCommonOwnership() throws {
        try withStorage { storage in
            let data = Data(
                #"{"keepScreenAwake":false,"streamPreset":"future-stream","scopeActivationOrder":["PLAY","FUTURE","MAG"],"displayChrome":{"futureStyle":{"gain":7},"statusBarVisible":false},"future":[1,2,3]}"#
                    .utf8)
            storage.set(data, forKey: legacy)
            storage.set(true, forKey: awake)
            let before = PreferencesStore.loadPreferences(storage: storage)
            var next = before
            next.relayWatcherPasscode = "6203"
            next.displayChrome.statusBarVisible = true
            PreferencesStore.save(next, previous: before, storage: storage)
            let saved = try #require(storage.data(forKey: legacy))
            let raw = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            #expect(raw["streamPreset"] as? String == "future-stream")
            #expect(raw["keepScreenAwake"] as? Bool == false)
            #expect(raw["scopeActivationOrder"] as? [String] == ["PLAY", "FUTURE", "MAG"])
            #expect(raw["future"] as? [Int] == [1, 2, 3])
            let chrome = try #require(raw["displayChrome"] as? [String: Any])
            #expect((chrome["futureStyle"] as? [String: Int])?["gain"] == 7)
            #expect(chrome["statusBarVisible"] as? Bool == true)
            #expect(PreferencesStore.loadPreferences(storage: storage) == next)
        }
    }

    @Test func malformedLegacySurvivesCommonEditsWithoutWritingUnsupportedKeys() throws {
        try withStorage { storage in
            let data = Data("{bad-json".utf8)
            storage.set(data, forKey: legacy)
            let before = PreferencesStore.loadPreferences(storage: storage)
            #expect(storage.object(forKey: awake) == nil)
            #expect(storage.object(forKey: record) == nil)
            #expect(storage.object(forKey: haptics) == nil)
            var next = before
            next.keepScreenAwake = false
            next.hapticsEnabled = false
            PreferencesStore.save(next, previous: before, storage: storage)
            #expect(storage.data(forKey: legacy) == data)
            #expect(!PreferencesStore.loadPreferences(storage: storage).keepScreenAwake)
            #expect(!PreferencesStore.loadPreferences(storage: storage).hapticsEnabled)
            #expect(storage.object(forKey: "OpenZCine.HDRDisplay") == nil)
            #expect(storage.object(forKey: "OpenZCine.CacheFullResolution") == nil)
        }
    }

    /// Product ruling 2026-10-16: the remote shutter moves to the shared key once. The operator's
    /// stored choice carries over and the retired blob field is removed after it was read.
    @Test func storedRemoteShutterChoiceMovesToTheSharedKeyOnceAndLeavesTheBlob() throws {
        try withStorage { storage in
            storage.set(
                Data(
                    #"{"bluetoothShutterEnabled":false,"hapticsEnabled":false,"future":[1,2,3]}"#
                        .utf8), forKey: legacy)
            let loaded = PreferencesStore.loadPreferences(storage: storage)
            #expect(!loaded.bluetoothShutterEnabled)
            #expect(storage.object(forKey: remote) as? Bool == false)
            let fields = try legacyFields(storage)
            #expect(fields["bluetoothShutterEnabled"] == nil)
            #expect(fields["hapticsEnabled"] as? Bool == false)
            #expect(fields["future"] as? [Int] == [1, 2, 3])
            let snapshot = storage.dictionaryRepresentation() as NSDictionary
            #expect(PreferencesStore.loadPreferences(storage: storage) == loaded)
            #expect(
                snapshot.isEqual(to: storage.dictionaryRepresentation()),
                "A second launch changes nothing")
        }
    }

    @Test func withoutAStoredRemoteShutterChoiceTheSharedDefaultAppliesAndNothingIsWritten() throws
    {
        try withStorage { storage in
            let data = Data(#"{"hapticsEnabled":false}"#.utf8)
            storage.set(data, forKey: legacy)
            let before = PreferencesStore.loadPreferences(storage: storage)
            #expect(before.bluetoothShutterEnabled)
            #expect(storage.object(forKey: remote) == nil)
            #expect(storage.data(forKey: legacy) == data)
            var next = before
            next.bluetoothShutterEnabled = false
            PreferencesStore.save(next, previous: before, storage: storage)
            #expect(storage.object(forKey: remote) as? Bool == false)
            #expect(storage.data(forKey: legacy) == data, "The shared key owns the choice now")
            #expect(PreferencesStore.loadPreferences(storage: storage) == next)
        }
    }

    @Test func anAlreadyMigratedChoiceWinsOverAStaleBlobFieldWhichIsRemoved() throws {
        try withStorage { storage in
            storage.set(
                Data(#"{"bluetoothShutterEnabled":true,"relayWatcherPasscode":"6203"}"#.utf8),
                forKey: legacy)
            storage.set(false, forKey: remote)
            let loaded = PreferencesStore.loadPreferences(storage: storage)
            #expect(!loaded.bluetoothShutterEnabled)
            #expect(storage.object(forKey: remote) as? Bool == false)
            let fields = try legacyFields(storage)
            #expect(fields["bluetoothShutterEnabled"] == nil)
            #expect(fields["relayWatcherPasscode"] as? String == "6203")
            #expect(!PreferencesStore.loadPreferences(storage: storage).bluetoothShutterEnabled)
        }
    }

    @Test func nikonEditsOnAFreshInstallNeverWriteTheRetiredRemoteShutterField() throws {
        try withStorage { storage in
            let before = PreferencesStore.loadPreferences(storage: storage)
            var next = before
            next.relayWatcherPasscode = "6203"
            PreferencesStore.save(next, previous: before, storage: storage)
            let fields = try legacyFields(storage)
            #expect(fields["bluetoothShutterEnabled"] == nil)
            #expect(storage.object(forKey: remote) == nil)
            #expect(PreferencesStore.loadPreferences(storage: storage) == next)
        }
    }

    @Test func unreadableRetiredShutterSurvivesAnExistingSharedChoice() throws {
        try withStorage { storage in
            let data = Data(#"{"bluetoothShutterEnabled":"future","future":[1,2,3]}"#.utf8)
            storage.set(data, forKey: legacy)
            storage.set(false, forKey: remote)
            #expect(!PreferencesStore.loadPreferences(storage: storage).bluetoothShutterEnabled)
            #expect(storage.data(forKey: legacy) == data)
            #expect(storage.object(forKey: remote) as? Bool == false)
        }
    }

    @Test func unrelatedEditsPreserveAnUnreadableRetiredShutter() throws {
        try withStorage { storage in
            let data = Data(#"{"bluetoothShutterEnabled":"future","future":[1,2,3]}"#.utf8)
            storage.set(data, forKey: legacy)
            let before = PreferencesStore.loadPreferences(storage: storage)
            #expect(before.bluetoothShutterEnabled)
            #expect(storage.data(forKey: legacy) == data)
            var next = before
            next.relayWatcherPasscode = "SIMULATED-preserved"
            PreferencesStore.save(next, previous: before, storage: storage)
            let fields = try legacyFields(storage)
            #expect(fields["bluetoothShutterEnabled"] as? String == "future")
            #expect(fields["future"] as? [Int] == [1, 2, 3])
            #expect(fields["relayWatcherPasscode"] as? String == "SIMULATED-preserved")
            #expect(storage.object(forKey: remote) == nil)
            #expect(PreferencesStore.loadPreferences(storage: storage) == next)
        }
    }
}
