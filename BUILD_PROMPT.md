# Prompt: Build "NotchApp" — a Dynamic Island for the MacBook notch

Copy everything below the line into a new Claude Code session.

---

You are building **NotchApp**, a personal-use macOS menu-bar app that turns the MacBook camera notch into an interactive "Dynamic Island". Build the **complete** app described here in one go, verify it as described in *Testing & verification*, and then give me a short summary of what works, what you tested, and anything you couldn't test.

## About me and how to work with me

- I'm **new to Swift/macOS development**. Keep code readable, with short comments that explain *why* (not what). Explain decisions in plain language.
- **Be honest** about what you actually tested vs. what you couldn't. Never claim something works without evidence.
- **Don't disrupt my Mac** while testing: don't play/pause my media, don't switch my browser tabs, don't move my cursor, don't grant/revoke permissions or change system settings yourself. For anything that needs me (permissions, keychain prompts, `tccutil`), give me exact steps/commands to run.
- When you finish, tell me exactly how to **start, stop, and restart** the app.

## My machine

- MacBook Air M3, **macOS 26.6**, built-in notch display (1470×956 pt; notch ≈ **179 × 32 pt**, read it at runtime — don't hardcode).
- Xcode is installed and its license accepted. An **"Apple Development"** code-signing certificate is in my login keychain (the Apple WWDR **G3** intermediate is installed).
- Project folder: `~/NotchApp`. Bundle ID: `com.local.NotchApp`.

## Tech stack & build

- **Swift + SwiftUI** for UI, **AppKit** for windows/system integration. **Swift Package Manager** executable target (no `.xcodeproj` needed); `platforms: [.macOS(.v14)]`, `swift-tools-version:5.10`.
- Must compile cleanly with **strict concurrency + warnings as errors**:
  `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  (Services are `@MainActor`; use `MainActor.assumeIsolated` inside main-queue callbacks; capture `[weak self]` in *each* nested escaping closure; wrap immutable non-Sendable framework objects in a small `@unchecked Sendable` box when crossing threads; `@preconcurrency import` for CoreGraphics/ScreenCaptureKit-era APIs if needed; constrain generic CoreAudio helpers to `BitwiseCopyable`.)
- `build.sh` (`./build.sh` and `./build.sh run`): `swift build`, assemble `build/NotchApp.app` (MacOS/, Resources/, Frameworks/, Info.plist), copy the Now Playing helper + its LICENSE, then **code-sign inside-out** (framework first, then app).
  - **Signing:** auto-detect a valid identity (`security find-identity -v -p codesigning`, prefer "Apple Development"; allow `SIGN_IDENTITY` override); fall back to ad-hoc (`-`) with a warning. Reason: macOS privacy permissions (TCC) are tied to the code signature — ad-hoc signatures change every build, so Accessibility/Full Disk Access would be forgotten after every rebuild.
  - `run`: `pkill -x NotchApp`, `sleep 1` (avoids LaunchServices error -600), `open` the app.
- `Info.plist`: `LSUIElement = true` (menu-bar app, no Dock icon), `LSMinimumSystemVersion 14.0`, `NSHighResolutionCapable`, and `NSAppleEventsUsageDescription` ("NotchApp switches to the browser tab that is playing media when you click it in the notch.").
- `.gitignore`: `.build/`, `build/`, `.swiftpm/`, `Vendor/build/`, `.DS_Store`.

### Suggested file layout
```
Sources/NotchApp/
  App/        AppDelegate.swift (entry point, menu), AppSettings.swift, DebugSnapshot.swift
  Notch/      NotchPanel, NotchShape, NotchView, OpenNotchView, NotchViewModel,
              NSScreen+Notch, FullScreenDetector
  Home/       HomeView.swift (cards + shared small components)
  Features/
    NowPlaying/ NowPlayingService, NowPlayingSelector, NowPlayingViews,
                FallbackArtwork (gradient, YouTube thumbnail, ArtworkTracker),
                MediaSourceNavigator (tab lookup/switching, TabMatcher)
    Battery/    BatteryService
    HUD/        SystemVolume (+VolumeObserver), DisplayBrightness, MediaKeyInterceptor
    Timer/      TimerService, TimerViews
    Clipboard/  ClipboardService, ClipboardCard
    Focus/      FocusService
    Privacy/    PrivacyMonitor
Vendor/       mediaremote-adapter (git clone), build-adapter.sh, build/ (compiled framework)
Support/Info.plist, build.sh, Package.swift
```

## 1. The notch window

- Entry point: `@main` AppKit `AppDelegate` with `static func main()`; `setActivationPolicy(.accessory)`.
- Find the notched screen: `NSScreen.screens.first { $0.safeAreaInsets.top > 0 }`; notch size = `frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width` × `safeAreaInsets.top`. Re-layout on `NSApplication.didChangeScreenParametersNotification`; hide the panel when no notched screen (lid closed).
- `NSPanel` subclass: `[.borderless, .nonactivatingPanel]`, clear background, not opaque, no shadow (SwiftUI draws it), not movable, `level = .mainMenu + 3`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`, `canBecomeKey = true`, `canBecomeMain = false`, override `constrainFrameRect` to return the frame unchanged (so it can sit over the menu bar).
- Fixed-size window at top-center, big enough for the open notch: width = openWidth + 2×openTopRadius + 60, height = openHeight + 40. SwiftUI animates *inside* it. `NSHostingView.sizingOptions = []`. Use an `NSHostingView` subclass that returns `true` from `acceptsFirstMouse` (first click works on buttons).
- `ignoresMouseEvents = true` while closed (clicks pass through to the menu bar), `false` while open.

### Shape & animation
- `NotchShape`: flat top, small outward-curving "ears" at the top corners, rounded bottom corners; animatable `(topRadius, bottomRadius)`. Closed: top 6 / bottom 10. Open: top 16 / bottom 32.
- Black fill, drop shadow only when open (black 45%, radius 14, y 4). Content is laid out at its final size and **revealed by the animating clip shape** (no re-flow mid-animation).
- Springs: open `response 0.42, damping 0.78`; close `0.35, 1.0`; closed-layout changes `0.38, 0.8`.

### Hover
- **Event-driven, no polling**: `NSEvent` global + local monitors for `.mouseMoved`/`.leftMouseDragged` (+ `.scrollWheel` locally). Mouse monitoring needs no permission. Target: **0% CPU when idle**.
- Closed hit area: current closed width + 20 wide × notch height (include the top pixel row). Open: stays open while the cursor is within open width + 2×16 + 20 × open height + 10.
- Optional **haptic** bump on open (`NSHapticFeedbackManager … .levelChange`), setting **"Haptic Feedback"**, default on. (It feels like a click on the trackpad but isn't one.)

## 2. Open notch (600 × 190 pt)

- **Header row** (height = notch height), split around the camera: left = short date ("Sun 27 Sep", secondary); right = Focus symbol (indigo, if on), mic/camera icons (orange mic / green video, tooltip lists mic apps), battery `NN%` + battery symbol (green charging / red low), and a **⚙︎ gear button** that pops up the app menu (see *Menu*). The gear matters because the menu-bar icon can be **hidden behind the notch** when the menu bar is full (this happened to me).
- **Two pages with page dots** at the bottom (active dot is a 14-pt capsule, inactive 6-pt dot):
  - **Home** (always available).
  - **Now Playing** — only while something is playing, or was paused < 5 minutes ago (so it doesn't vanish when you press pause).
  - Dots only appear when there are 2 pages. Switch by clicking dots or **two-finger horizontal swipe** (accumulate `scrollingDeltaX` over a gesture; > 40 pt and mostly horizontal).
  - On open: show the page I last picked if available, else Home. Default preference = Now Playing.
- Layout: horizontal padding 20, body top padding 8, dots row 20 pt.

### Home page (three cards: 150 pt, 196 pt, flexible; cards = 14-pt rounded rect, white 7% fill, padding 10)
- **Clock card**: time (30 pt rounded semibold, `TimelineView(.everyMinute)`), full date, and battery line ("80% · Charging / Plugged in / Charged / On battery").
- **Timer card** (see *Timer*): presets or running view.
- **Clipboard card** (see *Clipboard*).

### Now Playing page
- Artwork 92 pt (14-pt radius) with the **source app's icon** overlapped at the bottom-right (e.g. Safari icon for YouTube).
- Title (15 semibold, one line) and artist/album (12, secondary). **Clicking the title or artwork jumps to the source** (see *Go to source*); underline title on hover; tooltip "Show in Safari".
- Progress bar: capsule 5 pt (8 pt while dragging), tinted with the artwork's accent color; **drag/click to seek**; elapsed on the left, "-remaining" on the right. Time labels must stay on **one line**: `m:ss`, or `h:mm:ss` for ≥ 1 hour (e.g. `49:28 ━━━━ -1:31:20`) — use `lineLimit(1)`, `fixedSize()`, monospaced digits, and a min width that's larger for hour-long media. `TimelineView(.periodic 0.5 s)` only while open; elapsed is extrapolated from `elapsedTime + (now − timestamp) × rate`.
- Controls: previous / play-pause / next (16/22/16 pt symbols, 36 pt spacing, hover highlight).

## 3. Closed notch: live activities & peeks

The closed notch can grow symmetric "wings" left and right of the camera.

- **Peeks** (temporary; take over the whole closed notch): left = SF Symbol icon (tinted), right = text or a level bar. Peeks with the same id update in place (repeated volume steps don't re-pop).
  - Volume: speaker.slash/wave.1/2/3 + white level bar, 1.5 s. Brightness: sun.min/sun.max + bar, 1.5 s. Level wing width 72.
  - Charger plugged in: green bolt + "80%", 3 s. Unplugged: battery symbol + "%", 3 s. Low battery (20 / 10 / 5 %, once each until plugged in): red, "N% left", 5 s.
  - Focus on: its symbol (indigo) + its name, 3 s; off: moon (gray) + "Focus off", 2.5 s.
  - Timer done: orange timer + "Time's up" / "Break time" / "Focus time", 6 s.
  - Text wing width = max(notchHeight + 6, measured text width + 18).
- **Ongoing activities** (when no peek):
  - Music playing: left = small artwork (notch height − 8, 5-pt radius), right = **equalizer bars**. Wing = notch height + 6.
  - Timer running: right = orange countdown (`Text(timerInterval:countsDown:)`, updates without re-rendering our view); left = orange timer icon if no music. Wing ≥ 50.
  - Mic/camera in use: a 6-pt dot after the right content (green camera, orange mic); +10 wing width, or 20-pt wings if nothing else.
- **Equalizer bars must use Core Animation, not SwiftUI** (a SwiftUI timer version cost ~5% CPU and also froze because random values generated *inside* a `ForEach` row don't re-render): `NSViewRepresentable` hosting 4 `CALayer` bars (3 pt wide, 2 pt gap, 14 pt max), each with its own `CAKeyframeAnimation` on `transform.scale.y` (6 random values 0.25–1.0 + first value repeated, `.cubic`, duration random 1.4–2.0 s, repeat forever, random `timeOffset`). Target: **0% app CPU** while music plays. Color = artwork accent color.
- **Accent color**: `CIAreaAverage` of the artwork, saturation ×1.3, brightness ≥ 0.75 (visible on black).

## 4. Now Playing (any app: Apple Music, Spotify, YouTube in Safari/Chrome…)

- Since macOS 15.4 apps can't read MediaRemote directly. Use the open-source **[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)** (BSD-3): `git clone --depth 1` into `Vendor/`, **read its code** (it has no network access), and compile `MediaRemoteAdapter.framework` with **clang** in `Vendor/build-adapter.sh` (no cmake): all `src/adapter/*.m`, `src/private/MediaRemote.m`, `src/utility/*.m`, `-dynamiclib -fobjc-arc -fvisibility=default -arch arm64 -arch x86_64 -mmacosx-version-min=14.0`, link Foundation/AppKit/UniformTypeIdentifiers, `-install_name @rpath/…`, proper framework layout (Versions/A, Current, symlinks, Resources/Info.plist), codesign.
- Run: `/usr/bin/perl <Resources>/mediaremote-adapter.pl <absolute framework path> stream --micros --debounce=50`. Read stdout lines (`{"type":"data","diff":bool,"payload":{…}}`), merge diffs (null = remove key), deliver chunks in order on the main queue. Restart with backoff if it exits; stop it on quit.
- Fields: `title`, `artist`, `album`, `durationMicros`, `elapsedTimeMicros`, `timestampEpochMicros`, `playbackRate`, `playing`, `artworkData` (base64), `bundleIdentifier`, `parentApplicationBundleIdentifier`. **Source app = parent bundle ID if present** (YouTube in Safari reports `com.apple.WebKit.GPU` with parent `com.apple.Safari`); strip `.helper…` suffixes (Chrome helpers). Titles can end in a **no-break space** — trim with `.whitespacesAndNewlines` before matching.
- Commands via one-shot adapter runs: **send explicit play (0) or pause (1), never toggle (2)** — see below. Next 4, previous 5, `seek <micros>`. Update the UI optimistically.

### Stick with what's actually playing (important — observed on my Mac)
Safari keeps **flipping its Now Playing report to other paused YouTube tabs** whenever I switch/open tabs (it happened 5 times in one minute), which made the notch show the wrong title/thumbnail for a couple of seconds. Implement a pure, unit-tested `NowPlayingSelector`:
- Show an update if: nothing is shown yet, **or** it's the same item (identity = source bundle ID + trimmed title) — e.g. paused/new position, **or** the new item **is playing**.
- **Ignore** a *different* item that isn't playing.
- Safety net: if the shown item is playing but hasn't been reported for **20 s** while other items are, move on (its tab was probably closed) — schedule a re-check.
- An empty payload ("nothing playing") may just be a tab switch: wait **1.5 s** before clearing.
- Because Safari may treat a paused tab as "current", a toggle command could start *that* tab — hence explicit play/pause (pausing an already-paused tab does nothing).

### Artwork (priority order)
1. **Artwork from macOS**, validated by a pure, unit-tested `ArtworkTracker`: a picture **belongs to the track it first arrived with**. If a *different* track arrives with the exact same image bytes, it's the previous track's leftover (Safari sends the new title with the old picture for a moment) → reject it, and keep rejecting it for that track if re-sent. Exception: same non-empty album (songs from one album share a cover). Don't add any extra "keep old artwork when it disappears" logic — the adapter already bridges brief drops for the same item, and extra keeping makes wrong pictures stick.
2. **YouTube / YouTube Music thumbnail** when macOS gives no artwork and the source is a browser: find the playing tab (see *Go to source*), take its video ID (`watch?v=`, `youtu.be/`, `/shorts/`, `/embed/`, `/live/`, `music.youtube.com`; 11 chars `[A-Za-z0-9_-]`), download `https://i.ytimg.com/vi/<id>/hq720.jpg`, falling back to `mqdefault.jpg` (both 16:9, no black bars). Cache by video ID. **Only use it when unambiguous** (see `TabMatcher`); YouTube updates the tab title a moment after a video starts, so if nothing matches, **retry after 1.5 s and 4 s**. Discard results if the track changed meanwhile.
3. Otherwise a **colorful diagonal gradient** (pink → orange → purple style, 45°) — **never a plain music note**. Colors are deterministic per title: FNV-1a hash (not Swift's randomized `hashValue`) → hue; colors at hue, hue+0.15, hue−0.13, saturation 0.75, brightness 1.0. The accent color follows the gradient.

### Go to source (click title/artwork)
- `MediaSourceNavigator` via AppleScript (first use triggers macOS's "NotchApp wants to control Safari" prompt).
- **List matching tabs** in the background with `/usr/bin/osascript` (never block the UI, especially during the permission prompt): every tab whose title (`name` in Safari, `title` in Chrome/Brave/Edge/Vivaldi) contains the first 60 chars of the trimmed media title; output `title<TAB>URL` lines (`character id 9/10` — inside `tell "Safari"`, `tab` means the tab class!). Escape `\` and `"`. Wrap each tab check in `try`.
- Pure, unit-tested `TabMatcher`:
  - `normalized(title)`: trim, drop a leading `(3) ` notification count, drop ` - YouTube Music` / ` - YouTube`, lowercase.
  - `youtubeVideoTab` (for thumbnails, strict): among tabs with a video ID, if they're all the same video → it; else the tabs whose normalized title equals the media title, if they're all one video → it; else **nil (don't guess)**.
  - `bestTab` (for navigation): the strict YouTube match if any; else skip YouTube pages that aren't videos (search results are titled "<song> - YouTube"!), prefer an exact normalized title, else the first.
- Select the chosen tab **by its exact URL** (Safari: `set current tab`, un-miniaturize, `set index of w to 1`, `activate`; Chromium: `set active tab index`). Non-browsers (Music, Spotify…): just activate the app.

## 5. Volume & brightness HUD (replaces the macOS HUD)

- **Volume**: CoreAudio `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` via `AudioObjectGet/SetPropertyData` on the default output device (the old `AudioHardwareService*` functions are deprecated); mute via `kAudioDevicePropertyMute`. `VolumeObserver`: listeners on volume (main element and channels 1, 2) + mute, follow default-device changes, de-duplicate identical reports → show the volume peek on any change (also from Control Center).
- **Brightness** (built-in display): private `DisplayServices` framework loaded with `dlopen`/`dlsym` (`DisplayServicesGetBrightness` / `SetBrightness`); built-in display via `CGDisplayIsBuiltin`.
- **Key interception** (`MediaKeyInterceptor`): `CGEvent.tapCreate` at `.cgSessionEventTap`, `.headInsertEventTap`, `.defaultTap`, mask `1 << 14` (NX_SYSDEFINED). Parse `NSEvent(cgEvent:)` subtype 8: key code = `(data1 & 0xFFFF0000) >> 16` (0 vol up, 1 vol down, 2 bright up, 3 bright down, 7 mute), key-down when `((data1 & 0xFF00) >> 8) == 0xA`. When handled, **swallow** the key-down and its key-up (so macOS's HUD doesn't appear). Steps 1/16 (Option+Shift = 1/64), snapped to the grid; changing volume unmutes. Pass the key through if the device has no settable volume or there's no built-in display. Re-enable the tap on `tapDisabledByTimeout/UserInput`.
- Needs **Accessibility** permission. Setting **"Replace Volume & Brightness HUD"**, **default on**; at launch, if enabled and not trusted, show the system prompt (`AXIsProcessTrustedWithOptions` with `"AXTrustedCheckOptionPrompt"` — use the string, the global constant isn't concurrency-safe) and poll every 2 s (up to ~5 min) to start the tap as soon as it's granted. Without the permission, volume changes still show the notch HUD (alongside macOS's).

## 6. Battery
IOKit `IOPSNotificationCreateRunLoopSource` (C callback + `Unmanaged` context, main run loop) — event-driven. Read the internal battery: percent, AC power, charging, minutes remaining. Peeks as listed above. Status is shown in the header and clock card.

## 7. Timer / Pomodoro
- Presets **5m / 15m / 25m** (chip buttons) and **Pomodoro** (orange chip): 25-min focus → 5-min break, 15-min long break after every 4th focus; phases **auto-advance**; title "Focus · 2/4" / "Short break" / "Long break".
- Running view: 52-pt progress ring (orange, `TimelineView` 1 s, only while open), big countdown, pause/resume and stop (red) round buttons.
- Implementation: store `endDate`; **one** `DispatchQueue.main.asyncAfter(wallDeadline:)` at the end (keeps counting during sleep) instead of ticking; play the "Glass" sound and show a peek when done.

## 8. Clipboard history
- `NSPasteboard.general.changeCount` checked **once per second** with timer `tolerance 0.5` (there's no change notification).
- Text only, **in memory only**, max 20, trimmed-empty ignored, stored up to 10 000 chars. Copying something already in the list **moves the existing item to the top** (keep its id).
- **Skip secrets**: ignore pasteboards with `org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`, `com.agilebits.onepassword`.
- Card: title + trash (clear) button; rows single-line (newlines → spaces), hover highlight, click to copy back with a green ✓ for 1.2 s; placeholders when empty or disabled. Setting **"Clipboard History"**, default on (turning it off clears it).

## 9. Focus / Do Not Disturb
- No public API: read `~/Library/DoNotDisturb/DB/Assertions.json` (`data[0].storeAssertionRecords[0].assertionDetails.assertionDetailsModeIdentifier`) and `ModeConfigurations.json` (`data[0].modeConfigurations[id].mode.name` / `symbolImageName`). Needs **Full Disk Access** (detect access by listing the folder). Watch the folder with a `DispatchSource` file-system source (debounce 0.3 s). Peek on change; show the symbol in the header.
- Limitation to mention: Focus turned on by a *schedule* may not be detected.

## 10. Microphone / camera in use
- **Mic**: CoreAudio process objects — `kAudioHardwarePropertyProcessObjectList`, per process `kAudioProcessPropertyIsRunningInput`, `…BundleID`, `…PID`. **Ignore** always-listening system services (bundle prefixes `com.apple.CoreSpeech`, `com.apple.corespeech`, `com.apple.siri`, `com.apple.assistant`, `com.apple.SpeechRecognitionCore`, `com.apple.accessibility.heard`, `com.apple.voicetrigger`) and ourselves — otherwise "Hey Siri" keeps the mic dot on permanently. App names from `NSRunningApplication` (strip " Helper…"; `com.apple.WebKit*` → "Safari").
- **Camera**: CoreMediaIO devices, `kCMIODevicePropertyDeviceIsRunningSomewhere` (wildcard scope/element).
- **Listeners only, no polling** (process list, device list, per-process running-input, per-device running-somewhere; de-duplicate listeners with a hashable `(object, selector)` key). No mic/camera permission is needed because nothing is recorded.

## 11. Full-screen behavior
- Hide the live activities (artwork/bars, timer, privacy dot) **and** disable hover-to-open **only when a video is full screen** on the notched screen. **Apps that are merely in full-screen mode (Safari browsing, Claude, Notes, Cursor…) keep the notch fully working.** Peeks (volume/brightness etc.) still show in full screen, since the keys are swallowed.
- Detection (`FullScreenDetector`, uses the Accessibility permission): focused window of the frontmost app (`AXFocusedWindow`, messaging timeout 0.5 s) has `AXFullScreen == true`, is on the notched screen, and **either** its `AXSubrole` is **not** `AXStandardWindow` (Safari/WebKit shows full-screen video in a borderless, untitled `AXDialog` window; full-screen apps keep a titled `AXStandardWindow` — verified on my Mac) **or** the app is a video player (QuickTime Player, TV, IINA, VLC, Infuse). Without Accessibility permission, never hide.
- Re-check on `NSWorkspace.activeSpaceDidChangeNotification` and `didActivateApplicationNotification`, and again 1 s later. Close the notch if it's open when a video goes full screen.
- Known limitation: Chrome/Brave/Edge play full-screen video inside their normal window.

## 12. Menu & settings
- `NSStatusItem` (SF Symbol `rectangle.topthird.inset.filled`) with a menu rebuilt on open (`NSMenuDelegate.menuNeedsUpdate`); **the same menu pops up from the ⚙︎ in the notch** (`NSMenu.popUp(positioning:at: NSEvent.mouseLocation, in: nil)`).
- Items: "NotchApp" (title) · Replace Volume & Brightness HUD ✓ (+ "Grant Accessibility Permission…" if missing, opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`) · Clipboard History ✓ · Haptic Feedback ✓ · "Enable Focus Detection (Full Disk Access)…" / "Focus Detection: On" (opens `…?Privacy_AllFiles`) · Quit NotchApp (⌘Q).
- `AppSettings` (`ObservableObject`, `UserDefaults`, registered defaults): `replaceSystemHUD` true, `clipboardHistory` true, `hapticFeedback` true.
- The view model forwards every service's `objectWillChange` so one `@ObservedObject` redraws the notch.

## 13. Explicitly NOT wanted
- **No live video mirroring / screen capture** in the notch (I tried it and rejected it for privacy). Don't use ScreenCaptureKit and don't request Screen Recording permission. Thumbnails only.

## 14. Diagnostics & debugging aids
- `os.Logger(subsystem: "com.local.NotchApp", …)` categories: Permissions (log Accessibility / Full Disk Access / HUD-tap status at launch, +5 s, and when the menu opens), NowPlaying, Artwork (decisions and match *counts* — no titles/URLs), FullScreen, plus the menu-bar icon position (and whether it's hidden behind the notch).
- Read logs with **`/usr/bin/log show …`** — in zsh, plain `log` is a shell builtin and silently does nothing.
- DEBUG-only `--snapshot <folder>`: render the notch in many states (closed idle, volume peek, charging, focus, timer + mic, music + timer + mic, open Home, open Now Playing, no-artwork gradient, hour-long media) to PNGs with `ImageRenderer` at 2×, over a light-gray background. Add an `isSnapshot` environment value so views swap AppKit-backed views (e.g. `ScrollView`) for plain stacks. (Core Animation bars show as a placeholder there — expected.)

## 15. Testing & verification (do all of this before reporting)
1. Probe each system API on my Mac with a small read-only Swift script first (volume, brightness, battery, mic processes, cameras) — don't change anything.
2. Strict build (`-strict-concurrency=complete -warnings-as-errors`) passes.
3. Unit tests (small `swiftc` harnesses compiling the pure files) for: YouTube video-ID parsing (watch, Music, m., youtu.be, shorts, embed, invalid), gradient determinism, `ArtworkTracker` (leftover picture rejected even if re-sent; same-album cover allowed; new real artwork accepted), `TabMatcher` (exact title beats a longer title; ambiguous → nil; same video twice OK; search-results page skipped for navigation; non-YouTube → no thumbnail; normalization), `NowPlayingSelector` (replay: playing item + flips to a paused tab are ignored; pausing keeps the paused item; playing another tab switches; closed tab → switch after 20 s, not before; notch-pause then another paused tab ignored).
4. Compile (don't run) every generated AppleScript with `osacompile -o /dev/null` for Safari and Chrome, including titles with quotes/backslashes/no-break spaces. Note: compiling can launch the target app — check and mention it.
5. Render the snapshots and look at them.
6. Launch the real app and measure with `top -pid`: **0.0% CPU idle** (brief spikes only while the mouse moves), ~20 MB memory; use `sample` if anything looks high.
7. Tell me clearly which behaviors need me to test live (media keys, battery plug/unplug, mic, tab switching, full-screen video) and what to look for.

## 16. Permissions checklist to give me at the end
- **Accessibility** (HUD + full-screen detection) — prompted at launch; takes effect without relaunch.
- **Automation → Safari/Chrome** (thumbnail lookup + click-to-tab) — prompted on first use.
- **Full Disk Access** (optional, Focus) — add manually; relaunch.
- If a permission shows as granted but doesn't work (e.g. after a signing change), have me run `tccutil reset All com.local.NotchApp`, relaunch, and grant again. Check `tccd` logs for "Failed to match existing code requirement" to diagnose.

## 17. How I start/stop it (include in your summary)
- Start: `open ~/NotchApp/build/NotchApp.app` (or copy to /Applications and use Spotlight). Restart: `pkill -x NotchApp; sleep 1; open ~/NotchApp/build/NotchApp.app`.
- Stop: hover the notch → ⚙︎ → **Quit NotchApp** (the menu-bar icon may be hidden behind the notch), or `pkill -x NotchApp`.
