# Development

This page covers setting up, building, and running Remux. Tests are covered in
[testing.md](testing.md).

## Requirements

- A Mac with Xcode 26.4.1 or later and an iOS simulator runtime. CI builds
  with Xcode 26.4.1. The app targets iOS 18 and builds with Swift 6.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Network access to GitHub, to download GhosttyKit and the Swift packages.

## Set Up

Remux uses GhosttyKit, the Ghostty terminal library built from
[h3nock/remux-ghostty](https://github.com/h3nock/remux-ghostty). The project
expects it next to your Remux checkout, at
`../ghostty-remux-upstream-rebuild/macos/GhosttyKit.xcframework` (set in
[project.yml](../project.yml)), so clone Remux into a directory you own:

```bash
git clone https://github.com/h3nock/remux.git
cd remux
scripts/fetch_ghosttykit.sh
xcodegen generate
```

`scripts/fetch_ghosttykit.sh` downloads the GhosttyKit release pinned in the
script, checks its SHA-256, and installs it at that path. It is a ReleaseFast
build, so it works for Debug and Release builds. Run the script again after
pulling a change that updates the pin. It keeps a framework you built yourself
unless you pass `--force`.

If a build fails with `There is no XCFramework found at
'.../ghostty-remux-upstream-rebuild/macos/GhosttyKit.xcframework'`, GhosttyKit
isn't installed; run `scripts/fetch_ghosttykit.sh`.

### Building GhosttyKit Yourself

You only need this when you change libghostty. You need
[Zig](https://ziglang.org/download/) at the version in the checkout's
`build.zig.zon` (`minimum_zig_version`). Clone remux-ghostty to the path above
(remove a fetched copy there first) and build:

```bash
git clone https://github.com/h3nock/remux-ghostty.git ../ghostty-remux-upstream-rebuild
scripts/build_release_ghosttykit.sh
```

The script builds a ReleaseFast XCFramework in the checkout's `macos/`
directory, where Remux finds it. Release builds of Remux check that GhosttyKit
is a ReleaseFast build and fail otherwise. To go back to the pinned release,
run `scripts/fetch_ghosttykit.sh --force`.

## Generate the Project

`Remux.xcodeproj` is generated from [project.yml](../project.yml) and checked
in. Run `xcodegen generate` after you edit `project.yml` or add, remove, or
rename files, and commit the updated project with your change. CI fails when
`xcodegen generate` changes the checked-in project.

## Build

```bash
xcodebuild build \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'generic/platform=iOS Simulator'
```

## Run

### Simulator

Open `Remux.xcodeproj` in Xcode, choose the `Remux` scheme and an iPhone
simulator, and run.

### Device

The project sets no signing team. In Xcode, select the `Remux` target, open
Signing & Capabilities, choose your team, and change the bundle identifier
if Xcode reports that `dev.remux.app` is unavailable. Don't commit these
changes; `xcodegen generate` resets them.

### Connecting to a Server

Remux connects over SSH and attaches to tmux in control mode. The server needs
tmux 3.1 or later. With an older tmux, the terminal shows
`unsupported tmux version <version> (requires 3.1+)`. Remux looks for `tmux`
on the server's `PATH` and in `/opt/homebrew/bin`, `/usr/local/bin`,
`/usr/bin`, and `/bin`. If tmux is somewhere else, set its absolute path in the
server's Executable Path field.

## Debug Seeding

Debug builds can seed one saved connection from launch environment variables.

```bash
REMUX_DEBUG_SEED_CONNECTION=1
REMUX_DEBUG_SERVER_NAME="Example Server"
REMUX_DEBUG_SERVER_HOST="server.example.com"
REMUX_DEBUG_SERVER_PORT=22
REMUX_DEBUG_SERVER_USERNAME="demo"
REMUX_DEBUG_SERVER_PASSWORD="<password>"
REMUX_DEBUG_TMUX_SESSION="base"
```

To seed a private key, set `REMUX_DEBUG_CREDENTIALS_FILE` to the path of a
JSON file with `privateKeyPEM` and an optional `privateKeyPassphrase`, or with
`password`. The credential then comes only from that file. The app never reads
a key from its launch environment, because XCTest records that environment in
result bundles.

## Local Files

Keep developer-only notes and machine-specific working files in `.local/`.
Git ignores it. The live UI test script writes its logs and result bundles to
`.local/logs/`.

Don't commit credentials, live SSH host details, result bundles, or build
products.
