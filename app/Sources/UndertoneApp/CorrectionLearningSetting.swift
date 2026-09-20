import Foundation

/// The opt-in setting is stored in the engine's local config alongside the
/// other app settings. Keeping the key and default in one place makes an
/// absent setting safely resolve to OFF during upgrades.
enum CorrectionLearningSetting {
    static let key = "learn_from_corrections"
    static let defaultValue = false

    static func value(from config: [String: JSONValue]) -> Bool {
        guard case .bool(let value) = config[key] else { return defaultValue }
        return value
    }
}
