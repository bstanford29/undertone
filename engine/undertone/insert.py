from __future__ import annotations

import logging
import time

logger = logging.getLogger("undertone.insert")

CHUNK_SIZE = 20


def _process_trusted() -> bool:
    try:
        from ApplicationServices import AXIsProcessTrusted
    except ImportError:
        return True
    return bool(AXIsProcessTrusted())


def _insert_ax(text: str) -> bool:
    try:
        from ApplicationServices import (
            AXUIElementCreateSystemWide,
            AXUIElementCopyAttributeValue,
            AXUIElementSetAttributeValue,
            kAXFocusedUIElementAttribute,
            kAXSelectedTextAttribute,
        )
    except ImportError as exc:
        logger.warning("ax insert unavailable, pyobjc ApplicationServices missing: %s", exc)
        return False

    system_wide = AXUIElementCreateSystemWide()
    err, focused = AXUIElementCopyAttributeValue(system_wide, kAXFocusedUIElementAttribute, None)
    if err != 0 or focused is None:
        logger.warning("ax insert failed: could not get focused element (error %s)", err)
        return False

    err = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute, text)
    if err != 0:
        logger.warning("ax insert failed: could not set selected text (error %s)", err)
        return False

    return True


def _insert_type(text: str) -> bool:
    try:
        from Quartz import (
            CGEventCreateKeyboardEvent,
            CGEventKeyboardSetUnicodeString,
            CGEventPost,
            kCGHIDEventTap,
        )
    except ImportError as exc:
        logger.warning("type insert unavailable, pyobjc Quartz missing: %s", exc)
        return False

    try:
        for i in range(0, len(text), CHUNK_SIZE):
            chunk = text[i : i + CHUNK_SIZE]
            down = CGEventCreateKeyboardEvent(None, 0, True)
            CGEventKeyboardSetUnicodeString(down, len(chunk), chunk)
            CGEventPost(kCGHIDEventTap, down)
            up = CGEventCreateKeyboardEvent(None, 0, False)
            CGEventKeyboardSetUnicodeString(up, len(chunk), chunk)
            CGEventPost(kCGHIDEventTap, up)
        return True
    except Exception as exc:
        logger.warning("type insert failed: %s", exc)
        return False


def _insert_paste(text: str) -> bool:
    try:
        from AppKit import NSPasteboard, NSPasteboardTypeString
        from Quartz import (
            CGEventCreateKeyboardEvent,
            CGEventPost,
            CGEventSetFlags,
            kCGEventFlagMaskCommand,
            kCGHIDEventTap,
        )
    except ImportError as exc:
        logger.warning("paste insert unavailable, pyobjc AppKit/Quartz missing: %s", exc)
        return False

    logger.warning("paste insert: touching the system clipboard")
    pasteboard = NSPasteboard.generalPasteboard()
    saved_items = []
    for item in pasteboard.pasteboardItems() or []:
        types = item.types()
        saved_items.append({t: item.dataForType_(t) for t in types})

    pasteboard.clearContents()
    pasteboard.setString_forType_(text, NSPasteboardTypeString)

    v_keycode = 9  # kVK_ANSI_V
    down = CGEventCreateKeyboardEvent(None, v_keycode, True)
    CGEventSetFlags(down, kCGEventFlagMaskCommand)
    up = CGEventCreateKeyboardEvent(None, v_keycode, False)
    CGEventSetFlags(up, kCGEventFlagMaskCommand)
    CGEventPost(kCGHIDEventTap, down)
    CGEventPost(kCGHIDEventTap, up)

    time.sleep(0.15)

    pasteboard.clearContents()
    for item_types in saved_items:
        for pb_type, data in item_types.items():
            pasteboard.setData_forType_(data, pb_type)

    return True


def insert(text: str, mode: str = "auto", config: dict | None = None) -> str:
    if not _process_trusted():
        logger.error(
            "insertion blocked: this process lacks Accessibility permission. "
            "System Settings > Privacy & Security > Accessibility: add the app running undertone "
            "(your terminal, or the Undertone app). Synthetic keystrokes are also dropped without it."
        )
        return "failed"
    """Insert text into the frontmost app. Returns the strategy that succeeded."""
    config = config or {}

    if mode == "auto":
        if _insert_ax(text):
            return "ax"
        if _insert_type(text):
            return "type"
        if config.get("insert_mode") == "paste" and _insert_paste(text):
            return "paste"
        return "failed"

    if mode == "ax":
        return "ax" if _insert_ax(text) else "failed"
    if mode == "type":
        return "type" if _insert_type(text) else "failed"
    if mode == "paste":
        return "paste" if _insert_paste(text) else "failed"

    raise ValueError(f"unknown insert mode: {mode}")
