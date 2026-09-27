import AppKit
import Combine
import os
import SwiftUI

/// Read with: /usr/bin/log show --last 10m --predicate 'subsystem == "com.local.NotchApp"'
private let fullScreenLog = Logger(subsystem: "com.local.NotchApp", category: "FullScreen")

/// A short alert that pops out of the closed notch for a few seconds
/// (volume change, charger plugged in, timer finished...).
struct Peek: Equatable {
    enum Value: Equatable {
        case text(String)
        case level(Double) // 0...1, drawn as a bar
    }

    /// Peeks with the same id update in place (e.g. repeated volume steps)
    /// instead of popping a new one each time.
    var id: String
    var icon: String
    var tint: Color
    var value: Value
}

/// What the closed notch shows on each side of the camera.
struct ClosedLayout: Equatable {
    enum Left: Equatable { case none, artwork, icon(String, Color) }
    enum Right: Equatable { case none, bars, timer, text(String, Color), level(Double) }

    var left: Left = .none
    var right: Right = .none
    /// Green = camera in use, orange = microphone in use.
    var privacyDot: Color?
    /// Extra width added on each side of the camera (0 = plain notch).
    var wingWidth: CGFloat = 0
}

/// The notch's brain: open/closed state, which page is shown, and what the
/// closed notch displays. Owns all the feature services.
@MainActor
final class NotchViewModel: ObservableObject {
    enum State { case closed, open }
    enum Page { case home, nowPlaying }

    @Published private(set) var state: State = .closed
    @Published private(set) var page: Page = .home
    @Published private(set) var peek: Peek?
    /// A video is playing full screen on the notched screen: hide the live
    /// activities and don't open on hover (volume/brightness pop-ups still show).
    /// Apps that are merely in full-screen mode keep the notch as normal.
    @Published private(set) var isVideoFullScreen = false

    /// Size of the physical notch; updated from the real screen at launch.
    @Published var notchSize = CGSize(width: 185, height: 32)

    /// Size of the black area when the notch is open.
    let openSize = CGSize(width: 600, height: 190)

    /// Frame of the notched screen, in global screen coordinates.
    var screenFrame: NSRect?

    /// Shows the app menu (settings, Quit). Set by the app delegate; used by the
    /// ⚙︎ button in the open notch, since the menu bar icon can end up hidden
    /// behind the notch when the menu bar is full.
    var showAppMenu: (() -> Void)?

    let settings = AppSettings()
    let nowPlaying = NowPlayingService()
    let battery = BatteryService()
    let timer = TimerService()
    let clipboard = ClipboardService()
    let privacy = PrivacyMonitor()
    let focus = FocusService()
    let mediaKeys = MediaKeyInterceptor()
    private let volumeObserver = VolumeObserver()

    /// The page the user last picked; used when the notch next opens.
    private var preferredPage: Page = .nowPlaying
    private var peekDismissal: DispatchWorkItem?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var swipeDistance = CGSize.zero
    private var permissionPoll: Timer?
    private var permissionPollAttempts = 0

    /// The window is always big enough for the open notch plus room for the
    /// curved "ears" and the drop shadow; SwiftUI animates inside it.
    var windowSize: CGSize {
        CGSize(width: openSize.width + 2 * NotchShape.openTopRadius + 60, height: openSize.height + 40)
    }

    init() {
        // Redraw the notch whenever any feature's data changes.
        let publishers = [
            settings.objectWillChange, nowPlaying.objectWillChange, battery.objectWillChange,
            timer.objectWillChange, clipboard.objectWillChange, privacy.objectWillChange, focus.objectWillChange,
        ]
        for publisher in publishers {
            publisher
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
                .store(in: &cancellables)
        }
    }

    func start() {
        startMouseTracking()
        startFullScreenTracking()
        nowPlaying.start()
        privacy.start()

        battery.onEvent = { [weak self] event in self?.handleBatteryEvent(event) }
        battery.start()

        focus.onChange = { [weak self] focus in self?.handleFocusChange(focus) }
        focus.start()

        timer.onFinished = { [weak self] message in
            self?.showPeek(Peek(id: "timer", icon: "timer", tint: .orange, value: .text(message)), for: 6)
        }

        volumeObserver.onChange = { [weak self] volume, muted in self?.showVolumeHUD(volume, muted: muted) }
        volumeObserver.start()
        mediaKeys.handler = { [weak self] key, fine in self?.handleMediaKey(key, fineStep: fine) ?? false }

        applySettings()
        requestMissingPermissions()
    }

    /// Features that are switched on but lack permission: show macOS's prompts.
    /// (Turn a feature off in the menu to stop being asked.)
    private func requestMissingPermissions() {
        if settings.replaceSystemHUD && !MediaKeyInterceptor.hasPermission {
            MediaKeyInterceptor.requestPermission()
        }
    }

    func stop() {
        nowPlaying.stop()
        mediaKeys.stop()
    }

    /// Starts/stops features to match the current settings.
    func applySettings() {
        if settings.clipboardHistoryEnabled { clipboard.start() } else { clipboard.stop() }
        updateMediaKeyInterception()
    }

