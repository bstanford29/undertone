import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import UndertoneApp

/// Exercises the pure parts of typing into a remote-desktop viewer: which
/// apps count as viewers, the per-character plan, and the modifier wrapping.
/// Nothing here posts a keyboard event.
final class RemoteDesktopTypingTests: XCTestCase {
    private let plainA = LayoutKeyStroke(keyCode: CGKeyCode(kVK_ANSI_A), shift: false, option: false)

    // MARK: viewer detection

    func testJumpDesktopViewerBuildsAreRemoteViewers() {
        XCTAssertTrue(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: "com.p5sys.jump.mac.viewer"))
        XCTAssertTrue(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: "com.p5sys.jump.mac.viewer.web"))
    }

    func testJumpDesktopConnectHostIsNotAViewer() {
        XCTAssertFalse(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: "com.p5sys.jump.connect"))
    }

    func testOtherRemoteDesktopViewersAreRecognized() {
        XCTAssertTrue(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: "com.microsoft.rdc.macos"))
        XCTAssertTrue(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: "com.apple.ScreenSharing"))
        XCTAssertTrue(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: "com.edovia.screens5.mac"))
        XCTAssertTrue(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: "tv.parsec.www"))
    }

    func testLocalAppsAreNotRemoteViewers() {
        XCTAssertFalse(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: "com.apple.MobileSMS"))
        XCTAssertFalse(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: "com.google.Chrome"))
        XCTAssertFalse(RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: nil))
    }

    func testKeystrokeMethodChangesOnlyForRemoteViewers() {
        XCTAssertEqual(RemoteDesktopTyping.keystrokeMethod(bundleID: "com.p5sys.jump.mac.viewer.web"), .layoutKeys)
        XCTAssertEqual(RemoteDesktopTyping.keystrokeMethod(bundleID: "com.apple.TextEdit"), .unicodeChunks)
        XCTAssertEqual(RemoteDesktopTyping.keystrokeMethod(bundleID: nil), .unicodeChunks)
    }

    // MARK: per-character plan

    func testStepsUseTheKeyMapOneCharacterAtATime() {
        let shiftedH = LayoutKeyStroke(keyCode: CGKeyCode(kVK_ANSI_H), shift: true, option: false)
        let plainI = LayoutKeyStroke(keyCode: CGKeyCode(kVK_ANSI_I), shift: false, option: false)
        let keyMap = ["H": shiftedH, "i": plainI]
        XCTAssertEqual(RemoteDesktopTyping.steps(for: "Hii", keyMap: keyMap),
                       [.key(shiftedH), .key(plainI), .key(plainI)])
    }

    func testLineBreaksAndTabsUseReturnAndTab() {
        let returnKey = RemoteTypingStep.key(LayoutKeyStroke(keyCode: CGKeyCode(kVK_Return), shift: false, option: false))
        let tabKey = RemoteTypingStep.key(LayoutKeyStroke(keyCode: CGKeyCode(kVK_Tab), shift: false, option: false))
        XCTAssertEqual(RemoteDesktopTyping.steps(for: "a\nb\r\na\ta", keyMap: ["a": plainA, "b": plainA]),
                       [.key(plainA), returnKey, .key(plainA), returnKey, .key(plainA), tabKey, .key(plainA)])
    }

    func testCharacterWithoutAKeyStillGoesOutAsUnicode() {
        let steps = RemoteDesktopTyping.steps(for: "a😀é", keyMap: ["a": plainA])
        XCTAssertEqual(steps, [.key(plainA), .unicode(Array("😀".utf16)), .unicode(Array("é".utf16))])
    }

    func testEmptyKeyMapSendsEverythingAsUnicode() {
        XCTAssertEqual(RemoteDesktopTyping.steps(for: "ok", keyMap: [:]),
                       [.unicode(Array("o".utf16)), .unicode(Array("k".utf16))])
    }

    // MARK: modifier wrapping

    func testPlainKeyIsJustDownAndUp() {
        XCTAssertEqual(RemoteDesktopTyping.keyPresses(for: plainA), [
            LayoutKeyPress(keyCode: CGKeyCode(kVK_ANSI_A), keyDown: true, flags: []),
            LayoutKeyPress(keyCode: CGKeyCode(kVK_ANSI_A), keyDown: false, flags: []),
        ])
    }

    func testShiftOptionKeyPressesAndReleasesBothModifiers() {
        let stroke = LayoutKeyStroke(keyCode: CGKeyCode(kVK_ANSI_RightBracket), shift: true, option: true)
        let shift: CGEventFlags = [.maskShift, RemoteDesktopTyping.leftShiftDeviceFlag]
        let both = shift.union([.maskAlternate, RemoteDesktopTyping.leftOptionDeviceFlag])
        XCTAssertEqual(RemoteDesktopTyping.keyPresses(for: stroke), [
            LayoutKeyPress(keyCode: CGKeyCode(kVK_Shift), keyDown: true, flags: shift),
            LayoutKeyPress(keyCode: CGKeyCode(kVK_Option), keyDown: true, flags: both),
            LayoutKeyPress(keyCode: CGKeyCode(kVK_ANSI_RightBracket), keyDown: true, flags: both),
            LayoutKeyPress(keyCode: CGKeyCode(kVK_ANSI_RightBracket), keyDown: false, flags: both),
            LayoutKeyPress(keyCode: CGKeyCode(kVK_Option), keyDown: false, flags: shift),
            LayoutKeyPress(keyCode: CGKeyCode(kVK_Shift), keyDown: false, flags: []),
        ])
    }

    func testNoStrokeLeavesAModifierHeld() {
        for shift in [false, true] {
            for option in [false, true] {
                let presses = RemoteDesktopTyping.keyPresses(
                    for: LayoutKeyStroke(keyCode: CGKeyCode(kVK_ANSI_A), shift: shift, option: option))
                XCTAssertEqual(presses.last?.flags, CGEventFlags())
                XCTAssertEqual(presses.filter(\.keyDown).count, presses.filter { !$0.keyDown }.count)
            }
        }
    }

    // MARK: key map from a real layout

    /// Builds the map from the US layout that ships with macOS, so the
    /// result does not depend on the layout the test machine has selected.
    func testUSLayoutKeyMap() throws {
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let us = sources.first,
              let data = RemoteDesktopTyping.layoutData(of: us) else {
            throw XCTSkip("US keyboard layout not available")
        }
        let map = RemoteDesktopTyping.keyMap(layoutData: data, keyboardType: UInt32(LMGetKbdType()))
        XCTAssertEqual(map["a"], LayoutKeyStroke(keyCode: CGKeyCode(kVK_ANSI_A), shift: false, option: false))
        XCTAssertEqual(map["A"], LayoutKeyStroke(keyCode: CGKeyCode(kVK_ANSI_A), shift: true, option: false))
        XCTAssertEqual(map["!"], LayoutKeyStroke(keyCode: CGKeyCode(kVK_ANSI_1), shift: true, option: false))
        XCTAssertEqual(map[" "], LayoutKeyStroke(keyCode: CGKeyCode(kVK_Space), shift: false, option: false))
        XCTAssertEqual(map["\u{2019}"], LayoutKeyStroke(keyCode: CGKeyCode(kVK_ANSI_RightBracket), shift: true, option: true))
        // The main row wins over the keypad.
        XCTAssertEqual(map["*"], LayoutKeyStroke(keyCode: CGKeyCode(kVK_ANSI_8), shift: true, option: false))
        // Option-E is a dead key on the US layout, so "é" has no single key.
        XCTAssertNil(map["é"])
        XCTAssertNil(map["\r"])
    }
}
