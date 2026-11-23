import Foundation

/// Times shown to a person, to the whole second at most. The engine measures
/// in milliseconds, but no label, list, or spoken description shows them.
enum TimeText {
    /// A short duration label: "<1 s", "2 s", "1 min 5 s".
    static func duration(milliseconds: Double) -> String {
        guard milliseconds.isFinite, milliseconds > 0 else { return "0 s" }
        if milliseconds < 1000 { return "<1 s" }
        let total = Int((milliseconds / 1000).rounded())
        if total < 60 { return "\(total) s" }
        let seconds = total % 60
        return seconds == 0 ? "\(total / 60) min" : "\(total / 60) min \(seconds) s"
    }

    /// The same duration for VoiceOver: "under a second", "1 second", "12 seconds".
    static func spokenDuration(milliseconds: Double) -> String {
        guard milliseconds.isFinite, milliseconds > 0 else { return "0 seconds" }
        if milliseconds < 1000 { return "under a second" }
        let total = Int((milliseconds / 1000).rounded())
        return total == 1 ? "1 second" : "\(total) seconds"
    }
}
