# Physical Keyboard Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add configurable physical-keyboard commands, a global command palette with visible-terminal search, and auto-hiding floating terminal chrome.

**Architecture:** A persisted keyboard-settings value defines an optional key chord for each fixed app action. Root-level routing owns global commands while each selected terminal exposes its existing local actions through the same command interface; a small UIKit responder turns configured chords into those actions. Visible-text search crosses the existing retained tmux surfaces through one new non-mutating GhosttyKit viewport API, while physical-keyboard monitoring drives a separately tested floating-chrome state machine.

**Tech Stack:** Swift 6, SwiftUI, UIKit, GameController, XCTest, Zig, GhosttyKit C API, XcodeGen

## Global Constraints

- Preserve all touch-first layout and input behavior when no physical keyboard is connected.
- Treat Bluetooth, Magic Keyboard, and wired keyboards reported by `GCKeyboard.coalescedKeyboard` as physical keyboards.
- Accept only a key plus one or more of Command, Shift, Option, and Control; allow unassigned commands and reject duplicate chords.
- Default `Hide button bar when a physical keyboard is connected` to enabled.
- Search only the currently visible viewport, case-insensitively; do not add scrollback indexing or persistent highlights.
- Route Command-Left/Right through the same previous/next tmux-window behavior as the existing swipe gesture.
- Request app priority over system behavior for every configured command, but keep physical-iPad verification as a separate acceptance gate.
- Do not migrate or alter the existing terminal-settings JSON schema.
- Make the smallest GhosttyKit fork change required for a non-mutating visible-viewport snapshot.

---

### Task 1: Keyboard Command Domain and Defaults

**Files:**
- Create: `RemuxApp/Sources/Domain/AppKeyboardCommand.swift`
- Create: `RemuxApp/Sources/Domain/KeyboardSettings.swift`
- Create: `RemuxAppTests/KeyboardSettingsTests.swift`

**Interfaces:**
- Produces: `enum AppKeyboardCommand: String, Codable, CaseIterable, Identifiable`
- Produces: `struct KeyboardKeyBinding: Codable, Equatable, Hashable`
- Produces: `struct KeyboardSettings: Codable, Equatable`
- Produces: `KeyboardSettings.validated(updating:to:) throws -> KeyboardSettings`

- [ ] **Step 1: Write failing default, clearing, custom-chord, and duplicate tests**

Create tests asserting the exact default chord for all twelve registry commands,
that `nil` clears a command, that a custom modified chord persists in the
value, that a chord with no modifier is rejected, and that assigning a chord
already used by another command throws
`KeyboardSettings.ValidationError.duplicateBinding`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux -destination 'platform=iOS Simulator,id=53D1EE7F-E770-41B6-BEDF-9F416C35D2B9' -only-testing:RemuxTests/KeyboardSettingsTests
```

Expected: compilation fails because the keyboard settings types do not exist.

- [ ] **Step 3: Implement the smallest immutable command/settings model**

Define stable raw values for:

```swift
case previousWindow, nextWindow
case previousSession, nextSession
case home, windows, panes, attachments, commandPalette
```

Represent input with UIKit-compatible strings (`UIKeyInputLeftArrow`, `UIKeyInputRightArrow`, and lower-case printable characters) and modifiers with a Codable `OptionSet`. Build `KeyboardSettings.default` from an explicit dictionary and validate the prospective whole dictionary before returning an updated copy.

- [ ] **Step 4: Re-run the focused tests and verify GREEN**

Run the Task 1 test command and confirm zero failures.

- [ ] **Step 5: Commit**

```bash
git add RemuxApp/Sources/Domain/AppKeyboardCommand.swift RemuxApp/Sources/Domain/KeyboardSettings.swift RemuxAppTests/KeyboardSettingsTests.swift
git commit -m "Add configurable keyboard command domain

