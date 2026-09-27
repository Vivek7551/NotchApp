import AppKit
import ApplicationServices

/// Tells whether a *video* is playing full screen on the notched screen
/// (e.g. a full-screen YouTube video), as opposed to an app that's simply in
/// full-screen mode (Safari browsing, Notes...), which should keep the notch.
///
/// Safari/WebKit shows full-screen video in a borderless window with no title
/// (Accessibility subrole "AXDialog"), while normal app windows, even in full
/// screen, are "AXStandardWindow". Dedicated video players use normal windows,
/// so for them full screen always means watching.
///
/// Uses the Accessibility permission the HUD feature already has; without it,
/// the notch never hides.
@MainActor
enum FullScreenDetector {
    private static let videoPlayerApps: Set<String> = [
        "com.apple.QuickTimePlayerX", "com.apple.TV", "com.colliderli.iina",
        "org.videolan.vlc", "com.firecore.infuse",
    ]

    /// - Parameter screenFrame: the notched screen, in AppKit coordinates.
    static func isVideoFullScreen(screenFrame: NSRect) -> Bool {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(),
              let window = focusedWindow(of: app.processIdentifier),
              boolAttribute(window, "AXFullScreen") == true
        else { return false }

        // Full screen, but on this screen? (It could be on an external display.)
        if let frame = frame(of: window), !frame.intersects(topLeftRect(screenFrame)) { return false }

        let isStandardWindow = stringAttribute(window, "AXSubrole") == "AXStandardWindow"
        return !isStandardWindow || videoPlayerApps.contains(app.bundleIdentifier ?? "")
    }

    // MARK: - Accessibility helpers

    private static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5) // never hang on a busy app
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    /// Window frame in top-left-origin screen coordinates.
    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXPosition" as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, "AXSize" as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    /// AppKit uses a bottom-left origin; window APIs use top-left of the main display.
    private static func topLeftRect(_ rect: NSRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? rect.height
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
