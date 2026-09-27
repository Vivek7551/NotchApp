# NotchApp

A Dynamic Island for the MacBook notch. Hover over the notch to open it; it also shows live activities and short alerts while closed.

## Features

- **Now Playing** for any app (Apple Music, Spotify, YouTube in Safari/Chrome…): artwork, progress bar with seeking, play/pause/next/previous. Click the title to jump to the tab that's playing.
- **Live activities** in the closed notch: artwork + equalizer while music plays, timer countdown, mic/camera-in-use dot.
- **Volume & brightness HUD** that replaces the macOS one.
- **Battery**: charging / unplugged / low-battery alerts.
- **Timer & Pomodoro** (25/5, long break every 4th round).
- **Clipboard history** (text only, kept in memory, skips password-manager secrets).
- **Focus / Do Not Disturb** indicator.
- Two pages (Home / Now Playing) with page dots and two-finger swipe.
- Stays out of the way during full-screen video.

## Requirements

- A MacBook with a notch, macOS 14 or later (developed on macOS 26).
- Xcode (or the Command Line Tools) for `swift` and `clang`.
- Optional: an "Apple Development" signing certificate, so macOS remembers the app's permissions across rebuilds.

## Build & run

```bash
./build.sh run
```

This builds `build/NotchApp.app` and launches it. The first build downloads and compiles the Now Playing helper ([mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), BSD-3-Clause) at a pinned version.

- **Stop:** hover the notch → ⚙︎ → Quit NotchApp (or `pkill -x NotchApp`).
- **Restart:** `pkill -x NotchApp; sleep 1; open build/NotchApp.app`

## Permissions

| Permission | Used for |
|---|---|
| Accessibility | Replacing the volume/brightness HUD; detecting full-screen video |
| Automation (Safari/Chrome) | Finding the playing tab (thumbnails, click-to-tab) |
| Full Disk Access (optional) | Reading the current Focus mode |

## Credits

Now Playing data comes from [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg (BSD-3-Clause); its license is bundled in the app.
