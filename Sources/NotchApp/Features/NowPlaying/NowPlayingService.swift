import AppKit
import CoreImage.CIFilterBuiltins
import os

/// Read with: /usr/bin/log show --last 10m --predicate 'subsystem == "com.local.NotchApp"'
private let artworkLog = Logger(subsystem: "com.local.NotchApp", category: "Artwork")
private let nowPlayingLog = Logger(subsystem: "com.local.NotchApp", category: "NowPlaying")

/// A snapshot of what's currently playing, from any app.
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double?     // seconds
    var elapsedTime: Double?  // seconds, as of `timestamp`
    var timestamp: Date?
    var playbackRate: Double
    var isPlaying: Bool
    /// The app to show as the source, e.g. Safari for a YouTube video.
    var appBundleID: String?

    /// Playback position right now. The adapter only reports the position when
    /// something changes, so we extrapolate from the last report.
    func elapsed(at date: Date) -> Double {
        guard var elapsed = elapsedTime else { return 0 }
        if isPlaying, let timestamp {
            elapsed += date.timeIntervalSince(timestamp) * (playbackRate > 0 ? playbackRate : 1)
        }
        if let duration { elapsed = min(elapsed, duration) }
        return max(0, elapsed)
    }
}

/// Reads system-wide "Now Playing" info (the same data Control Center shows).
///
/// Since macOS 15.4, apps can't read this directly. We run the bundled
/// open-source `mediaremote-adapter` through `/usr/bin/perl`, which Apple
/// still allows, and read its JSON output line by line.
@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var artwork: NSImage?
    /// A color picked from the artwork, used to tint the audio bars.
    @Published private(set) var accentColor: NSColor = .white
    @Published private(set) var appIcon: NSImage?
    /// Last moment something was playing; lets the player page stick around
    /// for a while after you pause.
    @Published private(set) var lastPlayedAt: Date?

    private var process: Process?
    private var lineBuffer = Data()
    private var raw: [String: Any] = [:]   // latest merged payload from the adapter
    /// Decides whether each update's artwork really belongs to the track.
    private var artworkTracker = ArtworkTracker()
    /// The track (app + title) we're showing fallback artwork for.
    private var fallbackTrack: String?
    /// YouTube thumbnails already downloaded, by video ID.
    private var thumbnailCache: [String: NSImage] = [:]
    /// Keeps the notch on what's playing when Safari flips to paused tabs.
    private var selector = NowPlayingSelector()
    private var staleCheck: DispatchWorkItem?
    private var pendingClear: DispatchWorkItem?
    private var isStopping = false
    private var restartDelay: TimeInterval = 1

    private static let scriptPath = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl")
    private static let frameworkPath = Bundle.main.privateFrameworksURL?
        .appendingPathComponent("MediaRemoteAdapter.framework").path

    // MARK: - Streaming

    func start() {
        guard process == nil else { return }
        isStopping = false

        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil // end of stream
                return
            }
            DispatchQueue.main.async { [weak self] in // main queue keeps chunks in order
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }

        guard let process = makeAdapterProcess(["stream", "--micros", "--debounce=50"], output: pipe) else { return }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.adapterDidExit() }
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            print("NowPlaying: failed to start adapter: \(error)")
        }
    }

    func stop() {
        isStopping = true
        process?.terminate()
        process = nil
    }

    /// Restart the adapter if it quits unexpectedly, waiting a bit longer each time.
    private func adapterDidExit() {
        process = nil
        lineBuffer.removeAll()
        guard !isStopping else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
        restartDelay = min(restartDelay * 2, 30)
    }

    /// The adapter prints one JSON object per line; chunks can split lines.
    private func receive(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            handleLine(line)
        }
    }

    /// Each line looks like `{"type":"data","diff":true,"payload":{...}}`.
    /// A diff only contains changed keys (null = removed); otherwise it's the full state.
    private func handleLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data",
              let payload = object["payload"] as? [String: Any]
        else { return }

        restartDelay = 1 // healthy again
        if object["diff"] as? Bool == true {
            for (key, value) in payload {
                if value is NSNull { raw.removeValue(forKey: key) } else { raw[key] = value }
            }
        } else {
            raw = payload
        }
        applyRawPayload()
    }

    private func applyRawPayload() {
        guard let title = raw["title"] as? String else {
            // Might just be the browser switching between tabs: wait a moment
            // before deciding nothing is playing.
            guard info != nil, pendingClear == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.clearNowPlaying() }
            }
            pendingClear = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            return
        }
        pendingClear?.cancel()
        pendingClear = nil

        let bundleID = ((raw["parentApplicationBundleIdentifier"] as? String) ?? (raw["bundleIdentifier"] as? String))
            .map { $0.components(separatedBy: ".helper").first ?? $0 } // "com.google.Chrome.helper" → Chrome
        let candidate = NowPlayingInfo(
            title: title,
            artist: raw["artist"] as? String ?? "",
            album: raw["album"] as? String ?? "",
            duration: (raw["durationMicros"] as? Double).map { $0 / 1_000_000 },
            elapsedTime: (raw["elapsedTimeMicros"] as? Double).map { $0 / 1_000_000 },
            timestamp: (raw["timestampEpochMicros"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000_000) },
            playbackRate: raw["playbackRate"] as? Double ?? 1,
            isPlaying: raw["playing"] as? Bool ?? false,
            appBundleID: bundleID
        )

        let identity = "\(bundleID ?? "")|\(title.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard selector.consider(identity: identity, isPlaying: candidate.isPlaying) == .show else {
            nowPlayingLog.notice("Ignoring a paused item from another tab; still showing what's playing")
            scheduleStaleCheck()
            return
        }
        staleCheck?.cancel()
        staleCheck = nil

        if bundleID != info?.appBundleID {
            appIcon = bundleID
                .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        info = candidate
        updateArtwork(base64: raw["artworkData"] as? String)
        if candidate.isPlaying { lastPlayedAt = Date() }
    }

    /// While ignoring other tabs, re-check once the playing item has gone
    /// quiet long enough to be considered gone (e.g. its tab was closed).
    private func scheduleStaleCheck() {
        guard selector.shownIsPlaying else { return }
        staleCheck?.cancel()
        let deadline = selector.shownLastSeen.addingTimeInterval(NowPlayingSelector.staleAfter + 0.5)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.applyRawPayload() }
        }
        staleCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, deadline.timeIntervalSinceNow), execute: work)
    }

    private func clearNowPlaying() {
        pendingClear = nil
        selector.reset()
        info = nil
        updateArtwork(base64: nil)
        appIcon = nil
    }

    /// Artwork, in order of preference:
    /// 1. what the app gives macOS,
    /// 2. for YouTube / YouTube Music in a browser: the video's thumbnail,
    /// 3. a colorful gradient.
    private func updateArtwork(base64: String?) {
        guard let info else {
            artworkTracker.reset()
            fallbackTrack = nil
            setArtwork(nil)
            return
        }
        let track = "\(info.appBundleID ?? "")|\(info.title)"

        switch artworkTracker.update(track: track, album: info.album, base64: base64) {
        case .unchanged:
            return
        case .useNew(let base64):
            fallbackTrack = nil
            setArtwork(Data(base64Encoded: base64).flatMap { NSImage(data: $0) })
        case .fallback:
            guard track != fallbackTrack else { return } // already handled this track
            fallbackTrack = track
            setArtwork(FallbackArtwork.gradient(for: info.title)) // show something right away
            if let bundleID = info.appBundleID, MediaSourceNavigator.isScriptableBrowser(bundleID) {
                loadYouTubeThumbnail(bundleID: bundleID, title: info.title, track: track)
            }
        }
    }

    /// Right after a video starts, YouTube may not have updated the tab's
    /// title yet, so if nothing matches we look again a little later.
    private static let lookupRetryDelays: [TimeInterval] = [1.5, 4]

    private func loadYouTubeThumbnail(bundleID: String, title: String, track: String, attempt: Int = 0) {
        artworkLog.notice("No artwork for this track; looking for its YouTube tab (attempt \(attempt + 1))")
        MediaSourceNavigator.matchingTabs(bundleID: bundleID, title: title) { [weak self] tabs in
            guard let self, self.fallbackTrack == track else { return } // track changed meanwhile
            guard let tab = TabMatcher.youtubeVideoTab(in: tabs, mediaTitle: title),
                  let videoID = YouTubeThumbnail.videoID(from: tab.url)
            else {
                artworkLog.notice("\(tabs.count) tab(s) matched, none clearly the playing YouTube video")
                if attempt < Self.lookupRetryDelays.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookupRetryDelays[attempt]) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.fallbackTrack == track else { return }
                            self.loadYouTubeThumbnail(bundleID: bundleID, title: title, track: track, attempt: attempt + 1)
                        }
                    }
                }
                return
            }
            artworkLog.notice("\(tabs.count) tab(s) matched; using the YouTube video's thumbnail")
            if let cached = self.thumbnailCache[videoID] {
                self.setArtwork(cached)
                return
            }
            Task {
                guard let data = await YouTubeThumbnail.fetch(videoID: videoID),
                      let image = NSImage(data: data)
                else {
                    artworkLog.error("YouTube thumbnail download failed; using gradient")
                    return
                }
                self.thumbnailCache[videoID] = image
                if self.fallbackTrack == track { self.setArtwork(image) } // still the same track?
            }
        }
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        accentColor = image?.vibrantAverageColor ?? .white
    }

    // MARK: - Controls

    /// Sends an explicit "pause" or "play" rather than "toggle": Safari may
    /// briefly treat another (paused) tab as current, and a toggle would
    /// start *that* tab. Pausing an already-paused tab does nothing.
    func togglePlayPause() {
        guard var current = info else { return }
        send(command: current.isPlaying ? 1 : 0) // 1 = pause, 0 = play
        current.isPlaying.toggle() // update the UI instantly; the stream confirms shortly after
        info = current
        selector.setShownIsPlaying(current.isPlaying)
        lastPlayedAt = Date()
    }

    func nextTrack() { send(command: 4) }
    func previousTrack() { send(command: 5) }

    func seek(to seconds: Double) {
        if var current = info { // optimistic update
            current.elapsedTime = seconds
            current.timestamp = Date()
            info = current
        }
        runOneShot(["seek", String(Int(seconds * 1_000_000))])
    }

    /// MediaRemote command IDs: 0 play, 1 pause, 4 next, 5 previous.
    private func send(command: Int) {
        runOneShot(["send", String(command)])
    }

    private func runOneShot(_ arguments: [String]) {
        guard let process = makeAdapterProcess(arguments, output: nil) else { return }
        try? process.run()
    }

    private func makeAdapterProcess(_ arguments: [String], output: Pipe?) -> Process? {
        guard let script = Self.scriptPath, let framework = Self.frameworkPath,
              FileManager.default.fileExists(atPath: framework)
        else {
            print("NowPlaying: adapter not found in app bundle")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script, framework] + arguments
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    // MARK: - Debug

    /// Used by `--snapshot` to render the player without real playback.
    func showPreview(_ info: NowPlayingInfo, artwork: NSImage?) {
        self.info = info
        _ = selector.consider(identity: "\(info.appBundleID ?? "")|\(info.title)", isPlaying: info.isPlaying)
        lastPlayedAt = Date()
        setArtwork(artwork ?? FallbackArtwork.gradient(for: info.title))
    }
}

private extension NSImage {
    /// The image's average color, brightened so it stays visible on black.
    var vibrantAverageColor: NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        let color = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        return NSColor(hue: color.hueComponent,
                       saturation: min(color.saturationComponent * 1.3, 1),
                       brightness: max(color.brightnessComponent, 0.75),
                       alpha: 1)
    }
}