Define Remux's fixed app command set, the documented default bindings,
optional unassignment, and whole-settings validation that rejects bare or
duplicate chords before persistence."
```

### Task 2: Keyboard Settings Persistence

**Files:**
- Create: `RemuxApp/Sources/Persistence/KeyboardSettingsRepository.swift`
- Create: `RemuxAppTests/KeyboardSettingsRepositoryTests.swift`
- Modify: `RemuxApp/Sources/App/RemuxAppDependencies.swift`

**Interfaces:**
- Consumes: `KeyboardSettings`
- Produces: `protocol KeyboardSettingsRepositoryProtocol`
- Produces: `actor KeyboardSettingsRepository` with `load() async throws -> KeyboardSettings` and `save(_:) async throws`
- Produces: `RemuxAppDependencies.keyboardSettingsRepository`

- [ ] **Step 1: Write failing repository behavior tests**

Use an isolated temporary application-support directory and assert that a missing file loads `.default`, a saved custom value round-trips, and invalid duplicate JSON is rejected rather than becoming live settings.

- [ ] **Step 2: Run the repository tests and verify RED**

Run the simulator test command restricted to `KeyboardSettingsRepositoryTests`; expect missing repository symbols.

- [ ] **Step 3: Implement a separate `keyboard-settings.json` repository**

Reuse `JSONFileStore` conventions, validate decoded settings before returning them, and wire the repository into live and UI-test dependency constructors without changing `terminal-settings.json`.

- [ ] **Step 4: Run repository and dependency tests and verify GREEN**

Run `KeyboardSettingsRepositoryTests` plus existing dependency tests, then confirm zero failures.

- [ ] **Step 5: Commit**

Stage only the repository, dependency wiring, and tests; commit with a detailed message describing the separate schema and missing-file default.

### Task 3: Dynamic Key Commands and Route-Aware Dispatch

**Files:**
- Create: `RemuxApp/Sources/App/AppKeyboardCommandRouter.swift`
- Create: `RemuxApp/Sources/App/AppKeyboardCommandResponder.swift`
- Create: `RemuxAppTests/AppKeyboardCommandRouterTests.swift`
- Modify: `RemuxApp/Sources/App/RootView.swift`
- Modify: `RemuxApp/Sources/Terminal/GhosttyTerminalResponderUIView.swift`

**Interfaces:**
- Consumes: `KeyboardSettings`, `AppKeyboardCommand`
- Produces: `struct AppKeyboardCommandAvailability`
- Produces: `AppKeyboardCommandRouter.perform(_:)`
- Produces: configured `UIKeyCommand` values with `wantsPriorityOverSystemBehavior = true`
- Produces: terminal-local command closure returning whether a command was consumed

- [ ] **Step 1: Write failing routing tests**

Test that global Home and palette commands remain available on Home, terminal-only commands are disabled there, selected-terminal commands dispatch locally, session cycling wraps in Home's active-session order, and an unavailable configured command is consumed rather than sent to Ghostty.

- [ ] **Step 2: Run focused router tests and verify RED**

Run only `AppKeyboardCommandRouterTests`; expect missing router symbols.

- [ ] **Step 3: Implement command conversion and central routing**

Generate `UIKeyCommand` objects directly from the current settings, attach each command action as its property-list payload, request system priority, and rebuild commands when settings change. Root routing handles Home, session cycling, and palette presentation. The selected `GhosttySurfaceScreen` closure handles window cycling and existing window/pane/attachment presentations. Match active-session ordering to `ConnectionLibraryView`.

- [ ] **Step 4: Integrate terminal interception before Ghostty mapping**

In `GhosttyTerminalResponderUIView`, resolve configured app chords before `GhosttyTerminalHardwareCommandMapping`; pass unmatched keys to the existing mapping unchanged. Call the same local methods used by swipe and chrome button callbacks.

- [ ] **Step 5: Run router, hardware mapping, and navigation tests**

Confirm the focused suites pass with no warnings or failures.

- [ ] **Step 6: Commit**

Commit the central router, UIKit responders, root wiring, and tests with a message documenting command ownership and terminal fallthrough.

### Task 4: Keyboard Settings UI and Chord Capture

**Files:**
- Create: `RemuxApp/Sources/App/KeyboardSettingsView.swift`
- Create: `RemuxApp/Sources/App/KeyboardShortcutCaptureView.swift`
- Create: `RemuxAppTests/KeyboardShortcutCaptureTests.swift`
- Modify: `RemuxApp/Sources/App/RootView.swift`
- Modify: `RemuxAppUITests/RemuxAppUITests.swift`

**Interfaces:**
- Consumes: repository, settings validation, command metadata
- Produces: capture events as `KeyboardKeyBinding?`
- Produces: settings navigation link and hide-button-bar toggle

- [ ] **Step 1: Write failing capture-normalization tests**

Assert lower-case printable normalization, arrow-key preservation, combined modifiers, rejection of modifier-only/bare keys, clear-to-`nil`, and duplicate error presentation through a small pure capture reducer.

- [ ] **Step 2: Run focused tests and verify RED**

Run `KeyboardShortcutCaptureTests`; expect missing capture reducer.

- [ ] **Step 3: Implement the settings view and UIKit capture control**

Use one row per `AppKeyboardCommand`, an explicit capture button, a clear control, inline validation text, and the exact toggle label `Hide button bar when a physical keyboard is connected`. Keep the edited value local until validation succeeds, then persist through the injected repository.

- [ ] **Step 4: Add an existing-settings-flow navigation link**

Add a `NavigationLink` from `TerminalSettingsView` without reorganizing unrelated settings. Add stable accessibility identifiers for the screen, binding rows, clear actions, validation, and hide toggle.

- [ ] **Step 5: Write and run a UI test**

Exercise navigation, clearing a binding, assigning a custom chord through the deterministic capture seam, duplicate rejection, relaunch persistence, and the default-enabled hide toggle.

- [ ] **Step 6: Run focused unit and UI tests, then commit**

Commit the settings UI, capture behavior, tests, and accessibility identifiers.

### Task 5: Physical Keyboard Projection and Floating-Chrome State

**Files:**
- Create: `RemuxApp/Sources/App/PhysicalKeyboardMonitor.swift`
- Create: `RemuxApp/Sources/Terminal/PhysicalKeyboardChromeState.swift`
- Create: `RemuxAppTests/PhysicalKeyboardChromeStateTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces: `@MainActor @Observable final class PhysicalKeyboardMonitor`
- Produces: `struct PhysicalKeyboardChromeState`
- Produces: events `keyboardConnectionChanged`, `terminalTapped`, `chromeInteracted`, and `autoHideElapsed`

