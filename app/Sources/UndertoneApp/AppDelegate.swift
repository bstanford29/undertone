import AppKit
import SwiftUI
import Combine
import AVFoundation
import ApplicationServices
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var statusItem: NSStatusItem!
    private var pill: PillPanelController!
    private var quickNote: QuickNotePanelController!
    private var meetingPanel: MeetingRecordingPanelController!
    private var statusMenuItem: NSMenuItem!
    private var batteryMenuItem: NSMenuItem!
    private var cleanupMenuItem: NSMenuItem!
    private var meetingMenuItem: NSMenuItem!
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        let args = CommandLine.arguments
        let preview = args.contains("--preview") || Bundle.main.bundleIdentifier?.hasPrefix("com.undertone.preview") == true
        if let index = args.firstIndex(of: "--socket"), args.indices.contains(index + 1) {
            model = AppModel(socketPath: args[index + 1], previewMode: preview)
        } else { model = AppModel(previewMode: preview) }
        super.init()
    }

    /// The appearance named by `--appearance`, so the capture background
    /// matches the screen instead of guessing.
    private static func requestedAppearance() -> NSAppearance? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--appearance"),
              arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1].lowercased() {
        case "dark": return NSAppearance(named: .darkAqua)
        case "light": return NSAppearance(named: .aqua)
        default: return nil
        }
    }

    /// Preview only: writes a PNG of the preview window, then quits. The app
    /// draws its own window, so this needs no Screen Recording permission and
    /// makes the light and dark screenshots repeatable.
    private func capturePreview(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            defer { NSApp.terminate(nil) }
            guard let window = NSApp.windows.first(where: { $0.title == "Undertone Preview" }),
                  let view = window.contentView,
                  let content = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: content)
            // cacheDisplay draws the views only, so the window background is
            // added underneath. Without it a dark capture comes out white.
            guard let output = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: content.pixelsWide, pixelsHigh: content.pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            // The size must be set before the context is made, or drawing lands
            // in pixel coordinates and fills a quarter of the image.
            output.size = view.bounds.size
            guard let context = NSGraphicsContext(bitmapImageRep: output) else { return }
            let frame = NSRect(origin: .zero, size: view.bounds.size)
            let requested = Self.requestedAppearance() ?? view.effectiveAppearance
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            requested.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath.fill(frame)
            }
            // A bitmap context composites with .copy by default, which would
            // punch the transparent parts of the view back out of the fill.
            content.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = output.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(model.previewMode ? .accessory : .regular)
        if CommandLine.arguments.contains("--check-permissions") {
            let microphone: String
            switch AVAudioApplication.shared.recordPermission {
            case .granted: microphone = "granted"
            case .denied: microphone = "denied"
            default: microphone = "not_determined"
            }
            let result: [String: Any] = ["microphone": microphone, "accessibility": AXIsProcessTrusted(), "input_monitoring": CGPreflightListenEventAccess()]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
            NSApp.terminate(nil)
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--appearance"), CommandLine.arguments.indices.contains(index + 1) {
            switch CommandLine.arguments[index + 1].lowercased() {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
        }
        meetingPanel = MeetingRecordingPanelController(model: model)
        if model.previewMode {
            model.openWindow("Undertone Preview") { PreviewView() }
            if let index = CommandLine.arguments.firstIndex(of: "--capture"),
               CommandLine.arguments.indices.contains(index + 1) {
                capturePreview(to: CommandLine.arguments[index + 1])
            }
            return
        }
        guard RuntimeIdentity.isInstalled(bundlePath: Bundle.main.bundleURL.path,
                                          home: FileManager.default.homeDirectoryForCurrentUser.path) else {
            let alert = NSAlert()
            alert.messageText = "Open the installed Undertone app"
            alert.informativeText = "This is a development copy. Open Undertone from Applications so macOS permissions apply to the correct app."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        pill = PillPanelController(model: model)
        quickNote = QuickNotePanelController(model: model)
        model.onQuickNoteToggle = { [weak self] in self?.quickNote.toggle() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Undertone")
        statusItem.menu = makeMenu()
        model.$statusText.receive(on: RunLoop.main).sink { [weak self] value in self?.statusMenuItem?.title = value }.store(in: &subscriptions)
        model.$slowerOnBattery.receive(on: RunLoop.main).sink { [weak self] slower in
            self?.batteryMenuItem?.isHidden = !slower
        }.store(in: &subscriptions)
        model.$cleanupLevel.receive(on: RunLoop.main).sink { [weak self] value in self?.cleanupMenuItem?.title = "Cleanup: \(value.capitalized)" }.store(in: &subscriptions)
        model.meetings.$state.receive(on: RunLoop.main).sink { [weak self] state in
            self?.updateMeetingMenu(state)
        }.store(in: &subscriptions)
        updateMeetingMenu(model.meetings.state)
        model.start()
        showInitialWindow()
    }

    /// Opens straight to Permissions, once, when the globe key still runs
    /// its system action (stealing fn's bare tap from Undertone's
    /// hold-to-talk key) and the user has not dismissed the nudge. Marks
    /// the nudge dismissed as soon as it fires, since it is meant to show
    /// exactly once rather than on every qualifying launch.
    private func showInitialWindow() {
        let defaults = UserDefaults.standard
        guard GlobeKeySetting.needsChange, !defaults.bool(forKey: "globeKeyNudgeDismissed") else {
            model.showApp(.home)
            return
        }
        defaults.set(true, forKey: "globeKeyNudgeDismissed")
        model.showApp(.permissions)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !model.previewMode { model.showApp() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !model.previewMode { model.refreshPermissions() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.previewMode else { return .terminateNow }
        guard !model.meetings.state.isRecording else {
            model.statusText = "Stop meeting capture before quitting"
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model.previewMode
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: ""); status.isEnabled = false; statusMenuItem = status; menu.addItem(status)
        let battery = NSMenuItem(title: "Slower on battery", action: nil, keyEquivalent: "")
        battery.isEnabled = false
        battery.isHidden = !model.slowerOnBattery
        batteryMenuItem = battery
        menu.addItem(battery)
        menu.addItem(.separator())
        menu.addItem(item: "Open Undertone…", action: #selector(openHome))
        let cleanup = NSMenuItem(title: "Cleanup: Medium", action: #selector(openSettings), keyEquivalent: ""); cleanup.target = self; cleanupMenuItem = cleanup; menu.addItem(cleanup)
        menu.addItem(item: "Insert last transcript again", action: #selector(insertLast))
        menu.addItem(item: "Undo AI edit, keep raw", action: #selector(insertRaw))
        menu.addItem(item: "Copy last transcript", action: #selector(copyLast))
        menu.addItem(.separator())
        menu.addItem(item: "History…", action: #selector(openHistory), key: "h", modifiers: [.option, .shift])
        menu.addItem(item: "Dictionary…", action: #selector(openDictionary))
        let meeting = NSMenuItem(title: "Start meeting notes", action: #selector(startMeeting), keyEquivalent: "m")
        meeting.keyEquivalentModifierMask = [.option, .shift]
        meeting.target = self
        meetingMenuItem = meeting
        menu.addItem(meeting)
        menu.addItem(item: "Meetings…", action: #selector(openMeetings))
        menu.addItem(item: "Setup…", action: #selector(openSetup))
        menu.addItem(item: "Settings…", action: #selector(openSettings), key: ",", modifiers: [.command])
        menu.addItem(.separator())
        menu.addItem(item: "Quit Undertone", action: #selector(NSApplication.terminate(_:)), key: "q", modifiers: [.command])
        return menu
    }

    @objc private func insertLast() { model.insertLast() }
    @objc private func insertRaw() { model.insertLast(raw: true) }
    @objc private func copyLast() { model.copyLast() }
    @objc func openSettings() { model.showApp(.settings) }
    @objc private func openHome() { model.showApp(.home) }
    @objc private func openHistory() { model.showApp(.history) }
    @objc private func openDictionary() { model.showApp(.dictionary) }
    @objc private func startMeeting() {
        switch model.meetings.state {
        case .recording:
            model.showApp(.meetings)
            model.meetings.stop()
        case .idle, .error:
            model.showApp(.meetings)
            model.meetings.start()
        case .starting, .stopping, .summarizing:
            break
        }
    }
    @objc private func openMeetings() { model.showApp(.meetings) }
    @objc private func openSetup() { model.showApp(.permissions) }
}

private extension AppDelegate {
    func updateMeetingMenu(_ state: MeetingModel.State) {
        guard let meetingMenuItem else { return }
        switch state {
        case .idle, .error:
            meetingMenuItem.title = "Start meeting notes"
            meetingMenuItem.isEnabled = true
        case .starting:
            meetingMenuItem.title = "Preparing meeting…"
            meetingMenuItem.isEnabled = false
        case .recording:
            meetingMenuItem.title = "End meeting notes"
            meetingMenuItem.isEnabled = true
        case .stopping, .summarizing:
            meetingMenuItem.title = "Finalizing meeting…"
            meetingMenuItem.isEnabled = false
        }
    }
}

private extension NSMenu {
    func addItem(item title: String, action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; addItem(item)
    }
}
