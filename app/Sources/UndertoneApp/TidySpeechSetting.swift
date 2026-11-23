import Foundation

/// The brain-dump tidy pass for Medium and High cleanup. It is stored in the
/// engine's local config. It is on unless the config says otherwise, matching
/// the engine's default. History keeps the raw transcript either way.
enum TidySpeechSetting {
    static let key = "tidy_speech"
    static let defaultValue = true

    static func value(from config: [String: JSONValue]) -> Bool {
        guard case .bool(let value) = config[key] else { return defaultValue }
        return value
    }
}