- [ ] **Step 1: Write failing state-transition tests**

Cover initial hidden state when connected and hide-enabled, reveal on terminal tap, hide after the timer event, timer restart after chrome interaction, persistent visibility when hide is disabled, and restoration of normal non-floating chrome on disconnect.

- [ ] **Step 2: Run focused tests and verify RED**

Run only `PhysicalKeyboardChromeStateTests`; expect missing state symbols.

- [ ] **Step 3: Implement the pure state reducer**

Keep timer scheduling outside the value type. Make state expose `usesFloatingChrome`, `isChromeVisible`, and a monotonically changing timer token only when a three-second hide should be scheduled.

- [ ] **Step 4: Implement the GameController-backed monitor**

Initialize from `GCKeyboard.coalescedKeyboard`, reconcile both connect/disconnect notifications against the current coalesced value, and support `REMUX_UI_TEST_PHYSICAL_KEYBOARD=1` as a deterministic UI-test projection.

- [ ] **Step 5: Add GameController linkage, run tests, and commit**

Regenerate the Xcode project, build, run the focused tests, and commit monitor/state/project changes.

### Task 6: Floating Button Bar Integration

**Files:**
- Modify: `RemuxApp/Sources/Terminal/GhosttySurfaceScreen.swift`
- Modify: `RemuxApp/Sources/Terminal/GhosttyKeyboardChrome.swift`
- Modify: `RemuxAppUITests/RemuxAppUITests.swift`

**Interfaces:**
- Consumes: `PhysicalKeyboardMonitor`, `PhysicalKeyboardChromeState`, `KeyboardSettings.hideButtonBarWhenPhysicalKeyboardConnected`
- Produces: unchanged measured layout without hardware keyboard and unmeasured bottom overlay with one

- [ ] **Step 1: Add a failing geometry UI test**

Under the physical-keyboard override, record the terminal viewport frame with chrome hidden and shown and assert identical height and bottom edge. Also assert that a terminal tap reveals the bar and a deterministic auto-hide hook hides it.

- [ ] **Step 2: Run the UI test and verify RED**

Confirm the current measured chrome shortens the terminal and the new test fails for that reason.

- [ ] **Step 3: Integrate floating chrome with one timer task**

When hardware is connected, render `GhosttyKeyboardChrome` in an overlay excluded from `GhosttyBottomChromeHeightPreferenceKey`. A terminal tap reveals without calling the software-keyboard path; every bar callback sends `chromeInteracted` before its existing action. Cancel and replace a `Task.sleep(for: .seconds(3))` task using the state token.

- [ ] **Step 4: Preserve the disconnected path byte-for-byte where practical**

Keep existing measured chrome, keyboard show/hide, and terminal tap behavior when no hardware keyboard is attached. When hide is disabled, keep the overlay visible and do not schedule a timer.

- [ ] **Step 5: Run geometry UI test, existing terminal UI tests, and commit**

Commit the floating overlay integration and evidence-producing UI assertions.

### Task 7: GhosttyKit Visible-Viewport API

**Files:**
- Modify: `/Users/jesse/Documents/remux-ghostty/src/renderer/TerminalSurface.zig`
- Modify: `/Users/jesse/Documents/remux-ghostty/src/renderer/TerminalSurfaceC.zig`
- Modify: `/Users/jesse/Documents/remux-ghostty/include/ghostty.h`

