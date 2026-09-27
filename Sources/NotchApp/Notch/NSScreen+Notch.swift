import AppKit

extension NSScreen {
    /// The built-in display with a camera notch, if one is connected and awake.
    static var notched: NSScreen? {
        screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// Size of the physical notch in points. The areas left and right of the
    /// notch are reported by macOS, so the notch is whatever is in between.
    var notchSize: CGSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea?.width,
              let right = auxiliaryTopRightArea?.width
        else { return nil }
        return CGSize(width: frame.width - left - right, height: safeAreaInsets.top)
    }
}
