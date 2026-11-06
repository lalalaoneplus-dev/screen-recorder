# Screen Recorder

A small, native macOS screen recorder built with SwiftUI, ScreenCaptureKit and AVFoundation.

## Features

- **Record any screen, or several at once.** Each screen is recorded at its native resolution to its own `.mov` file.
- **Area recording.** Drag a rectangle on any connected screen.
- **Pause, resume, restart and discard.** Pauses are cut out, so the file plays without gaps.
- **Countdown, global hotkeys and a menu-bar timer.**
- **Video size presets:** Full, 1440p, 1080p, 720p and 480p, each at High, Standard or Small quality, with a live file-size estimate.
- **System audio and microphone.**
- **Crash-safe files.** Recordings are written in 10-second fragments, so a crash or power loss still leaves a playable file.
- **Recent recordings list.** Thumbnails, rename, copy, reveal in Finder, and move to Trash.
- **Floating thumbnail after recording.** Drag it straight into another app.
- **Trim editor.** Exports as passthrough, HEVC, or MP4 at 1080p, 720p, 540p or 480p.

### Hotkeys

| Keys  | Action                    |
|-------|---------------------------|
| ⌥⇧⌘R  | Start / stop recording    |
| ⌥⇧⌘P  | Pause / resume            |
| ⌥⇧⌘A  | Select an area and record |

## Requirements

- macOS 15 or later on Apple silicon
- Xcode command-line tools (Swift 6)

## Build

```bash
./build.sh --no-install   # builds build/Screen Recorder.app
./build.sh                # builds and copies the app to ~/Desktop
```

By default the app is signed ad-hoc. To sign with your own Developer ID and notarize, create an untracked `build.local.env` next to `build.sh`:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
NOTARY_PROFILE="your-notarytool-keychain-profile"
```

## Permissions

The first recording asks for **Screen & System Audio Recording** permission, and the microphone permission if you turn the microphone on. An ad-hoc-signed build may ask again after each rebuild. A build signed with a stable Developer ID keeps the permission.

## Project layout

```
Sources/
  App.swift       SwiftUI windows, settings, menu-bar extra
  Recorder.swift  Recording state, settings, size planning
  Engine.swift    ScreenCaptureKit → AVAssetWriter capture session
  Overlays.swift  Area selector, countdown, area border, global hotkeys
  Library.swift   Recent recordings list and floating thumbnail
  Editor.swift    Trim editor and export
tools/make_icon.swift  Draws the app icon
```

## License

MIT. See [LICENSE](LICENSE).
