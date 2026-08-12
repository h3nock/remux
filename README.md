# Remux

> A native iOS client for remote tmux workspaces.

<p align="center">
  <a href="https://trendshift.io/repositories/91075?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-91075" target="_blank" rel="noopener noreferrer">
    <img src="https://trendshift.io/api/badge/repositories/91075" alt="h3nock/remux | Trendshift" width="250" height="55" />
  </a>
</p>

https://github.com/user-attachments/assets/e7482322-15f8-4f7d-aca4-83368fddd07c

<p align="center">
  <a href="https://testflight.apple.com/join/fHqG1ruE">Join the beta on TestFlight</a>
</p>

## About

Remux is a native iOS client for remote tmux workspaces, built on Ghostty.
It brings tmux's session, window, and pane model into a mobile-first
interface. It previews files and running dev servers straight from the
terminal, and uploads photos and files, with markup for images.

## Features

- **tmux sessions**: Attach to running sessions or start new ones.
- **Windows and panes**: Swipe between windows, pick panes from a bottom
  sheet with live previews, and split, zoom, or close them.
- **Shortcut palette**: Run saved commands with a tap. Starter sets cover
  shell, Claude Code, and Codex, and you can add your own commands and
  groups.
- **Voice dictation**: Dictate text in the composer using on-device speech
  recognition.
- **Attachments**: Upload photos and files to the server, with markup for
  images. The remote path is typed at the prompt.
- **File preview**: Long-press a path in terminal output to preview it:
  code, images, PDFs, or HTML pages.
- **Localhost preview**: Long-press a localhost URL to open the dev server
  running on the remote machine, hot reload and WebSockets included.
- **Cursor control**: Hold the space bar or long-press in the terminal,
  then drag to place the cursor.
- **Direct SSH**: Remux connects straight to the server, with no relay and
  no account. Passwords and private keys are stored in the iOS Keychain,
  and trusted host keys are remembered.
- **Themes**: Ghostty default, Catppuccin Mocha, and Catppuccin Latte,
  with adjustable font size.

## Installation

Remux is available as a public beta on TestFlight:
[testflight.apple.com/join/fHqG1ruE](https://testflight.apple.com/join/fHqG1ruE).
You can also build from source.

## Building from Source

Requirements:

- Xcode with iOS 18 SDK support
- XcodeGen

Fetch the prebuilt GhosttyKit framework:

```bash
scripts/fetch_ghosttykit.sh
```

Generate the Xcode project and build:

```bash
xcodegen generate

xcodebuild build \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'generic/platform=iOS Simulator'
```

Run the tests:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

To build GhosttyKit yourself instead of fetching it, see
[remux-ghostty](https://github.com/h3nock/remux-ghostty) and
[scripts/build_release_ghosttykit.sh](scripts/build_release_ghosttykit.sh).

## Acknowledgments

Remux is built on [Ghostty](https://github.com/ghostty-org/ghostty)'s
terminal core and uses [Citadel](https://github.com/orlandos-nl/Citadel)
for SSH.
