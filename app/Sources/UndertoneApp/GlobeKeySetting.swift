import Darwin
import Foundation
import os

/// Reads and writes macOS's "Press globe key to" preference through the
/// same private HIToolbox entry points System Settings uses.
///
/// A bare tap of the fn key runs a system action unless this preference is
/// 0 ("Do Nothing"): 1 changes the input source, 2 shows the Emoji &
/// Symbols picker, 3 starts dictation, and a missing value defaults to 2.
/// Undertone uses fn as its hold-to-talk key, so that system action steals
/// every bare tap unless this preference is 0.
///
/// A plain write of `AppleFnUsageType` in the `com.apple.HIToolbox`
/// preference domain persists (System Settings' Keyboard pane reads it
/// back correctly) but does nothing at runtime: `TextInputSwitcher`, the
/// process that actually runs the globe-key action, never re-reads that
/// key. The file read 0 for two hours in testing while every bare fn tap
/// still opened the Emoji & Symbols picker.
///
/// The Keyboard settings pane does not write the preference key itself.
/// Disassembly of `/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex`
/// shows it calls two private functions exported by
/// `/System/Library/Frameworks/Carbon.framework/Carbon`:
/// `TISGetFnUsageType() -> Int32` (the effective value) and
/// `TISUpdateFnUsageType(Int32) -> Int32` (0 on success; persists the
/// value and notifies the text input agents). This signature was
/// confirmed by that disassembly and by a live test on 2026-09-16, which
/// called both functions via `dlopen`/`dlsym` and observed
/// `TextInputMenuAgent` log "Loading Preferences" on each call, with
/// `TISGetFnUsageType()` reading back the value `TISUpdateFnUsageType`
/// had just set. Undertone loads the same functions the same way so its
/// button actually changes the running behavior, not just the stored
/// preference.
enum GlobeKeySetting {
    /// A store for the previous-value bookkeeping this type needs, narrowed
    /// to just the calls it makes so tests can inject a fake in place of
    /// `UserDefaults`.
    protocol PreferenceStore {
        func integer(forKey key: String) -> Int?
        func set(_ value: Int, forKey key: String)
        func removeObject(forKey key: String)
    }

    private typealias TISGetFnUsageTypeFn = @convention(c) () -> Int32
    private typealias TISUpdateFnUsageTypeFn = @convention(c) (Int32) -> Int32

    private static let carbonFrameworkPath = "/System/Library/Frameworks/Carbon.framework/Carbon"

    /// Resolves `TISGetFnUsageType` via `dlopen`/`dlsym` on every access
    /// instead of caching it in global mutable state, so this type has no
    /// non-Sendable statics under Swift 6 strict concurrency. The repeated
    /// `dlopen` calls are cheap: the dynamic linker already holds Carbon
    /// open and just bumps a refcount. `nil` means the symbol could not be
    /// resolved; callers fall back to the `CFPreferences` read.
    private static var tisGetFnUsageType: TISGetFnUsageTypeFn? {
        guard let handle = dlopen(carbonFrameworkPath, RTLD_NOW),
              let symbol = dlsym(handle, "TISGetFnUsageType") else {
            return nil
        }
        return unsafeBitCast(symbol, to: TISGetFnUsageTypeFn.self)
    }

    /// Resolves `TISUpdateFnUsageType` the same way as `tisGetFnUsageType`.
    private static var tisUpdateFnUsageType: TISUpdateFnUsageTypeFn? {
        guard let handle = dlopen(carbonFrameworkPath, RTLD_NOW),
              let symbol = dlsym(handle, "TISUpdateFnUsageType") else {
            return nil
        }
        return unsafeBitCast(symbol, to: TISUpdateFnUsageTypeFn.self)
    }

    // Computed, not stored, so these CFStrings do not become non-Sendable
    // global mutable state under Swift 6 strict concurrency checking.
    private static var domain: CFString { "com.apple.HIToolbox" as CFString }
    private static var preferenceKey: CFString { "AppleFnUsageType" as CFString }
    /// Undertone's own key, not Apple's. Holds the value `AppleFnUsageType`
    /// had before Undertone changed it, so `revert()` can put it back.
    /// `-1` means "the key was unset", since `nil` cannot round-trip
    /// through `UserDefaults` as a stored sentinel.
    static let previousValueDefaultsKey = "globeKeyPreviousValue"
    private static let wasUnsetSentinel = -1
    private static let logger = Logger(subsystem: "com.undertone.app", category: "GlobeKeySetting")

    /// The current effective `AppleFnUsageType` value. Reads it through
    /// `TISGetFnUsageType()` when that symbol resolves, since that is what
    /// actually drives the globe-key action; falls back to the raw
    /// `CFPreferencesCopyAppValue` read (which can be `nil` when unset)
    /// only when the symbol is unavailable.
    static func current() -> Int? {
        if let getFn = tisGetFnUsageType {
            return Int(getFn())
        }
        return CFPreferencesCopyAppValue(preferenceKey, domain) as? Int
    }

    /// Whether the globe-key system action is likely to steal a bare fn
    /// tap, given whether fn is currently a hold key and the raw
    /// `AppleFnUsageType` value. Pure so it can be unit tested without
    /// touching real preferences.
    static func needsChange(holdKeyIsFn: Bool, currentValue: Int?) -> Bool {
        guard holdKeyIsFn else { return false }
        return currentValue != 0
    }

