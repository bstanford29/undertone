import AppKit
import SwiftUI

/// The badge that tells the nudge card apart at a glance: Teams is not Zoom.
/// It shows the call app's own icon when macOS can find it, and falls back to
/// the platform color with a distinct glyph when it cannot.
extension MeetingPlatform {
    /// The brand color used behind the fallback glyph.
    var badgeColor: Color {
        switch self {
        case .zoom: return Color(red: 0.18, green: 0.55, blue: 1.00)
        case .teams: return Color(red: 0.31, green: 0.35, blue: 0.79)
        case .meet: return Color(red: 0.00, green: 0.54, blue: 0.24)
        case .facetime: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .webex: return Color(red: 0.00, green: 0.74, blue: 0.92)
        case .slack: return Color(red: 0.29, green: 0.08, blue: 0.29)
        case .unknown: return Color(white: 0.45)
        }
    }

    /// The SF Symbol drawn on the fallback badge.
    var badgeSymbol: String {
        switch self {
        case .zoom: return "video.fill"
        case .teams: return "person.2.fill"
        case .meet: return "video.fill"
        case .facetime: return "video.fill"
        case .webex: return "video.fill"
        case .slack: return "number"
        case .unknown: return "video"
        }
    }
}

/// Reads an app icon out of the bundle, once per bundle id.
@MainActor
enum MeetingAppIcon {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image
        return image
    }
}

/// A 28 point rounded square. The app's own icon when there is one, otherwise
/// the platform color plus a glyph. Browser calls get a small corner pip in
/// the service color, so Meet in Chrome does not read as plain Chrome.
struct MeetingBadgeView: View {
    let detected: DetectedMeeting
    var size: CGFloat = 28

    /// Both read the detector's answer. Re-deriving them here would let the
    /// badge drift away from the call the detector is actually tracking.
    private var platform: MeetingPlatform { detected.platform }
    private var isBrowser: Bool { detected.browserName != nil }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon = MeetingAppIcon.icon(for: detected.bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size, height: size)
                } else {
                    RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                        .fill(platform.badgeColor)
                        .frame(width: size, height: size)
                        .overlay(
                            Image(systemName: platform.badgeSymbol)
                                .font(.system(size: size * 0.55, weight: .medium))
                                .foregroundStyle(.white)
                        )
                }
            }
            if isBrowser {
                Circle()
                    .fill(platform.badgeColor)
                    .frame(width: size * 0.43, height: size * 0.43)
                    .overlay(Circle().strokeBorder(Color(red: 0.067, green: 0.067, blue: 0.067), lineWidth: 1.5))
                    .offset(x: size * 0.11, y: size * 0.11)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