**Interfaces:**
- Produces: `TerminalSurface.viewportText() ![]const u8`
- Produces: `ghostty_terminal_surface_read_viewport(ghostty_terminal_surface_t, ghostty_text_s*)`
- Consumes: existing `ghostty_terminal_surface_free_text`

- [ ] **Step 1: Create the Ghostty WIP branch and write failing Zig tests**

Create `codex/viewport-text-snapshot`. Add core tests proving only viewport rows are returned, alternate-screen content is used while active, and selection plus scroll state are unchanged. Extend the C ABI declaration test for the new export.

- [ ] **Step 2: Run focused Zig tests and verify RED**

Run:

```bash
zig build test -Dtest-filter='TerminalSurface viewport text'
```

Expected: failure because `viewportText` and the C export do not exist.

- [ ] **Step 3: Implement the locked, non-mutating snapshot**

Lock the surface mutex, call the terminal viewport dump allocator, unlock, and return owned UTF-8 bytes. Add the C export using the same result/error mapping and allocator/free contract as selection text. Document visible-viewport scope and ownership in `ghostty.h`.

- [ ] **Step 4: Format and run Ghostty verification**

Run:

```bash
zig fmt src/renderer/TerminalSurface.zig src/renderer/TerminalSurfaceC.zig
zig build test -Dtest-filter='TerminalSurface viewport text'
zig build test -Demit-macos-app=false
```

Confirm all commands exit zero.

- [ ] **Step 5: Commit in the Ghostty fork**

Commit only the three API files with a detailed message covering snapshot scope, mutation guarantees, and ownership.

### Task 8: Remux Viewport Snapshot Wrapper and Search Projection

**Files:**
- Modify: `RemuxApp/Sources/Ghostty/GhosttyKitControlSurface.swift`
- Modify: `RemuxApp/Sources/Terminal/TmuxTerminalSession.swift`
- Modify: `RemuxApp/Sources/Terminal/TmuxTerminalScreenAdapter.swift`
- Create: `RemuxApp/Sources/Domain/TerminalViewportSnapshot.swift`
- Create: `RemuxAppTests/TerminalViewportSnapshotTests.swift`

**Interfaces:**
- Consumes: `ghostty_terminal_surface_read_viewport`
- Produces: `GhosttyKitControlSurface.visibleText() -> String?`
- Produces: `TerminalViewportSnapshot` containing workspace/server/window/pane identity and text
- Produces: adapter async snapshot enumeration that tolerates per-surface failure

- [ ] **Step 1: Write failing projection tests**

Use real adapter fixtures with multiple retained panes and assert exact metadata, all-pane enumeration, omission of a failed/disappeared surface, and no all-or-nothing failure.

- [ ] **Step 2: Run focused tests and verify RED**

Run `TerminalViewportSnapshotTests`; expect missing snapshot API.

- [ ] **Step 3: Build and install the forked XCFramework**

Build with:

```bash
GHOSTTY_SOURCE_DIR=../ghostty-remux-upstream-rebuild scripts/build_release_ghosttykit.sh
```

Verify the generated header contains
`ghostty_terminal_surface_read_viewport`. After remux-ghostty PR #7 merges,
publish an immutable GhosttyKit release containing that API, update
`scripts/fetch_ghosttykit.sh` to its tag and verified checksum, and verify a
clean checkout can fetch and build against the new pin. Until that release
exists, the source build is local verification and the clean-checkout build
remains externally dependent on PR #7 and its release asset.

- [ ] **Step 4: Implement the Swift wrapper and retained-surface projection**

Decode and free the returned text immediately. Enumerate the existing `surfacesByPaneID` under tmux-session ownership and join topology/identity metadata in the adapter; never issue `capture-pane` or reconstruct terminal state from transport bytes.

- [ ] **Step 5: Run focused tests, build Remux, and commit**

Commit the Remux wrapper, projection, tests, and updated pinned framework together so the checkout remains buildable.

### Task 9: Command Palette Filtering and Search Engine

**Files:**
- Create: `RemuxApp/Sources/App/CommandPaletteModel.swift`
- Create: `RemuxApp/Sources/App/CommandPaletteSearch.swift`
- Create: `RemuxAppTests/CommandPaletteModelTests.swift`

**Interfaces:**
- Consumes: hosts, route-aware commands, active-session snapshot providers
- Produces: `CommandPaletteItem` command and text-result cases
- Produces: debounced `setQuery(_:)`, cancellation on replacement/close, and `select(_:)`

- [ ] **Step 1: Write failing palette-model tests**

Assert empty-query action inventory, case-insensitive command filtering, case-insensitive visible-line matching, snippet and session/host/window/pane metadata, debounce replacement, close cancellation, and omission of failed surfaces.

