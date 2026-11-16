import Foundation
import Testing
@testable import LiquidMouse

@Suite struct SettingsStoreTests {
    @Test func savedValuesAreLaidOverTheDefaults() {
        let defaults: [String: Any] = ["size": 6.5, "name": "dot", "group": ["on": true, "length": 160.0]]
        let saved: [String: Any] = ["size": 9.0, "name": 3, "group": ["length": 80.0], "removed": 1]
        let merged = SettingsStore.overlay(saved, on: defaults)
        #expect(merged["size"] as? Double == 9)
        // A value of the wrong kind keeps the default instead of breaking the whole set.
        #expect(merged["name"] as? String == "dot")
        let group = merged["group"] as? [String: Any]
        #expect(group?["on"] as? Bool == true)
        #expect(group?["length"] as? Double == 80)
        #expect(merged["removed"] == nil)
    }

    @Test func settingsSavedByAnOlderVersionStillLoad() throws {
        // An early build called the color "look" and had a single "fades when idle" switch.
        let old = Data(#"{"body": {"look": "light", "trailLength": 120, "dotRadius": 8}, "fadesWhenIdle": false}"#.utf8)
        let settings = try #require(SettingsStore.settings(from: old))
        #expect(settings.body.trailLength == 120)
        #expect(settings.body.dotRadius == 8)
        #expect(settings.body.appearance == .automatic)
        #expect(settings.hidesWhenStill == Engine.Settings().hidesWhenStill)
    }

    /// A later version may add a form, a look or a hiding choice: going back to this one keeps everything else.
    @Test func anUnknownChoiceFallsBackWithoutLosingTheRest() throws {
        let later = Data(#"{"body": {"form": "drop", "appearance": "neon", "dotRadius": 10}, "hidesWhenStill": "sometimes"}"#.utf8)
        let settings = try #require(SettingsStore.settings(from: later))
        #expect(settings.body.dotRadius == 10)
        #expect(settings.body.form == .arrow)
        #expect(settings.body.appearance == .automatic)
        #expect(settings.hidesWhenStill == .inFullScreen)
    }

    @Test func somethingThatIsNotSettingsIsRejected() {
        #expect(SettingsStore.settings(from: Data("[1, 2]".utf8)) == nil)
        #expect(SettingsStore.settings(from: Data("not json".utf8)) == nil)
    }

    @Test func appExclusionsSurviveSavingAndInvalidListsKeepOtherSettings() throws {
        var settings = Engine.Settings()
        settings.excludedApplicationIDs = ["com.example.editor", "com.example.game"]
        let saved = try JSONEncoder().encode(settings)
        #expect(SettingsStore.settings(from: saved)?.excludedApplicationIDs == settings.excludedApplicationIDs)
        let invalid = Data(#"{"excludedApplicationIDs": [42], "stillDelay": 8}"#.utf8)
        let recovered = try #require(SettingsStore.settings(from: invalid))
        #expect(recovered.excludedApplicationIDs.isEmpty)
        #expect(recovered.stillDelay == 8)
    }

    @Test func numbersAndBooleansCannotInvalidateUnrelatedPreferences() throws {
        let saved = Data(#"{"hidesWhileTyping": 1, "body": {"trailLength": true, "dotRadius": 9, "form": "arrow"}}"#.utf8)
        let settings = try #require(SettingsStore.settings(from: saved))
        #expect(settings.hidesWhileTyping == Engine.Settings().hidesWhileTyping)
        #expect(settings.body.trailLength == LiquidBody.Tuning().trailLength)
        #expect(settings.body.dotRadius == 9)
        #expect(settings.body.form == .arrow)
    }

    @Test func savedNumericSettingsStayWithinTheSupportedRanges() throws {
        let saved = Data(#"{"stillDelay": -3, "body": {"dotRadius": 1e300, "trailLength": -4, "trailResponse": 0, "bounce": 12, "form": "arrow"}}"#.utf8)
        let settings = try #require(SettingsStore.settings(from: saved))
        #expect(settings.stillDelay == 1)
        #expect(settings.body.dotRadius == 20)
        #expect(settings.body.trailLength == 0)
        #expect(settings.body.trailResponse == 20)
        #expect(settings.body.bounce == 1)
        #expect(settings.body.form == .arrow)
    }
}
