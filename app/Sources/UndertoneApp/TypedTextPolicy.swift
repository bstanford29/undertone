import Foundation

/// What the local typing path may send as Unicode key events.
///
/// A typed line break acts as Return. In a chat app Return sends the
/// message, and in a terminal it runs the line. Other control characters
/// act as keys too: Tab moves focus, Escape cancels. So typed text keeps
/// line breaks only in apps where Return starts a new line, and never
/// carries any other control character. History keeps the original text.
///
/// The remote-desktop path has its own rule: it refuses text that needs
/// Return or Tab. See `RemoteDesktopTyping.canDeliver`.
enum TypedTextPolicy {
    /// Apps where Return in the body starts a new line or paragraph.
    static let lineBreakBundleIDs: Set<String> = [
        "com.apple.mail",
        "com.apple.Notes",
        "com.apple.TextEdit",
        "com.apple.iWork.Pages",
        "com.microsoft.Word",
        "md.obsidian",
    ]

    static func allowsLineBreaks(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return lineBreakBundleIDs.contains(bundleID)
    }

    /// `text` made safe to type into the app with `bundleID`.
    ///
    /// - Every line break (`\n`, `\r`, `\r\n`, U+0085, U+2028, U+2029)
    ///   becomes `\n` in a line-break app. Anywhere else, a run of line
    ///   breaks and the spaces around it becomes one space, so words stay
    ///   apart. A leading break also becomes one space: a streamed chunk
    ///   carries its separator at the front.
    /// - Tab becomes a space.
    /// - Every other control character is dropped.
    ///
    /// Words are never removed, so the content rule still holds.
    static func sanitized(_ text: String, bundleID: String?) -> String {
        let keepLineBreaks = allowsLineBreaks(bundleID: bundleID)
        var result = ""
        var inBreak = false
        for character in text {
            if character.isNewline {
                if keepLineBreaks {
                    result.append("\n")
                } else if !inBreak {
                    while result.last == " " { result.removeLast() }
                    result.append(" ")
                    inBreak = true
                }
                continue
            }
            let isControl = character.unicodeScalars.contains { $0.properties.generalCategory == .control }
            let kept: Character
            if character == "\t" {
                kept = " "
            } else if isControl {
                continue
            } else {
                kept = character
            }
            if inBreak, kept == " " { continue }
            inBreak = false
            result.append(kept)
        }
        return result
    }
}