    /// Whether Undertone's live hold key needs this preference changed.
    /// Undertone always listens on fn (alongside F13), so this reads the
    /// live preference and reports whether it differs from "Do Nothing".
    static var needsChange: Bool {
        needsChange(holdKeyIsFn: true, currentValue: current())
    }

    /// The value to save as "previous" before overwriting `currentValue`,
    /// using `wasUnsetSentinel` in place of a real `nil`. Pure so the
    /// bookkeeping can be tested without real preference reads or writes.
    static func valueToStore(currentValue: Int?) -> Int {
        currentValue ?? wasUnsetSentinel
    }

    /// The value to restore `AppleFnUsageType` to given a stored "previous"
    /// value, or `nil` when that value means the key was unset. Pure for
    /// the same reason as `valueToStore`.
    static func valueToRestore(storedPreviousValue: Int) -> Int? {
        storedPreviousValue == wasUnsetSentinel ? nil : storedPreviousValue
    }

    /// Sets the globe-key action to 0 ("Do Nothing"), after saving the
    /// current effective value so `revert()` can restore it. Returns
    /// whether the value reads back as 0 afterward. Never throws or
    /// crashes; failures are logged.
    ///
    /// Calls `TISUpdateFnUsageType(0)`, the same private HIToolbox entry
    /// point the Keyboard settings pane uses, so the change takes effect
    /// immediately instead of only persisting to disk. Falls back to a
    /// plain `CFPreferencesSetAppValue` write, which persists but is not
    /// picked up by the running `TextInputSwitcher`, only when the TIS
    /// symbol cannot be resolved.
    @discardableResult
    static func setDoNothing(store: PreferenceStore = UserDefaults.standard) -> Bool {
        let existing = current()
        store.set(valueToStore(currentValue: existing), forKey: previousValueDefaultsKey)

        guard let updateFn = tisUpdateFnUsageType else {
            logger.error("TISUpdateFnUsageType unavailable; falling back to a CFPreferences write")
            CFPreferencesSetAppValue(preferenceKey, 0 as CFPropertyList, domain)
            if !CFPreferencesAppSynchronize(domain) {
                logger.error("CFPreferencesAppSynchronize failed while setting AppleFnUsageType to 0")
            }
            let succeeded = current() == 0
            if !succeeded {
                logger.error("AppleFnUsageType did not read back as 0 after the setDoNothing() fallback")
            }
            return succeeded
        }

        let result = updateFn(0)
        if result != 0 {
            logger.error("TISUpdateFnUsageType(0) returned \(result, privacy: .public) instead of 0")
            return false
        }

        let succeeded = current() == 0
        if !succeeded {
            logger.error("AppleFnUsageType did not read back as 0 after setDoNothing()")
        }
        return succeeded
    }

    /// Restores the globe-key action to the value saved by
    /// `setDoNothing()`, or to 2 (the macOS default when the key is
    /// absent) when that saved value means the key was unset. Returns
    /// false, without changing anything, when no previous value is
    /// stored. Never throws or crashes; failures are logged.
    ///
    /// Calls `TISUpdateFnUsageType(previous)` so the restore takes effect
    /// immediately, the same as `setDoNothing()`. Falls back to a plain
    /// `CFPreferencesSetAppValue` write (removing the key entirely when it
    /// was previously unset) only when the TIS symbol cannot be resolved.
    @discardableResult
    static func revert(store: PreferenceStore = UserDefaults.standard) -> Bool {
        guard let stored = store.integer(forKey: previousValueDefaultsKey) else {
            logger.error("revert() called with no stored previous AppleFnUsageType value")
            return false
        }

        let storedRestoreValue = valueToRestore(storedPreviousValue: stored)

        guard let updateFn = tisUpdateFnUsageType else {
            logger.error("TISUpdateFnUsageType unavailable; falling back to a CFPreferences write")
            if let storedRestoreValue {
                CFPreferencesSetAppValue(preferenceKey, storedRestoreValue as CFPropertyList, domain)
            } else {
                CFPreferencesSetAppValue(preferenceKey, nil, domain)
            }
            if !CFPreferencesAppSynchronize(domain) {
                logger.error("CFPreferencesAppSynchronize failed while reverting AppleFnUsageType")
            }
            let succeeded = current() == storedRestoreValue
            if !succeeded {
                logger.error("AppleFnUsageType did not read back as the restored value after the revert() fallback")
            }
            store.removeObject(forKey: previousValueDefaultsKey)
            return succeeded
        }

        // The default macOS behavior when the key is absent is 2 (Emoji &
        // Symbols); TISUpdateFnUsageType always needs a concrete value.
        let restoreTarget = storedRestoreValue ?? 2
        let result = updateFn(Int32(restoreTarget))
        store.removeObject(forKey: previousValueDefaultsKey)
        if result != 0 {
            logger.error("TISUpdateFnUsageType(\(restoreTarget, privacy: .public)) returned \(result, privacy: .public) instead of 0")
            return false
        }

        let succeeded = current() == restoreTarget
        if !succeeded {
            logger.error("AppleFnUsageType did not read back as the restored value after revert()")
        }
        return succeeded
    }

}

extension UserDefaults: GlobeKeySetting.PreferenceStore {
    func integer(forKey key: String) -> Int? {
        object(forKey: key) as? Int
    }
}
