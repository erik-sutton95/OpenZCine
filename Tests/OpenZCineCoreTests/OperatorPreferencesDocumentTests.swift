import Foundation
import Testing

@testable import OpenZCineCore

@Suite struct OperatorPreferencesDocumentTests {
    private func fixture() throws -> Data {
        var raw = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(OperatorPreferences.defaults)) as? [String: Any])
        raw["hapticsEnabled"] = false
        raw["keepScreenAwake"] = false
        raw["streamPreset"] = "future-stream"
        raw["portraitFeedAspect"] = "future-aspect"
        raw["scopeActivationOrder"] = ["WAVE", "FUTURE", "PLAY", "MAG"]
        raw["futureSetting"] = ["modes": ["alpha", "beta"], "level": 4]
        var chrome = try #require(raw["displayChrome"] as? [String: Any])
        chrome["futureStyle"] = ["color": "amber", "gain": 3]
        raw["displayChrome"] = chrome
        return try JSONSerialization.data(
            withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
    }

    @Test func loadingAndNoOpUpdateKeepOriginalBytes() throws {
        let original = try fixture()
        let document = OperatorPreferencesDocument(data: original)
        let current = document.decoded()
        #expect(!current.hapticsEnabled)
        #expect(!current.keepScreenAwake)
        #expect(current.scopeActivationOrder.contains(.instantReview))
        #expect(!current.scopeActivationOrder.contains(.magnification))
        #expect(document.data == original)
        #expect(try document.updating(current, previous: current) == original)
    }

    @Test func changingNikonMembersKeepsUnknownEnumsAndNestedData() throws {
        let original = try fixture()
        let document = OperatorPreferencesDocument(data: original)
        let previous = document.decoded()
        var next = previous
        next.autoRotateFeedEnabled = !previous.autoRotateFeedEnabled
        next.displayChrome.statusBarVisible = !previous.displayChrome.statusBarVisible
        let updated = try document.updating(next, previous: previous)
        let raw = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let before = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        #expect(raw["streamPreset"] as? String == "future-stream")
        #expect(raw["portraitFeedAspect"] as? String == "future-aspect")
        #expect(raw["scopeActivationOrder"] as? [String] == ["WAVE", "FUTURE", "PLAY", "MAG"])
        #expect(
            NSDictionary(dictionary: try #require(raw["futureSetting"] as? [String: Any]))
                .isEqual(to: try #require(before["futureSetting"] as? [String: Any])))
        let chrome = try #require(raw["displayChrome"] as? [String: Any])
        #expect(
            NSDictionary(dictionary: try #require(chrome["futureStyle"] as? [String: Any]))
                .isEqual(to: ["color": "amber", "gain": 3]))
        #expect(chrome["statusBarVisible"] as? Bool == next.displayChrome.statusBarVisible)
        #expect(raw["autoRotateFeedEnabled"] as? Bool == next.autoRotateFeedEnabled)
        #expect(document.data == original)
    }

    @Test func editingKnownArrayMembersRetainsUnknownAndRetiredRawMembers() throws {
        let document = OperatorPreferencesDocument(data: try fixture())
        let previous = document.decoded()
        var next = previous
        next.scopeActivationOrder = [.histogram, .waveform]
        let raw = try #require(
            JSONSerialization.jsonObject(
                with: document.updating(next, previous: previous)) as? [String: Any])
        let values = try #require(raw["scopeActivationOrder"] as? [String])
        #expect(values.filter { ["HISTO", "WAVE"].contains($0) } == ["HISTO", "WAVE"])
        #expect(values.contains("FUTURE"))
        #expect(values.contains("MAG"))
    }

    @Test func malformedDocumentSurvivesAndRejectsReplacement() throws {
        let original = Data("{malformed document".utf8)
        let document = OperatorPreferencesDocument(data: original)
        let previous = document.decoded()
        #expect(previous == .defaults)
        #expect(document.data == original)
        #expect(try document.updating(previous, previous: previous) == original)
        var next = previous
        next.relayWatcherPasscode = "6203"
        #expect(throws: (any Error).self) {
            try document.updating(next, previous: previous)
        }
        #expect(document.data == original)
    }

    @Test(arguments: ["statusBar", "sideRails"])
    func editingLegacyChromePreservesUntouchedInheritedChoices(field: String) throws {
        let original = Data(
            #"{"displayChrome":{"statusBarVisible":false,"sideRailsVisible":false,"futureStyle":{"gain":7}},"futureSetting":"retain"}"#
                .utf8)
        let document = OperatorPreferencesDocument(data: original)
        let previous = document.decoded()
        var next = previous
        if field == "statusBar" {
            next.displayChrome.statusBarVisible = true
        } else {
            next.displayChrome.sideRailsVisible = true
        }
        let updated = try document.updating(next, previous: previous)
        #expect(
            OperatorPreferencesDocument(data: updated).decoded() == next,
            "Changing one legacy layout must preserve the other inherited layouts and rail choices")
        let raw = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(raw["futureSetting"] as? String == "retain")
        let chrome = try #require(raw["displayChrome"] as? [String: Any])
        #expect((chrome["futureStyle"] as? [String: Int])?["gain"] == 7)
    }

    @Test func nullLegacyLayoutsKeepTheirInheritedChoicesAfterParentEdit() throws {
        let original = Data(
            #"{"displayChrome":{"statusBarVisible":false},"commandChrome":null,"photoDisplayChrome":null,"photoCommandChrome":null,"futureSetting":null}"#
                .utf8)
        let document = OperatorPreferencesDocument(data: original)
        let previous = document.decoded()
        var next = previous
        next.displayChrome.statusBarVisible = true
        let updated = try document.updating(next, previous: previous)
        #expect(OperatorPreferencesDocument(data: updated).decoded() == next)
        let raw = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(raw["futureSetting"] is NSNull)
    }

    @Test func editingAnInheritedVideoCommandLayoutKeepsItsPhotoSibling() throws {
        let original = Data(
            #"{"displayChrome":{"statusBarVisible":false,"sideRailsVisible":false},"futureSetting":"retain"}"#
                .utf8)
        let document = OperatorPreferencesDocument(data: original)
        let previous = document.decoded()
        var next = previous
        next.commandChrome.statusBarVisible = true
        let updated = try document.updating(next, previous: previous)
        #expect(
            OperatorPreferencesDocument(data: updated).decoded() == next,
            "Editing one inherited layout must keep the photo layout that inherited from it")
        let raw = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(raw["futureSetting"] as? String == "retain")
    }

    @Test func unreadableLayoutsAndRailsKeepTheirInheritedChoicesAfterParentEdit() throws {
        let original = Data(
            #"{"displayChrome":{"sideRailsVisible":false,"railRecordVisible":"yes","futureStyle":{"gain":7}},"commandChrome":"corrupt","photoDisplayChrome":7,"futureSetting":"retain"}"#
                .utf8)
        let document = OperatorPreferencesDocument(data: original)
        let previous = document.decoded()
        var next = previous
        next.displayChrome.sideRailsVisible = true
        let updated = try document.updating(next, previous: previous)
        #expect(
            OperatorPreferencesDocument(data: updated).decoded() == next,
            "An unreadable stored value inherits like an absent one, so a parent edit must not move it"
        )
        let raw = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(raw["futureSetting"] as? String == "retain")
        let chrome = try #require(raw["displayChrome"] as? [String: Any])
        #expect((chrome["futureStyle"] as? [String: Int])?["gain"] == 7)
    }

    @Test func untouchedChoicesOwnedElsewhereKeepTheirStoredBytes() throws {
        // The app overlays choices that now live in shared keys onto the decoded document, so
        // `previous` can differ from the document; an unrelated edit must not write them back.
        let original = Data(
            #"{"displayChrome":{"sideRailsVisible":false},"hapticsEnabled":true}"#.utf8)
        let document = OperatorPreferencesDocument(data: original)
        var previous = document.decoded()
        previous.keepScreenAwake = false
        previous.hapticsEnabled = false
        var next = previous
        next.displayChrome.statusBarVisible = false
        let updated = try document.updating(next, previous: previous)
        let raw = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(raw["keepScreenAwake"] == nil)
        #expect(raw["hapticsEnabled"] as? Bool == true)
        var expected = next
        expected.keepScreenAwake = true
        expected.hapticsEnabled = true
        #expect(OperatorPreferencesDocument(data: updated).decoded() == expected)
    }
}
