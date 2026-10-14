import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// One physical key press on the current keyboard layout: the virtual key
/// code plus the Shift and Option state that make it type one character.
struct LayoutKeyStroke: Equatable {
    let keyCode: CGKeyCode
    let shift: Bool
    let option: Bool
}

/// One key event to post, in order. Modifiers are their own key presses so
/// a viewer that tracks Shift and Option from those events sees them.
struct LayoutKeyPress: Equatable {
    let keyCode: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

/// One character of text bound for a remote-desktop viewer.
enum RemoteTypingStep: Equatable {
    /// A real key press the viewer can forward to the remote computer.
    case key(LayoutKeyStroke)
    /// No key on the current layout types this character in one press (an
    /// emoji, or a letter that needs a dead-key sequence). Delivery must
    /// reject the complete plan before posting any keys; these viewers
    /// cannot reliably forward attached Unicode text.
    case unicode([UInt16])
}

/// How `InsertionController` turns text into keyboard events.
enum KeystrokeMethod: String {
    /// Unicode strings on key code 0, up to 20 UTF-16 units per event. Fast
    /// and layout-independent, and every local app reads the string.
    case unicodeChunks
    /// One real key press per character, found on the current keyboard
    /// layout. Used for remote-desktop viewers.
    case layoutKeys
}

/// Typing into a remote-desktop viewer (Jump Desktop, Windows App, Screen
/// Sharing, and the like). The viewer shows another computer's screen and
/// forwards each key event to it by key code. Jump Desktop's viewer sends
/// USB key codes to its host. The Unicode string that the default
/// `unicodeChunks` method attaches to key code 0 never makes that trip, so
/// the dictated text does not arrive. Apple documents the general case:
/// frameworks "may ignore the Unicode string in a keyboard event and do
/// their own translation based on the virtual keycode". Real key presses
/// from the current layout reach the remote computer the same way physical
/// typing does.
enum RemoteDesktopTyping {
    /// Remote-desktop viewers matched by exact bundle id.
    static let viewerBundleIDs: Set<String> = [
        "com.microsoft.rdc.macos",      // Windows App, formerly Microsoft Remote Desktop
        "com.microsoft.rdc.mac",        // Microsoft Remote Desktop 8
        "com.apple.ScreenSharing",
        "tv.parsec.www",
        "com.realvnc.vncviewer",
        "com.teamviewer.TeamViewer",
        "com.philandro.anydesk",
    ]

    /// Viewer families matched by bundle id prefix. Jump Desktop ships as
    /// `com.p5sys.jump.mac.viewer` (App Store) and `.viewer.web` (direct
    /// download). Its host agent, `com.p5sys.jump.connect`, is not a viewer.
    static let viewerBundleIDPrefixes: [String] = [
        "com.p5sys.jump.mac.viewer",
        "com.edovia.screens",
    ]

    /// Keypad keys are skipped when building the key map. A remote Windows
    /// computer reads keypad keys through Num Lock, and the main keys type
    /// the same characters.
    static let keypadKeyCodes: Set<CGKeyCode> = Set([
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear,
        kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals,
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
    ].map { CGKeyCode($0) })

    /// Left Shift and left Option device bits (`NX_DEVICELSHIFTKEYMASK`,
    /// `NX_DEVICELALTKEYMASK`). A physical key press carries them next to
    /// the generic modifier mask; some viewers read them to tell left from
    /// right.
    static let leftShiftDeviceFlag = CGEventFlags(rawValue: 0x02)
    static let leftOptionDeviceFlag = CGEventFlags(rawValue: 0x20)

