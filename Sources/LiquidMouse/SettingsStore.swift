import CoreFoundation
import Foundation

/// Keeps the settings between launches.
///
/// Settings are stored as JSON and laid over the defaults when read back, key by key: a setting added in a later
/// version simply takes its default, instead of making the whole saved set unreadable.
enum SettingsStore {
    private static let settingsKey = "settings"
    private static let enabledKey = "enabled"

    static var hasSavedSettings: Bool { UserDefaults.standard.data(forKey: settingsKey) != nil }

    static func load() -> Engine.Settings {
        UserDefaults.standard.data(forKey: settingsKey).flatMap(settings(from:)) ?? Engine.Settings()
    }

    /// The settings in `saved`, laid over the defaults; nil when it is not a set of settings at all.
    static func settings(from saved: Data) -> Engine.Settings? {
        guard let savedObject = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(Engine.Settings()),
              let defaultsObject = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: overlay(savedObject, on: defaultsObject))
        else { return nil }
        guard var settings = try? JSONDecoder().decode(Engine.Settings.self, from: merged) else { return nil }
        // Persisted values can come from older builds or manual edits. Keep the renderer and sliders within
        // the same supported ranges as the settings panel, without discarding unrelated preferences.
        settings.body.dotRadius = min(max(settings.body.dotRadius, 4), 20)
        settings.body.trailLength = min(max(settings.body.trailLength, 0), 400)
        settings.body.trailResponse = min(max(settings.body.trailResponse, 20), 240)
        settings.body.bounce = min(max(settings.body.bounce, 0), 1)
        settings.stillDelay = min(max(settings.stillDelay, 1), 30)
        return settings
    }

    static func save(_ settings: Engine.Settings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// `saved` on top of `defaults`, descending into nested groups; values of the wrong kind are ignored.
    static func overlay(_ saved: [String: Any], on defaults: [String: Any]) -> [String: Any] {
        var result = defaults
        for (key, value) in saved where defaults[key] != nil {
            if let nested = value as? [String: Any], let base = defaults[key] as? [String: Any] {
                result[key] = overlay(nested, on: base)
            } else if let base = defaults[key], sameKind(value, base) {
                result[key] = value
            }
        }
        return result
    }

    private static func sameKind(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? NSNumber, let b = b as? NSNumber {
            // Foundation bridges JSON booleans and numbers to NSNumber, but Codable keeps them distinct.
            return (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID())
        }
        return (a is String && b is String) || (a is [String] && b is [String])
    }
}
