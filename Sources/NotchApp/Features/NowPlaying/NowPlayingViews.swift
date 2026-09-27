import SwiftUI

/// The full player shown when the notch is open.
struct NowPlayingView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    let info: NowPlayingInfo

    @State private var isHoveringTitle = false

    var body: some View {
        HStack(spacing: 16) {
            // Click the artwork (or title) to jump to the tab/app that's playing.
            Button(action: showSource) {
                ArtworkView(image: nowPlaying.artwork, appIcon: nowPlaying.appIcon, size: 92, cornerRadius: 14)
            }
                .buttonStyle(.plain)
                .help("Show in \(appName)")

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: showSource) {
                        Text(info.title)
                            .font(.system(size: 15, weight: .semibold))
                            .underline(isHoveringTitle)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringTitle = $0 }
                    .help("Show in \(appName)")

                    Text(info.artist.isEmpty ? info.album : info.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                PlaybackProgressView(info: info, tint: Color(nsColor: nowPlaying.accentColor)) { seconds in
                    nowPlaying.seek(to: seconds)
                }

                HStack(spacing: 36) {
                    ControlButton(systemImage: "backward.fill", size: 16) { nowPlaying.previousTrack() }
                    ControlButton(systemImage: info.isPlaying ? "pause.fill" : "play.fill", size: 22) {
                        nowPlaying.togglePlayPause()
                    }
                    ControlButton(systemImage: "forward.fill", size: 16) { nowPlaying.nextTrack() }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var appName: String {
        guard let id = info.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return "app" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func showSource() {
        guard let bundleID = info.appBundleID else { return }
        MediaSourceNavigator.show(bundleID: bundleID, title: info.title)
    }
}

/// Album art with the source app's icon in the corner.
struct ArtworkView: View {
    let image: NSImage?
    let appIcon: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let appIcon, size > 40 {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: size * 0.32, height: size * 0.32)
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
    }
}

/// Progress bar with elapsed/remaining time. Drag or click it to seek.
struct PlaybackProgressView: View {
    let info: NowPlayingInfo
    let tint: Color
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    var body: some View {
        // Redraws twice a second; only exists while the notch is open.
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = info.duration ?? 0
            let elapsed = dragFraction.map { $0 * duration } ?? info.elapsed(at: context.date)
            let fraction = duration > 0 ? elapsed / duration : 0

            HStack(spacing: 8) {
                // One line, sized to fit; hour-long media get room for "1:32:31".
                Text(formatTime(elapsed))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: duration >= 3600 ? 48 : 34, alignment: .trailing)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(tint)
                            .frame(width: geo.size.width * fraction)
                    }
                    .frame(height: dragFraction == nil ? 5 : 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { _ in
                                if let dragFraction, duration > 0 { onSeek(dragFraction * duration) }
                                dragFraction = nil
                            }
                    )
                    .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
                }
                .frame(height: 14)
                .disabled(duration <= 0)

                Text("-" + formatTime(max(duration - elapsed, 0)))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: duration >= 3600 ? 52 : 38, alignment: .leading)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

private struct ControlButton: View {
    let systemImage: String
    let size: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(isHovering ? 0.12 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Decorative "equalizer" bars. (Real audio levels would need screen-recording
/// permission, so we animate random heights like most notch apps do.)
///
/// Animated with Core Animation rather than SwiftUI: the animation runs in the
/// system's render server, so the app itself uses ~0% CPU. (A SwiftUI
/// timer-driven version used ~5% CPU for as long as music played.)
struct AudioBarsView: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> AudioBarsNSView { AudioBarsNSView() }

    func updateNSView(_ view: AudioBarsNSView, context: Context) {
        view.color = color
    }
}

final class AudioBarsNSView: NSView {
    private let barCount = 4
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let maxHeight: CGFloat = 14
    private var bars: [CALayer] = []

    var color: NSColor = .white {
        didSet { bars.forEach { $0.backgroundColor = color.cgColor } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = color.cgColor
            bar.cornerRadius = barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(barCount) * (barWidth + spacing) - spacing, height: maxHeight)
    }

    override func layout() {
        super.layout()
        let startX = (bounds.width - intrinsicContentSize.width) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit animation when positioning
        for (index, bar) in bars.enumerated() {
            bar.frame = CGRect(x: startX + CGFloat(index) * (barWidth + spacing),
                               y: (bounds.height - maxHeight) / 2,
                               width: barWidth, height: maxHeight)
        }
        CATransaction.commit()
        startAnimating()
    }

    /// Each bar loops through its own random heights at its own speed, so the
    /// bars never move in sync. Added once; repeats forever.
    private func startAnimating() {
        for bar in bars where bar.animation(forKey: "bounce") == nil {
            let steps = 6
            var scales = (0..<steps).map { _ in CGFloat.random(in: 0.25...1.0) }
            scales.append(scales[0]) // loop seamlessly

            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = scales
            animation.calculationMode = .cubic // smooth curves between heights
            animation.duration = Double.random(in: 1.4...2.0)
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.timeOffset = Double.random(in: 0...animation.duration)
            bar.add(animation, forKey: "bounce")
        }
    }
}