    static func isRemoteDesktopViewer(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if viewerBundleIDs.contains(bundleID) { return true }
        return viewerBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    static func keystrokeMethod(bundleID: String?) -> KeystrokeMethod {
        isRemoteDesktopViewer(bundleID: bundleID) ? .layoutKeys : .unicodeChunks
    }

    static func canDeliver(_ steps: [RemoteTypingStep]) -> Bool {
        !steps.isEmpty && steps.allSatisfy { if case .key = $0 { return true }; return false }
    }

    /// Plans one step per character. Line breaks and tabs use the Return
    /// and Tab keys, which sit at the same key code on every layout.
    static func steps(for text: String, keyMap: [String: LayoutKeyStroke]) -> [RemoteTypingStep] {
        text.map { character in
            switch character {
            case "\n", "\r", "\r\n":
                return .key(LayoutKeyStroke(keyCode: CGKeyCode(kVK_Return), shift: false, option: false))
            case "\t":
                return .key(LayoutKeyStroke(keyCode: CGKeyCode(kVK_Tab), shift: false, option: false))
            default:
                let string = String(character)
                if let stroke = keyMap[string] { return .key(stroke) }
                return .unicode(Array(string.utf16))
            }
        }
    }

    /// The key events for one stroke: modifiers down, the key down and up,
    /// then modifiers up in reverse order. The last event always carries no
    /// modifier flags, so a stroke never leaves Shift or Option held.
    static func keyPresses(for stroke: LayoutKeyStroke) -> [LayoutKeyPress] {
        var presses: [LayoutKeyPress] = []
        var flags: CGEventFlags = []
        if stroke.shift {
            flags.formUnion([.maskShift, leftShiftDeviceFlag])
            presses.append(LayoutKeyPress(keyCode: CGKeyCode(kVK_Shift), keyDown: true, flags: flags))
        }
        if stroke.option {
            flags.formUnion([.maskAlternate, leftOptionDeviceFlag])
            presses.append(LayoutKeyPress(keyCode: CGKeyCode(kVK_Option), keyDown: true, flags: flags))
        }
        presses.append(LayoutKeyPress(keyCode: stroke.keyCode, keyDown: true, flags: flags))
        presses.append(LayoutKeyPress(keyCode: stroke.keyCode, keyDown: false, flags: flags))
        if stroke.option {
            flags.subtract([.maskAlternate, leftOptionDeviceFlag])
            presses.append(LayoutKeyPress(keyCode: CGKeyCode(kVK_Option), keyDown: false, flags: flags))
        }
        if stroke.shift {
            flags.subtract([.maskShift, leftShiftDeviceFlag])
            presses.append(LayoutKeyPress(keyCode: CGKeyCode(kVK_Shift), keyDown: false, flags: flags))
        }
        return presses
    }

    /// Maps every character the layout types in one key press to that key.
    /// Unmodified keys win over Shift, then Option, then Shift+Option, and
    /// a lower key code wins within a level. Dead keys (Option-E on the US
    /// layout) and control characters are left out.
    static func keyMap(layoutData: Data, keyboardType: UInt32) -> [String: LayoutKeyStroke] {
        let levels: [(shift: Bool, option: Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        var map: [String: LayoutKeyStroke] = [:]
        layoutData.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for level in levels {
                var modifiers: UInt32 = 0
                if level.shift { modifiers |= UInt32(shiftKey >> 8) & 0xFF }
                if level.option { modifiers |= UInt32(optionKey >> 8) & 0xFF }
                for keyCode in CGKeyCode(0)..<128 where !keypadKeyCodes.contains(keyCode) {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                                                0, &deadKeyState, characters.count, &length, &characters)
                    guard status == noErr, deadKeyState == 0, length > 0 else { continue }
                    let string = String(utf16CodeUnits: characters, count: length)
                    guard string.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
                          map[string] == nil else { continue }
                    map[string] = LayoutKeyStroke(keyCode: keyCode, shift: level.shift, option: level.option)
                }
            }
        }
        return map
    }

    /// The key map for the keyboard layout in use now. Empty when no layout
    /// data is available, which sends every character as a Unicode event.
    static func currentLayoutKeyMap() -> [String: LayoutKeyStroke] {
        for copySource in [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource] {
            guard let source = copySource()?.takeRetainedValue(),
                  let data = layoutData(of: source) else { continue }
            return keyMap(layoutData: data, keyboardType: UInt32(LMGetKbdType()))
        }
        return [:]
    }

    static func layoutData(of source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }
}
