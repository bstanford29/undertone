import AppKit
import CoreAudio
import Foundation

/// The tone names Settings shows for `app_prompt_variants`.
/// The engine stores style text per bundle id. Two texts are the presets the
/// engine ships; no entry means Neutral, and any other text is Custom.
enum ToneCatalog {
    enum Tone: String, CaseIterable, Identifiable, Sendable {
        case neutral = "Neutral"
        case casual = "Casual"
        case formal = "Formal"
        case custom = "Custom"

        var id: String { rawValue }
    }

    static let casualText = "Keep the speaker's casual tone and contractions. Preserve every spoken fact and request."
    static let formalText = "Use conventional punctuation and paragraph breaks suitable for email. Preserve the spoken wording and greetings; add no greeting or sign-off."

    /// The engine's own defaults, so Settings is right before config loads.
    static let defaults: [String: String] = [
        "com.apple.MobileSMS": casualText,
        "com.apple.mail": formalText,
    ]

    static func tone(for bundleID: String?, variants: [String: String]) -> Tone {
        guard let bundleID, let text = variants[bundleID]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return .neutral }
        if text == casualText { return .casual }
        if text == formalText { return .formal }
        return .custom
    }

    /// The style text for a preset, or nil for Neutral, which removes the
    /// entry. Custom has no text of its own to write.
    static func text(for tone: Tone) -> String? {
        switch tone {
        case .casual: return casualText
        case .formal: return formalText
        case .neutral, .custom: return nil
        }
    }

    /// `variants` with `bundleID` set to `tone`. Custom leaves it unchanged.
    static func setting(_ tone: Tone, for bundleID: String, in variants: [String: String]) -> [String: String] {
        var result = variants
        switch tone {
        case .neutral: result.removeValue(forKey: bundleID)
        case .casual, .formal: result[bundleID] = text(for: tone)
        case .custom: break
        }
        return result
    }

    private static let knownNames: [String: String] = [
        "com.apple.MobileSMS": "Messages",
        "com.apple.mail": "Mail",
        "com.openai.codex": "Codex",
        "com.anthropic.claudefordesktop": "Claude",
        "com.mitchellh.ghostty": "Ghostty",
        "com.apple.Notes": "Notes",
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Chrome",
        "com.tinyspeck.slackmacgap": "Slack",
    ]

    /// A short app name for a bundle id: the running app's own name, the
    /// installed app's name, or the last part of the id.
    @MainActor
    static func appName(for bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName, !name.isEmpty {
            return name
        }
        if let known = knownNames[bundleID] { return known }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init)
    }

    /// The same lookup without a running app, for tests and previews.
    static func fallbackName(for bundleID: String) -> String {
        knownNames[bundleID] ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

/// The Mac's audio input devices, read from Core Audio. Undertone records
/// from the system default input; it does not pick its own device yet, so
/// this list is shown, not chosen from.
enum AudioInputDevices {
    struct Device: Equatable, Identifiable, Sendable {
        let id: AudioDeviceID
        let name: String
        let isDefault: Bool
    }

    static func all() -> [Device] {
        let defaultID = defaultInputID()
        return deviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0, let name = name(of: id) else { return nil }
            return Device(id: id, name: name, isDefault: id == defaultID)
        }
    }

    static func defaultInputName() -> String? {
        guard let id = defaultInputID() else { return nil }
        return name(of: id)
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }
}

/// The right-click Flow menu, described as data so its items can be tested
/// without popping a real menu.
enum FlowMenu {
    enum Command: Equatable, Sendable {
        case insertLast
        case copyLast
        case setCleanup(String)
        case openSoundSettings
        case hideForAnHour
        case openSettings
    }

    indirect enum Entry: Equatable, Sendable {
        case item(title: String, key: String, modifiers: NSEvent.ModifierFlags.RawValue, command: Command?,
                  checked: Bool, enabled: Bool)
        case submenu(title: String, detail: String?, entries: [Entry])
        case separator
    }

    static let cleanupLevels: [(id: String, title: String)] = [
        ("none", "None"), ("light", "Light"), ("medium", "Medium"), ("high", "High"),
    ]

    private static let optionShift = NSEvent.ModifierFlags([.option, .shift]).rawValue

    static func entries(cleanupLevel: String, microphones: [AudioInputDevices.Device]) -> [Entry] {
        let defaultMic = microphones.first(where: \.isDefault)?.name
        var micEntries: [Entry] = microphones.map {
            .item(title: $0.name, key: "", modifiers: 0, command: nil, checked: $0.isDefault, enabled: false)
        }
        if micEntries.isEmpty {
            micEntries.append(.item(title: "No input device", key: "", modifiers: 0, command: nil,
                                    checked: false, enabled: false))
        }
        micEntries += [
            .separator,
            .item(title: "Sound Settings…", key: "", modifiers: 0, command: .openSoundSettings,
                  checked: false, enabled: true),
        ]
        let cleanupEntries: [Entry] = cleanupLevels.map { level in
            .item(title: level.title, key: "", modifiers: 0, command: .setCleanup(level.id),
                  checked: level.id == cleanupLevel, enabled: true)
        }
        let cleanupTitle = cleanupLevels.first(where: { $0.id == cleanupLevel })?.title
        return [
            .item(title: "Insert last again", key: "v", modifiers: optionShift, command: .insertLast,
                  checked: false, enabled: true),
            .item(title: "Copy last transcript", key: "c", modifiers: optionShift, command: .copyLast,
                  checked: false, enabled: true),
            .separator,
            .submenu(title: "Microphone", detail: defaultMic, entries: micEntries),
            .submenu(title: "Cleanup", detail: cleanupTitle, entries: cleanupEntries),
            .separator,
            .item(title: "Hide for an hour", key: "", modifiers: 0, command: .hideForAnHour,
                  checked: false, enabled: true),
            .item(title: "Settings…", key: ",", modifiers: NSEvent.ModifierFlags.command.rawValue,
                  command: .openSettings, checked: false, enabled: true),
        ]
    }
}

/// Builds the real `NSMenu` from `FlowMenu` entries and runs the chosen
/// command through one closure.
@MainActor
final class FlowMenuBuilder: NSObject {
    private let perform: (FlowMenu.Command) -> Void
    private var commands: [Int: FlowMenu.Command] = [:]

    init(perform: @escaping (FlowMenu.Command) -> Void) {
        self.perform = perform
    }

    func menu(for entries: [FlowMenu.Entry]) -> NSMenu {
        commands = [:]
        return build(entries)
    }

    private func build(_ entries: [FlowMenu.Entry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .submenu(let title, let detail, let children):
                let item = NSMenuItem(title: detail.map { "\(title): \($0)" } ?? title, action: nil, keyEquivalent: "")
                item.submenu = build(children)
                menu.addItem(item)
            case .item(let title, let key, let modifiers, let command, let checked, let enabled):
                let item = NSMenuItem(title: title, action: command == nil ? nil : #selector(choose(_:)),
                                      keyEquivalent: key)
                item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: modifiers)
                item.state = checked ? .on : .off
                item.isEnabled = enabled
                if let command {
                    item.target = self
                    item.tag = commands.count + 1
                    commands[item.tag] = command
                }
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let command = commands[sender.tag] else { return }
        perform(command)
    }
}
