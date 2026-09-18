import Foundation

/// Production permission checks must come from the installed app, never a build copy.
enum RuntimeIdentity {
    static func isInstalled(bundlePath: String, home: String) -> Bool {
        let path = URL(fileURLWithPath: bundlePath).standardizedFileURL.resolvingSymlinksInPath().path
        return [home + "/Applications/Undertone.app", "/Applications/Undertone.app"]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            .contains(path)
    }
}
