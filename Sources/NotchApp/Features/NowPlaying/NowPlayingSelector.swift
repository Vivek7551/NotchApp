import Foundation

/// Decides which Now Playing item the notch shows.
///
/// Safari keeps flipping its Now Playing report between the tab that's
/// playing and other (paused) YouTube tabs, e.g. when you switch tabs. The
/// notch should stick with what's playing and only switch when a different
/// item actually starts playing.
struct NowPlayingSelector {
    enum Decision: Equatable { case show, ignore }

    /// If the playing item isn't reported for this long while others are,
    /// assume it's gone (e.g. its tab was closed) and move on.
    static let staleAfter: TimeInterval = 20

    private(set) var shownIdentity: String?
    private(set) var shownIsPlaying = false
    private(set) var shownLastSeen = Date.distantPast

    mutating func consider(identity: String, isPlaying: Bool, now: Date = Date()) -> Decision {
        let accept = shownIdentity == nil           // nothing shown yet
            || identity == shownIdentity            // update for what's shown (e.g. paused, new position)
            || isPlaying                            // a different item started playing
            || (shownIsPlaying && now.timeIntervalSince(shownLastSeen) > Self.staleAfter)
        guard accept else { return .ignore }        // a paused item from another tab
        shownIdentity = identity
        shownIsPlaying = isPlaying
        shownLastSeen = now
        return .show
    }

    /// For instant UI updates when you press play/pause in the notch.
    mutating func setShownIsPlaying(_ isPlaying: Bool) {
        shownIsPlaying = isPlaying
    }

    mutating func reset() {
        self = NowPlayingSelector()
    }
}