    // MARK: - Open / close & pages

    func open() {
        guard state != .open else { return }
        page = isMediaPageAvailable ? preferredPage : .home
        state = .open
        if settings.hapticFeedback { // feels like a click on the trackpad, but it's only a vibration
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        }
    }

    func close() {
        state = .closed
    }

    /// The player page exists while something plays, and for 5 minutes after
    /// pausing (so you can resume without it vanishing under your cursor).
    var isMediaPageAvailable: Bool {
        guard let info = nowPlaying.info else { return false }
        if info.isPlaying { return true }
        guard let lastPlayedAt = nowPlaying.lastPlayedAt else { return false }
        return Date().timeIntervalSince(lastPlayedAt) < 5 * 60
    }

    var availablePages: [Page] {
        isMediaPageAvailable ? [.home, .nowPlaying] : [.home]
    }

    /// The page on screen; falls back to Home if the player page went away.
    var visiblePage: Page {
        availablePages.contains(page) ? page : .home
    }

    func select(_ page: Page) {
        self.page = page
        preferredPage = page
    }

    // MARK: - Closed notch

    var closedLayout: ClosedLayout {
        let privacyDot: Color? = privacy.cameraInUse ? .green : (privacy.micInUse ? .orange : nil)
        let baseWidth = notchSize.height + 6
        var layout = ClosedLayout(privacyDot: privacyDot)

        // A temporary peek takes over the whole closed notch.
        if let peek {
            layout.left = .icon(peek.icon, peek.tint)
            layout.privacyDot = nil
            switch peek.value {
            case .text(let text):
                layout.right = .text(text, peek.tint)
                layout.wingWidth = max(baseWidth, Self.textWidth(text) + 18)
            case .level(let level):
                layout.right = .level(level)
                layout.wingWidth = 72
            }
            return layout
        }

        // Full-screen video: keep the notch plain (no artwork, bars, timer).
        if isVideoFullScreen { return ClosedLayout() }

        // Otherwise show ongoing activities: music and/or a running timer.
        let isMusicPlaying = nowPlaying.info?.isPlaying == true
        if isMusicPlaying {
            layout.left = .artwork
            layout.right = .bars
            layout.wingWidth = baseWidth
        }
        if timer.isActive {
            if !isMusicPlaying { layout.left = .icon("timer", .orange) }
            layout.right = .timer
            layout.wingWidth = max(baseWidth, 50)
        }
        if privacyDot != nil {
            layout.wingWidth = layout.wingWidth == 0 ? 20 : layout.wingWidth + 10
        }
        return layout
    }

    var closedSize: CGSize {
        CGSize(width: notchSize.width + 2 * closedLayout.wingWidth, height: notchSize.height)
    }

