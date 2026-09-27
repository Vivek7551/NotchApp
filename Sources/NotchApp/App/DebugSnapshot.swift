#if DEBUG
import AppKit
import SwiftUI

/// Debug helper: `NotchApp --snapshot <folder>` renders the notch in several
/// states to PNG files, then exits. Handy for checking the design without
/// needing screen-recording permission.
///
/// Note: ImageRenderer can't draw AppKit-backed views, so the Core Animation
/// equalizer bars appear as a placeholder in these images.
enum DebugSnapshot {
    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return false }
        let folder = URL(fileURLWithPath: args[index + 1])
        func save(_ vm: NotchViewModel, _ name: String) {
            render(vm, to: folder.appendingPathComponent("notch-\(name).png"))
        }

        let vm = NotchViewModel()
        if let size = NSScreen.notched?.notchSize { vm.notchSize = size }
        vm.battery.showPreview(BatteryStatus(percent: 80, isPluggedIn: true, isCharging: true, minutesRemaining: 40))

        save(vm, "closed-idle")

        vm.showPeek(Peek(id: "volume", icon: "speaker.wave.2.fill", tint: .white, value: .level(0.56)), for: 60)
        save(vm, "closed-volume")
        vm.showPeek(Peek(id: "battery", icon: "bolt.fill", tint: .green, value: .text("80%")), for: 60)
        save(vm, "closed-charging")
        vm.showPeek(Peek(id: "focus", icon: "moon.fill", tint: .indigo, value: .text("Do Not Disturb")), for: 60)
        save(vm, "closed-focus")
        vm.clearPeek()

        vm.timer.showPreview(remaining: 18 * 60 + 42, total: 25 * 60, pomodoro: true)
        vm.privacy.showPreview(mic: true, camera: false)
        save(vm, "closed-timer-mic")

        vm.nowPlaying.showPreview(sampleTrack, artwork: sampleArtwork())
        save(vm, "closed-music-timer-mic")

        vm.focus.showPreview(FocusService.Focus(name: "Work", symbol: "briefcase.fill"))
        vm.clipboard.showPreview([
            "https://github.com/ungive/mediaremote-adapter",
            "brew install --cask notchapp",
            "Meeting moved to 4:30 pm — same link as before",
            "let openSize = CGSize(width: 600, height: 190)",
        ])
        vm.open()
        vm.select(.home)
        save(vm, "open-home")
        vm.select(.nowPlaying)
        save(vm, "open-music")
        vm.nowPlaying.showPreview(NowPlayingInfo(
            title: "Tere Bina", artist: "A.R. Rahman, Chinmayi", album: "Guru", duration: 310, elapsedTime: 42,
            timestamp: Date(), playbackRate: 1, isPlaying: true, appBundleID: "com.apple.Safari"), artwork: nil)
        save(vm, "open-music-no-artwork")
        vm.nowPlaying.showPreview(NowPlayingInfo(
            title: "Raja Raja Chora - Tamil Movie - Sreevishnu, Megha Akash, Sunaina", artist: "Zee Movies Tamil",
            album: "", duration: 49 * 60 + 28 + 5481, elapsedTime: 49 * 60 + 28,
            timestamp: Date(), playbackRate: 1, isPlaying: true, appBundleID: "com.apple.Safari"), artwork: nil)
        save(vm, "open-music-long")
        vm.nowPlaying.showPreview(sampleTrack, artwork: sampleArtwork())

        vm.timer.stop()
        vm.select(.home)
        save(vm, "open-home-idle-timer")
        return true
    }

    private static let sampleTrack = NowPlayingInfo(
        title: "Oosupodu",
        artist: "Hemachandra · Fidaa",
        album: "Fidaa",
        duration: 345,
        elapsedTime: 94,
        timestamp: Date(),
        playbackRate: 1,
        isPlaying: true,
        appBundleID: "com.apple.Safari"
    )

    /// A colorful placeholder "album cover".
    private static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [.systemPink, .systemOrange, .systemPurple])?.draw(in: rect, angle: 45)
            return true
        }
    }

    @MainActor
    private static func render(_ vm: NotchViewModel, to url: URL) {
        let view = NotchView(vm: vm)
            .frame(width: vm.windowSize.width, height: vm.windowSize.height)
            .background(Color(white: 0.82)) // stand-in for the menu bar / wallpaper
            .environment(\.isSnapshot, true)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            print("Failed to render \(url.lastPathComponent)")
            return
        }
        do {
            try png.write(to: url)
            print("Saved \(url.path)")
        } catch {
            print("Failed to save \(url.path): \(error)")
        }
    }
}
#endif
