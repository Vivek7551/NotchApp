import AppKit
import Combine
import os
import SwiftUI

/// Read with: log show --last 10m --predicate 'subsystem == "com.local.NotchApp"'
private let permissionsLog = Logger(subsystem: "com.local.NotchApp", category: "Permissions")

/// Entry point. We use a plain AppKit app delegate (instead of a SwiftUI `App`)
/// because we need full control over a special borderless window.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        #if DEBUG
        if DebugSnapshot.runIfRequested() { return }
        #endif

        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar app: no Dock icon
        app.run()
    }

    private let viewModel = NotchViewModel()
    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        layoutPanel()

        // Re-position when displays change (lid closed, resolution changed, etc).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Only catch mouse clicks while open; when closed, clicks pass through.
        viewModel.$state
            .sink { [weak self] state in self?.panel?.ignoresMouseEvents = (state == .closed) }
            .store(in: &cancellables)

        viewModel.showAppMenu = { [weak self] in self?.showMenuFromNotch() }
        viewModel.start()
        logPermissions("launch")
        logStatusItemPosition()
        // Accessibility can be granted while we run; report again a bit later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated { self?.logPermissions("launch+5s") }
        }
    }

    /// Writes which permissions macOS has given this copy of the app.
    private func logPermissions(_ reason: String) {
        let accessibility = MediaKeyInterceptor.hasPermission
        let fullDiskAccess = viewModel.focus.hasAccess
        let hudActive = viewModel.mediaKeys.isRunning
        permissionsLog.notice(
            "[\(reason, privacy: .public)] Accessibility=\(accessibility) FullDiskAccess=\(fullDiskAccess) HUDKeyInterceptionRunning=\(hudActive)"
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stop()
    }

    @objc private func screensDidChange() {
        layoutPanel()
    }

    /// Creates the notch panel (once) and places it at the top-center of the notched screen.
    private func layoutPanel() {
        guard let screen = NSScreen.notched, let notchSize = screen.notchSize else {
            // No notched display right now (e.g. lid closed with an external monitor).
            panel?.orderOut(nil)
            viewModel.screenFrame = nil
            return
        }

        viewModel.screenFrame = screen.frame
        viewModel.notchSize = notchSize

        let size = viewModel.windowSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        if panel == nil {
            let panel = NotchPanel(contentRect: frame)
            let hostingView = NotchHostingView(rootView: NotchView(vm: viewModel))
            hostingView.sizingOptions = [] // don't let SwiftUI resize our window
            panel.contentView = hostingView
            self.panel = panel
        }

        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    // MARK: - Menu bar icon

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "NotchApp"
        )
        let menu = NSMenu()
        menu.delegate = self // rebuilt each time it opens, so checkmarks are current
        item.menu = menu
        statusItem = item
    }

    /// The same menu as the menu bar icon, popped up at the mouse (from the ⚙︎ in the notch).
    private func showMenuFromNotch() {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Logs whether the menu bar icon ended up hidden behind the notch
    /// (macOS hides icons that don't fit when the menu bar is full).
    private func logStatusItemPosition() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let frame = self?.statusItem?.button?.window?.frame,
                      let screen = NSScreen.notched,
                      let left = screen.auxiliaryTopLeftArea?.maxX,
                      let right = screen.auxiliaryTopRightArea?.minX
                else { return }
                let hidden = frame.maxX > left && frame.minX < right
                permissionsLog.notice("Menu bar icon at x=\(Int(frame.minX)) (notch covers \(Int(left))–\(Int(right))): \(hidden ? "HIDDEN behind the notch" : "visible", privacy: .public)")
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = viewModel.settings
        viewModel.focus.refresh(notify: false) // pick up newly granted Full Disk Access
        logPermissions("menu opened")
        menu.removeAllItems()

        menu.addItem(withTitle: "NotchApp", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        addItem(to: menu, "Replace Volume & Brightness HUD", action: #selector(toggleSystemHUD),
                checked: settings.replaceSystemHUD)
        if settings.replaceSystemHUD && !MediaKeyInterceptor.hasPermission {
            addItem(to: menu, "    Grant Accessibility Permission…", action: #selector(openAccessibilitySettings))
        }

        addItem(to: menu, "Clipboard History", action: #selector(toggleClipboardHistory),
                checked: settings.clipboardHistoryEnabled)

        addItem(to: menu, "Haptic Feedback", action: #selector(toggleHapticFeedback),
                checked: settings.hapticFeedback)

        if viewModel.focus.hasAccess {
            addItem(to: menu, "Focus Detection: On", action: nil)
        } else {
            addItem(to: menu, "Enable Focus Detection (Full Disk Access)…", action: #selector(openFullDiskAccessSettings))
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotchApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func addItem(to menu: NSMenu, _ title: String, action: Selector?, checked: Bool = false) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    @objc private func toggleSystemHUD() {
        viewModel.settings.replaceSystemHUD.toggle()
        if viewModel.settings.replaceSystemHUD && !MediaKeyInterceptor.hasPermission {
            MediaKeyInterceptor.requestPermission() // shows the system prompt
        }
        viewModel.applySettings()
    }

    @objc private func toggleClipboardHistory() {
        viewModel.settings.clipboardHistoryEnabled.toggle()
        viewModel.applySettings()
    }

    @objc private func toggleHapticFeedback() {
        viewModel.settings.hapticFeedback.toggle()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FocusService.fullDiskAccessSettingsURL)
    }
}

/// Lets the first click on a button work immediately, even though our
/// panel isn't the active window.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