    func showPeek(_ peek: Peek, for duration: TimeInterval) {
        self.peek = peek
        peekDismissal?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.peek = nil }
        }
        peekDismissal = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    private static func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: - Feature events

    private func handleBatteryEvent(_ event: BatteryService.Event) {
        switch event {
        case .pluggedIn(let status):
            showPeek(Peek(id: "battery", icon: "bolt.fill", tint: .green, value: .text("\(status.percent)%")), for: 3)
        case .unplugged(let status):
            showPeek(Peek(id: "battery", icon: status.symbolName, tint: .white, value: .text("\(status.percent)%")), for: 3)
        case .low(let status):
            showPeek(Peek(id: "battery", icon: "battery.25percent", tint: .red, value: .text("\(status.percent)% left")), for: 5)
        }
    }

    private func handleFocusChange(_ focus: FocusService.Focus?) {
        if let focus {
            showPeek(Peek(id: "focus", icon: focus.symbol, tint: .indigo, value: .text(focus.name)), for: 3)
        } else {
            showPeek(Peek(id: "focus", icon: "moon", tint: .gray, value: .text("Focus off")), for: 2.5)
        }
    }

    // MARK: - Volume & brightness HUD

    private func showVolumeHUD(_ volume: Float, muted: Bool) {
        let level = muted ? 0 : Double(volume)
        let icon: String
        switch level {
        case 0: icon = "speaker.slash.fill"
        case ..<0.34: icon = "speaker.wave.1.fill"
        case ..<0.67: icon = "speaker.wave.2.fill"
        default: icon = "speaker.wave.3.fill"
        }
        showPeek(Peek(id: "volume", icon: icon, tint: .white, value: .level(level)), for: 1.5)
    }

    private func showBrightnessHUD(_ brightness: Float) {
        let icon = brightness < 0.5 ? "sun.min.fill" : "sun.max.fill"
        showPeek(Peek(id: "brightness", icon: icon, tint: .white, value: .level(Double(brightness))), for: 1.5)
    }

    /// Returns false to let macOS handle the key normally (e.g. the output
    /// device has no volume control, or the lid is closed).
    private func handleMediaKey(_ key: MediaKeyInterceptor.Key, fineStep: Bool) -> Bool {
        let step: Float = fineStep ? 1.0 / 64 : 1.0 / 16 // same steps as macOS

        func stepped(_ value: Float, up: Bool) -> Float {
            min(max(((value / step).rounded() + (up ? 1 : -1)) * step, 0), 1)
        }

        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard let device = SystemVolume.defaultOutputDevice,
                  SystemVolume.canSetVolume(of: device),
                  var volume = SystemVolume.volume(of: device)
            else { return false }
            var muted = SystemVolume.isMuted(device)
            if key == .mute {
                muted.toggle()
                SystemVolume.setMuted(muted, device: device)
            } else {
                volume = stepped(volume, up: key == .volumeUp)
                SystemVolume.setVolume(volume, of: device)
                if muted { // like macOS, changing the volume unmutes
                    muted = false
                    SystemVolume.setMuted(false, device: device)
                }
            }
            showVolumeHUD(volume, muted: muted)
            return true

        case .brightnessUp, .brightnessDown:
            guard let brightness = DisplayBrightness.brightness() else { return false }
            let newBrightness = stepped(brightness, up: key == .brightnessUp)
            DisplayBrightness.setBrightness(newBrightness)
            showBrightnessHUD(newBrightness)
            return true
        }
    }

    /// Turns key interception on/off. If Accessibility permission is missing,
    /// keeps checking for a few minutes so it starts as soon as you grant it.
    private func updateMediaKeyInterception() {
        permissionPoll?.invalidate()
        permissionPoll = nil
        guard settings.replaceSystemHUD else {
            mediaKeys.stop()
            return
        }
        if MediaKeyInterceptor.hasPermission, mediaKeys.start() { return }

        permissionPollAttempts = 0
        let poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccessibilityPermission() }
        }
        RunLoop.main.add(poll, forMode: .common)
        permissionPoll = poll
    }

    private func checkAccessibilityPermission() {
        permissionPollAttempts += 1
        let started = MediaKeyInterceptor.hasPermission && mediaKeys.start()
        if started || permissionPollAttempts > 150 { // give up after ~5 minutes
            permissionPoll?.invalidate()
            permissionPoll = nil
        }
    }

    // MARK: - Full screen

    /// Re-checks when you switch apps or Spaces (entering/leaving full screen
    /// switches Spaces), and once more after the animation settles.
    private func startFullScreenTracking() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshFullScreen()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        MainActor.assumeIsolated { self?.refreshFullScreen() }
                    }
                }
            }
        }
        refreshFullScreen()
    }

    private func refreshFullScreen() {
        guard let screenFrame else { return }
        let videoFullScreen = FullScreenDetector.isVideoFullScreen(screenFrame: screenFrame)
        guard videoFullScreen != isVideoFullScreen else { return }
        isVideoFullScreen = videoFullScreen
        fullScreenLog.notice("Video full screen: \(videoFullScreen)")
        if videoFullScreen, state == .open { close() }
    }

    // MARK: - Mouse & trackpad

    /// Re-checks the mouse position whenever it moves. This is event-driven, so
    /// it costs nothing while the mouse is still. Mouse monitoring (unlike
    /// keyboard monitoring) needs no special permission.
    private func startMouseTracking() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]

        // Mouse moves over other apps' windows (and the menu bar)...
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouse() }
        }) {
            monitors.append(global)
        }
        // ...and over our own window, plus two-finger swipes between pages.
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves.union(.scrollWheel), handler: { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .scrollWheel { self?.handleSwipe(event) } else { self?.checkMouse() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func checkMouse() {
        let mouse = NSEvent.mouseLocation
        switch state {
        case .closed:
            // Watching full screen: the top edge reveals macOS's controls; stay out of the way.
            guard !isVideoFullScreen else { return }
            let size = closedSize
            if hitRect(width: size.width + 20, height: size.height).contains(mouse) {
                open()
            }
        case .open:
            let width = openSize.width + 2 * NotchShape.openTopRadius + 20
            if !hitRect(width: width, height: openSize.height + 10).contains(mouse) {
                close()
            }
        }
    }

    /// Two-finger horizontal swipe on the trackpad switches pages.
    private func handleSwipe(_ event: NSEvent) {
        guard state == .open, availablePages.count > 1 else { return }
        switch event.phase {
        case .began:
            swipeDistance = .zero
        case .changed:
            swipeDistance.width += event.scrollingDeltaX
            swipeDistance.height += event.scrollingDeltaY
        case .ended:
            // Mostly-horizontal and far enough (so scrolling the clipboard list doesn't count).
            if abs(swipeDistance.width) > 40, abs(swipeDistance.width) > abs(swipeDistance.height) * 1.5 {
                select(swipeDistance.width < 0 ? .nowPlaying : .home)
            }
            swipeDistance = .zero
        default:
            break
        }
    }

    /// A rectangle hanging down from the top-center of the screen.
    /// Note: AppKit screen coordinates have y = 0 at the *bottom*.
    private func hitRect(width: CGFloat, height: CGFloat) -> NSRect {
        guard let screen = screenFrame else { return .zero }
        return NSRect(
            x: screen.midX - width / 2,
            y: screen.maxY - height,
            width: width,
            height: height + 2 // include the very top pixel row
        )
    }
}

#if DEBUG
extension NotchViewModel {
    func clearPeek() { peek = nil }
}
#endif
