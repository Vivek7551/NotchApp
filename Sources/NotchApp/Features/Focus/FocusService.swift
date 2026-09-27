import Foundation

/// Detects the active Focus mode (Do Not Disturb, Work, Sleep...).
///
/// macOS has no public API for this, so we read the Focus database files in
/// ~/Library/DoNotDisturb/DB. macOS protects that folder, so this only works
/// after you give NotchApp **Full Disk Access** in System Settings.
///
/// Limitation: only Focus modes turned on by hand (Control Center, menu bar,
/// Shortcuts) are detected; ones turned on by a schedule may not be.
@MainActor
final class FocusService: ObservableObject {
    struct Focus: Equatable {
        var name: String
        var symbol: String // SF Symbol name chosen for this Focus in System Settings
    }

    @Published private(set) var current: Focus?
    @Published private(set) var hasAccess = false
    /// Called when Focus turns on (with the mode) or off (nil).
    var onChange: ((Focus?) -> Void)?

    private let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB")
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?

    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    func start() {
        refresh(notify: false)
    }

    /// Re-reads the files. Also call this after granting Full Disk Access.
    func refresh(notify: Bool) {
        // Listing the folder fails without Full Disk Access.
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else {
            hasAccess = false
            current = nil
            return
        }
        hasAccess = true
        startWatchingIfNeeded()

        let assertions = readJSON("Assertions.json") ?? [:]
        let newFocus = activeModeID(in: assertions).map { mode(for: $0) }
        guard newFocus != current else { return }
        current = newFocus
        if notify { onChange?(newFocus) }
    }

    /// macOS rewrites these files whenever Focus changes; watch the folder.
    private func startWatchingIfNeeded() {
        guard watcher == nil else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    /// Files are often written several times in a row; wait for them to settle.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh(notify: true) }
        }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Parsing
    //
    // Assertions.json:         { "data": [ { "storeAssertionRecords": [ { "assertionDetails":
    //                             { "assertionDetailsModeIdentifier": "com.apple.focus.work" } } ] } ] }
    // ModeConfigurations.json: { "data": [ { "modeConfigurations": { "<id>":
    //                             { "mode": { "name": "Work", "symbolImageName": "briefcase.fill" } } } } ] }

    private func activeModeID(in assertions: [String: Any]) -> String? {
        let data = assertions["data"] as? [[String: Any]]
        let records = data?.first?["storeAssertionRecords"] as? [[String: Any]]
        let details = records?.first?["assertionDetails"] as? [String: Any]
        return details?["assertionDetailsModeIdentifier"] as? String
    }

    private func mode(for id: String) -> Focus {
        let data = readJSON("ModeConfigurations.json")?["data"] as? [[String: Any]]
        let configs = data?.first?["modeConfigurations"] as? [String: Any]
        let mode = (configs?[id] as? [String: Any])?["mode"] as? [String: Any]
        return Focus(
            name: mode?["name"] as? String ?? "Do Not Disturb",
            symbol: mode?["symbolImageName"] as? String ?? "moon.fill"
        )
    }

    private func readJSON(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

#if DEBUG
extension FocusService {
    func showPreview(_ focus: Focus?) {
        hasAccess = true
        current = focus
    }
}
#endif
