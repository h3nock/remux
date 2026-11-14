# Remux

> A native iOS client for tmux and herdr.

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

Remux connects to your servers over SSH and attaches to the tmux and herdr sessions running there. Its interface is built around their sessions, windows, panes and agents, each with views and controls suited to the iPhone.

## Features

- **Sessions**: Attach to the tmux and herdr sessions running on your servers, or start new ones. Remux stays connected to several servers at once.
- **Windows and tabs**: Swipe to the next window or herdr tab, or open the list from the toolbar and pick one.
- **Panes**: A window with several panes shows one at a time by default, and the pane map lets you switch, split or zoom out.
- **Agents**: With herdr, the Agents list puts the agents that need you first, across all your sessions. A banner tells you when one is waiting.
- **Composer**: Write a longer prompt before you send it, or dictate it. Dictation runs on your iPhone.
- **Attachments**: Attach photos or files to a message. Remux uploads them to your server and adds their paths to the message, and you can mark up images first.
- **Previews**: Long-press a file path to open it, whether it's code, an image, a PDF or an HTML page. A localhost address opens the dev server on that machine.
- **Shortcuts**: Hold the first toolbar key to run a saved command. Sets for the shell, Claude Code and Codex are included, and you can add your own.
- **Keyboard**: Pick which keys the toolbar shows, and long-press the terminal for arrow keys, like a joystick. Drag further to go faster.
- **Sign-in**: Use a password, a private key, a Secure Enclave key that never leaves your iPhone, or Tailscale SSH. Passwords and private keys stay in the iOS Keychain.

## Requirements

- An iPhone with iOS 18 or later
- A server you can reach over SSH, with tmux 3.1 or later, or herdr 0.9.3 or later

## Install

Remux is in public beta on TestFlight: [join the beta](https://testflight.apple.com/join/fHqG1ruE). It's open source under the MIT license, so you can also build it yourself.

## Building from source

Requirements:

- Xcode 27.1 or later (iOS 18 remains the minimum deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

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

Remux is built on [Ghostty](https://github.com/ghostty-org/ghostty)'s terminal core and on [Citadel](https://github.com/orlandos-nl/Citadel) for SSH.

## License

Remux is released under the [MIT License](LICENSE).
