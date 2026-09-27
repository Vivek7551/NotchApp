import Foundation

/// User preferences, saved in UserDefaults so they survive restarts.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let replaceSystemHUD = "replaceSystemHUD"
        static let clipboardHistory = "clipboardHistory"
        static let hapticFeedback = "hapticFeedback"
    }

    /// Swallow the volume/brightness keys and show our HUD instead of macOS's.
    /// Needs Accessibility permission.
    @Published var replaceSystemHUD: Bool {
        didSet { UserDefaults.standard.set(replaceSystemHUD, forKey: Key.replaceSystemHUD) }
    }

    @Published var clipboardHistoryEnabled: Bool {
        didSet { UserDefaults.standard.set(clipboardHistoryEnabled, forKey: Key.clipboardHistory) }
    }

    /// A small trackpad "bump" when the notch opens.
    @Published var hapticFeedback: Bool {
        didSet { UserDefaults.standard.set(hapticFeedback, forKey: Key.hapticFeedback) }
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Key.replaceSystemHUD: true, Key.clipboardHistory: true, Key.hapticFeedback: true])
        replaceSystemHUD = defaults.bool(forKey: Key.replaceSystemHUD)
        clipboardHistoryEnabled = defaults.bool(forKey: Key.clipboardHistory)
        hapticFeedback = defaults.bool(forKey: Key.hapticFeedback)
    }
}
