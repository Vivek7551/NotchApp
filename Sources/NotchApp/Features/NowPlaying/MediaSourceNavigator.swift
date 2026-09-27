import AppKit

/// Finds the browser tab (or app) that's playing, using AppleScript:
/// - `show` brings you to it (when you click the title/artwork).
/// - `matchingTabs` lists candidate tabs (to fetch a YouTube thumbnail).
///
/// The first time, macOS asks "NotchApp wants to control Safari"
/// (Automation permission).
@MainActor
enum MediaSourceNavigator {
    /// Browsers that use Chrome's AppleScript dictionary.
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    ]

    static func isScriptableBrowser(_ bundleID: String) -> Bool {
        bundleID == "com.apple.Safari" || chromiumBrowsers.contains(bundleID)
    }

    /// Brings the playing tab (or app) to the front.
    static func show(bundleID: String, title: String) {
        guard isScriptableBrowser(bundleID) else { return activate(bundleID) }
        matchingTabs(bundleID: bundleID, title: title) { tabs in
            guard let tab = TabMatcher.bestTab(in: tabs, mediaTitle: title),
                  let source = selectScript(bundleID: bundleID, url: tab.url)
            else { return activate(bundleID) }
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if error != nil { activate(bundleID) }
        }
    }

    /// Tabs whose title contains the media title. Runs `osascript` in the
    /// background, so the UI never waits on the browser (or on the permission
    /// prompt the first time).
    static func matchingTabs(bundleID: String, title: String,
                             completion: @escaping @MainActor @Sendable ([BrowserTab]) -> Void) {
        guard let source = listScript(bundleID: bundleID, title: title) else { return completion([]) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // One tab per line: "<title>\t<url>"
            let tabs = text.split(separator: "\n").compactMap { line -> BrowserTab? in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, let url = URL(string: String(parts[1])) else { return nil }
                return BrowserTab(title: String(parts[0]), url: url)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(tabs) }
            }
        }
        do {
            try process.run()
        } catch {
            completion([])
        }
    }

    private static func activate(_ bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    }

    // MARK: - Scripts

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Safari calls a tab's title "name"; Chrome-based browsers call it "title".
    private static func target(for bundleID: String) -> (app: String, titleProperty: String)? {
        if bundleID == "com.apple.Safari" { return (#"application "Safari""#, "name") }
        if chromiumBrowsers.contains(bundleID) { return ("application id \"\(bundleID)\"", "title") }
        return nil
    }

    private static func listScript(bundleID: String, title: String) -> String? {
        // Tab titles usually contain the media title, e.g. "<title> - YouTube".
        // Trim first: titles can end in invisible no-break spaces.
        let key = escaped(String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)))
        guard !key.isEmpty, let (app, titleProperty) = target(for: bundleID) else { return nil }
        return """
        set output to ""
        tell \(app)
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if \(titleProperty) of t contains "\(key)" then
                            set output to output & (\(titleProperty) of t) & (character id 9) & (URL of t) & (character id 10)
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return output
        """
    }

    private static func selectScript(bundleID: String, url: URL) -> String? {
        let address = escaped(url.absoluteString)
        if bundleID == "com.apple.Safari" {
            return """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is "\(address)" then
                            set current tab of w to t
                            set miniaturized of w to false
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        }
        guard chromiumBrowsers.contains(bundleID) else { return nil }
        return """
        tell application id "\(bundleID)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if (URL of t) is "\(address)" then
                        set active tab index of w to i
                        set minimized of w to false
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }
}

struct BrowserTab: Equatable {
    let title: String
    let url: URL
}

/// Picks which browser tab is the one playing, from the tabs whose title
/// contains the media title.
enum TabMatcher {
    /// For thumbnails: the YouTube video tab that's *clearly* the one playing,
    /// or nil if it's ambiguous (better no thumbnail than a wrong one).
    static func youtubeVideoTab(in tabs: [BrowserTab], mediaTitle: String) -> BrowserTab? {
        let videos = tabs.filter { YouTubeThumbnail.videoID(from: $0.url) != nil }
        let videoIDs = Set(videos.compactMap { YouTubeThumbnail.videoID(from: $0.url) })
        if videoIDs.count == 1 { return videos.first } // one video (maybe open in several tabs)

        let target = normalized(mediaTitle)
        let exact = videos.filter { normalized($0.title) == target }
        let exactIDs = Set(exact.compactMap { YouTubeThumbnail.videoID(from: $0.url) })
        return exactIDs.count == 1 ? exact.first : nil
    }

    /// For "take me there": best guess. Prefers the playing YouTube video,
    /// then an exact title match, and skips YouTube pages that aren't videos
    /// (e.g. search results titled "<song> - YouTube").
    static func bestTab(in tabs: [BrowserTab], mediaTitle: String) -> BrowserTab? {
        if let video = youtubeVideoTab(in: tabs, mediaTitle: mediaTitle) { return video }
        let candidates = tabs.filter { tab in
            let isYouTube = tab.url.host?.lowercased().hasSuffix("youtube.com") == true
            return !isYouTube || YouTubeThumbnail.videoID(from: tab.url) != nil
        }
        let target = normalized(mediaTitle)
        return candidates.first { normalized($0.title) == target } ?? candidates.first ?? tabs.first
    }

    /// "(3) Song Name - YouTube" → "song name"
    static func normalized(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { // unread-notification count
            text.removeSubrange(range)
        }
        for suffix in [" - YouTube Music", " - YouTube"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
