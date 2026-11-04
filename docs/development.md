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
scripts/build_release_ghosttykit.sh \
  -Dversion-string=1.3.2-dev+remux-window-close.3306070 -j2
```

The pinned source is `h3nock/remux-ghostty` at
`3306070c32d2591573928843cbd98fa8bb2ee384`, using Zig 0.16.0 and Xcode's
Metal Toolchain. The script applies `patches/ghostty-window-close.patch` once,
preserves unrelated source changes, and refuses incompatible patch contexts.
The explicit version avoids treating the non-semantic `ghosttykit-20261025`
tag as an application version. Additional arguments pass through to Zig.

`GHOSTTY_SOURCE_DIR` selects another checkout. Its generated framework must
still be at the relative path configured in `project.yml`; an APFS workspace
may use a sibling symlink to that checkout. The script builds `ReleaseFast`, and Remux Release
builds independently query the resulting XCFramework and fail on any other
mode. The app also validates the selected iOS slice at launch.

TestFlight archiving still requires the cryptographically pinned release via
`fetch_ghosttykit.sh --verify`. Local patched builds are for validation; promote
the reviewed patched framework asset and update that pin before archiving.
The archive gate continues to reject an unpinned local build.

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
  -destination 'platform=iOS Simulator,id=<discovered-uuid>'
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

## Phone acceptance checks

Discover destinations with `xcodebuild -showdestinations -project Remux.xcodeproj
-scheme Remux` and `xcrun simctl list devices available`. Record the actual model,
OS, viewport in points, orientation and text size; a product's pixel resolution
does not establish the app's viewport. Keep machine-specific logs, screenshots
and result bundles outside the tracked repository.

The focused phone changes have these acceptance criteria:

- Every dock action has a distinct, reachable 44-by-44-point target. The dock
  uses two rows when one row cannot fit within the safe area, including a
  320-point viewport with 8-point side margins.
- A long composer draft scrolls within its editor. It leaves room for the
  terminal and controls, limits landscape growth to two lines, and displays at
  least one complete line at larger text sizes. Return inserts a literal newline.
- Fast composer typing preserves every character, including the first character,
  literal newlines and Unicode. Reentrant model publication must not erase input
  or reset its caret; later external draft replacements and clearing still apply.
- Rotation, composer close/reopen and foreground/background preserve the exact
  draft. Repeated Send while delivery is pending sends one paste and one Enter.
- Keyboard overlap uses the attached responder's current window coordinates.
  A keyboard outside that window reserves no space; moving the responder to
  another window uses that window's bounds on the next notification.
- Shortcut fields retain their accessibility labels after typing, and saved
  shortcut text executes the exact intended command.
- Rapid settings edits compose in request order and persist in that order.
  Reopening settings shows the combined saved values; a failed final save keeps
  the last successful settings and leaves active terminal instances intact.
- Returning Home from a dark terminal restores the window's prior/system
  appearance, including readable status-bar contrast. Terminal appearance changes
  do not recreate retained terminal views or overwrite another window owner's
  newer style on removal.
- Saving a new server with either Save or the keyboard's Return action dismisses
  the form before opening that server's detail page. Password state clears on
  dismissal without interrupting navigation.
- Server and shortcut Save actions remain visible and hittable while the software
  keyboard is shown, with no overlap. Prominent actions use the pinned toolbar
  group on iOS 27 and later and retain their accessible titles. Shortcut and
  collection forms open at full height so fields can be reached while typing.
- Session, window and pane pickers remain reachable. Opening and closing a
  picker does not change remote topology. Closing a window removes its tile
  after the authoritative tmux notification; duplicate or unknown close
  notifications do not remove other windows or emit commands.
- Herdr follows the newest queued pane/tab selection or creation. Superseded
  moves send no stale focus command; a move already in flight can finish while
  keys continue to the most recently tapped pane.
- Live foreground/background recovery preserves the original pane's shell state.
  Unique output markers and a final counter value prove that before/after
  commands execute once; remote pane count matches the intended topology.
- Trusting a discovery host key retries immediately even while another backend
  is pending. The old discovery's late result cannot restore the dismissed trust
  prompt or overwrite the new successful session list.

`PhoneDailyUseUITests` covers the phone interactions and attaches screenshots;
the sizing and composer-submission XCTest cases cover bounds and duplicate
delivery. Run on the target configuration and a smaller supported iPhone. Check
the captured screens visually, including landscape with the keyboard shown and
accessibility XXXL text. These deterministic checks do not establish live SSH
connectivity or physical-device validation.

After targeted checks, run both full suites on the final integrated source:

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,id=<discovered-uuid>' \
  -resultBundlePath '<artifact-root>/unit-<unique-run>.xcresult'
xcodebuild test -project Remux.xcodeproj -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,id=<discovered-uuid>' \
  -resultBundlePath '<artifact-root>/ui-<unique-run>.xcresult'
```

The `Remux` scheme does not execute the UI suite. Build Debug and Release as
well; retain the GhosttyKit ReleaseFast check. Where local live configuration
exists, use the cleanup wrapper for keyboard resize, foreground recovery,
session/window/pane switching and exactly-one-pane checks. Report passed,
failed, skipped and environment-blocked validation separately.
