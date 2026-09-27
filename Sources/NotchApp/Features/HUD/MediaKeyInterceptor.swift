import AppKit
import ApplicationServices
@preconcurrency import CoreGraphics // CGEvent predates Swift concurrency annotations

/// Catches the volume and brightness keys before macOS sees them, so we can
/// change the level ourselves and show our HUD instead of the system's.
///
/// Needs Accessibility permission (System Settings → Privacy & Security →
/// Accessibility), because it intercepts keyboard events.
@MainActor
final class MediaKeyInterceptor {
    enum Key {
        case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
    }

    /// Return `true` if you handled the key; the event is then swallowed and
    /// macOS won't react to it (so its own HUD doesn't appear).
    var handler: ((_ key: Key, _ fineStep: Bool) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowedKeyCodes: Set<Int> = []

    var isRunning: Bool { tap != nil }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that links to the Accessibility settings.
    static func requestPermission() {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Returns false if macOS refused (usually: no Accessibility permission yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        // Media keys arrive as "system defined" events (type 14 / NX_SYSDEFINED).
        let mask = CGEventMask(1 << 14)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { interceptor.handle(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // .defaultTap = allowed to swallow events
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        swallowedKeyCodes.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // macOS disables taps that are too slow; just turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough
        }

        guard type.rawValue == 14,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 // "aux control button" = media keys
        else { return passThrough }

        // data1 packs the key code (high 16 bits) and key state (bits 8-15).
        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let isKeyDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0xA

        let key: Key
        switch keyCode {
        case 0: key = .volumeUp        // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown      // NX_KEYTYPE_SOUND_DOWN
        case 2: key = .brightnessUp    // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .brightnessDown  // NX_KEYTYPE_BRIGHTNESS_DOWN
        case 7: key = .mute            // NX_KEYTYPE_MUTE
        default: return passThrough
        }

        if isKeyDown {
            // Option+Shift gives finer steps, like macOS does.
            let fine = nsEvent.modifierFlags.contains([.option, .shift])
            guard handler?(key, fine) == true else { return passThrough }
            swallowedKeyCodes.insert(keyCode)
            return nil
        }
        // Swallow the matching key-up too.
        return swallowedKeyCodes.remove(keyCode) != nil ? nil : passThrough
    }
}
