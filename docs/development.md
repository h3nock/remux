# Development

Remux uses XcodeGen. The checked-in project definition is `project.yml`.

## Requirements

- Xcode with iOS 18 SDK support
- XcodeGen on `PATH`
- Zig and the Ghostty source checkout at the relative path configured in
  [project.yml](../project.yml)

## Build GhosttyKit

Build the XCFramework used by Release and performance profiling with:

```bash
scripts/build_release_ghosttykit.sh
```

Set `GHOSTTY_SOURCE_DIR` when the Ghostty checkout is not the configured
sibling directory. The script always builds `ReleaseFast`, and Remux Release
builds independently query the resulting XCFramework and fail on any other
mode. The app also validates the selected iOS slice at launch.

## Generate Project

```bash
xcodegen generate
```

Run this after changing [project.yml](../project.yml).

## Build

```bash
xcodebuild build \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'generic/platform=iOS Simulator'
```

## Test

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

## Local Files

Keep developer-only notes, live validation configuration, and machine-specific
working files in `.local/`. The directory is ignored by Git.

Do not commit local credentials, live SSH host details, machine-specific result
bundles, or generated build products.

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

To seed a private key, set `REMUX_DEBUG_CREDENTIALS_FILE` to a JSON file with
`privateKeyPEM` and an optional `privateKeyPassphrase` (or `password`); the
credential then comes only from that file. A key is never read from the launch
environment, which XCTest records in result bundles.

Live validation should stay opt-in and local. Keep any real host, username,
password, or test-control files out of the tracked repository.

When running generated live UI tests, use the tracked host-side wrapper so the
app runs with ephemeral debug storage, the test records the exact disposable
`remux-latency-*` tmux sessions it creates, and the wrapper removes only those
allowlisted sessions after the run:

```bash
scripts/remux_live_ui_test_with_cleanup.sh \
  --config .local/live-ssh.json \
  --only-testing RemuxUITests/RemuxAppUITests/testLiveSSHTmuxActionCycleWhenConfigured
```

`--config` defaults to `/tmp/remux-live-ssh.json`; `--help` lists every option
and the config's fields.
