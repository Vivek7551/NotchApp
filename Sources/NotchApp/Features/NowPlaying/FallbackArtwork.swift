import AppKit

/// Artwork to show when the playing app doesn't provide any.
enum FallbackArtwork {
    /// A colorful diagonal gradient (pink → orange → purple style). Each title
    /// gets its own colors, and the same title always gets the same ones.
    static func gradient(for title: String) -> NSImage {
        let hue = Double(stableHash(title) % 360) / 360
        func color(_ offset: Double) -> NSColor {
            let shifted = (hue + offset).truncatingRemainder(dividingBy: 1)
            return NSColor(hue: shifted < 0 ? shifted + 1 : shifted, saturation: 0.75, brightness: 1, alpha: 1)
        }
        let colors = [color(0), color(0.15), color(-0.13)]
        return NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: 45)
            return true
        }
    }

    /// FNV-1a. (Swift's `hashValue` changes every launch, so it can't be used
    /// for "same title → same colors".)
    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return hash
    }
}

/// Thumbnails for YouTube and YouTube Music, by video ID.
enum YouTubeThumbnail {
    /// Finds the video ID in URLs like youtube.com/watch?v=ID, youtu.be/ID,
    /// youtube.com/shorts/ID and music.youtube.com/watch?v=ID.
    static func videoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        var id: String?
        if host == "youtu.be" {
            id = url.pathComponents.dropFirst().first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if url.path == "/watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value
            } else if url.pathComponents.count >= 3, ["shorts", "embed", "live"].contains(url.pathComponents[1]) {
                id = url.pathComponents[2]
            }
        }
        // Video IDs are 11 characters of letters, digits, - and _.
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return id
    }

    /// Downloads the thumbnail: the HD version if the video has one, otherwise
    /// the medium one (every video has it). Both are 16:9 without black bars.
    static func fetch(videoID: String) async -> Data? {
        for name in ["hq720.jpg", "mqdefault.jpg"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(name)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                return data
            }
        }
        return nil
    }
}

/// Decides whether the artwork in each Now Playing update really belongs to
/// the current track.
///
/// When playback switches between browser tabs, Safari can briefly send the
/// new title together with the *previous* video's picture. So a picture
/// belongs to the track it first arrived with; if it shows up again with a
/// different track, it's a leftover and is ignored. (Exception: songs from
/// the same album share a cover.)
struct ArtworkTracker {
    enum Decision: Equatable {
        case unchanged          // keep showing what's on screen
        case useNew(String)     // new artwork (base64) for this track
        case fallback           // no trustworthy artwork: use thumbnail/gradient
    }

    private var base64: String?
    private var ownerTrack: String?
    private var ownerAlbum = ""
    /// A leftover picture we rejected for a track (in case it's sent again).
    private var rejected: (track: String, base64: String)?

    mutating func update(track: String, album: String, base64 newBase64: String?) -> Decision {
        guard let newBase64 else {
            base64 = nil
            ownerTrack = nil
            return .fallback
        }
        if let rejected, rejected.track == track, rejected.base64 == newBase64 {
            return .fallback // still the leftover
        }
        if newBase64 != base64 {
            base64 = newBase64
            ownerTrack = track
            ownerAlbum = album
            return .useNew(newBase64)
        }
        if track == ownerTrack { return .unchanged }
        if !album.isEmpty, album == ownerAlbum { // next song from the same album
            ownerTrack = track
            return .unchanged
        }
        rejected = (track, newBase64) // the previous track's leftover picture
        return .fallback
    }

    mutating func reset() {
        self = ArtworkTracker()
    }
}