- [ ] **Step 2: Run focused tests and verify RED**

Run `CommandPaletteModelTests`; expect missing model symbols.

- [ ] **Step 3: Implement command inventory and pure line matching**

Include `Add Connection`, `New Session on <host>` for each defined host, and currently available navigation/overlay commands. Search snapshots only for non-empty queries and construct short matching-line snippets without mutating surface state.

- [ ] **Step 4: Implement one cancellable debounce task**

On each query change cancel the previous task, wait the chosen short interval, snapshot all current providers, and publish only if the task/query generation is still current. Cancel and discard results when closed.

- [ ] **Step 5: Run focused tests and commit**

Commit model/search behavior and tests.

### Task 10: Global Command Palette UI and Selection Routing

**Files:**
- Create: `RemuxApp/Sources/App/CommandPaletteView.swift`
- Modify: `RemuxApp/Sources/App/RootView.swift`
- Modify: `RemuxApp/Sources/Terminal/GhosttySurfaceScreen.swift`
- Modify: `RemuxAppUITests/RemuxAppUITests.swift`

**Interfaces:**
- Consumes: `CommandPaletteModel`, root model methods, terminal focus methods
- Produces: global overlay available on Home and terminal routes

- [ ] **Step 1: Write failing routing tests for palette selections**

Assert Add Connection invokes `beginNewServer`, New Session preselects the chosen host through `beginNewWorkspace(for:)`, and a text result closes the palette before selecting workspace, window, and pane.

- [ ] **Step 2: Run routing tests and verify RED**

Confirm failure due to missing palette selection routing.

- [ ] **Step 3: Implement a focused SwiftUI palette overlay**

Present a searchable overlay from `RemuxWorkspaceShell`, keep the existing saved-command `ShortcutPalette` untouched, show command and text-result sections with disabled unavailable actions, and provide stable accessibility identifiers.

- [ ] **Step 4: Route exact search results**

Call `showActiveSession`, then `focusTmuxTopLevel`, then `focusTmuxPane` using the result identities. If the target disappeared, dismiss without crashing or redirecting to an arbitrary surface.

- [ ] **Step 5: Add and run UI tests**

Cover Command-K from Home and terminal, Add Connection, preselected New Session, existing windows/panes/attachments via configured commands, command filtering, and exact text-result routing with deterministic fixtures.

- [ ] **Step 6: Commit**

Commit the global palette UI, selection routing, and UI tests.

### Task 11: Full Verification and Acceptance Record

**Files:**
- Modify: `docs/superpowers/specs/2026-07-26-physical-keyboard-commands-design.md` only if implementation evidence reveals a genuine contract correction

**Interfaces:**
- Consumes: all prior tasks
- Produces: fresh automated and rendered evidence; explicitly leaves the physical-device gate open if no iPad is attached

- [ ] **Step 1: Regenerate and inspect**

Run `xcodegen generate`, `git diff --check`, and inspect both repositories' status/diffs to ensure unrelated `.worktrees` remain untouched and no generated or backup debris is staged.

- [ ] **Step 2: Run focused unit tests**

Run all new test classes in one fresh `xcodebuild test` invocation and record test counts and failures.

- [ ] **Step 3: Run the full Remux simulator suite**

Run:

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux -destination 'platform=iOS Simulator,id=53D1EE7F-E770-41B6-BEDF-9F416C35D2B9'
```

Read the complete result and do not infer full-suite success from focused tests.

- [ ] **Step 4: Run the full non-live UI suite**

Temporarily move any live-SSH configuration out of its discovery path, run the
entire `RemuxUITests` target, restore the configuration without reading or
copying its contents into logs, and record passed and live-only skipped counts
separately. Focused UI tests are not a substitute for this gate.

- [ ] **Step 5: Run release builds and Ghostty verification**

Run the Remux Release configuration build plus fresh `zig build test -Demit-macos-app=false` in the fork.

- [ ] **Step 6: Capture rendered simulator evidence**

Using the deterministic physical-keyboard override, capture Home palette, terminal palette, chrome hidden, and chrome revealed states. Verify from frames or accessibility geometry that the terminal viewport is identical between hidden and revealed floating-bar states.

- [ ] **Step 7: Review every design requirement**

Check each design section against code, focused tests, full-suite output, and rendered evidence. State explicitly that physical keyboard connection delivery and Command-H priority still require an attached iPad unless performed on one.

- [ ] **Step 8: Commit any final test/evidence-only corrections**

Run the relevant failing test before each correction, re-run full verification, then make a final detailed commit without staging the pre-existing `.worktrees`.
