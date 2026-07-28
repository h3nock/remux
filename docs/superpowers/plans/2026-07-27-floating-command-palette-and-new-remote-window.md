# Floating Command Palette and New Remote Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Command-K a compact, immediately keyboard-operable floating chooser and add configurable Command-N creation of one tmux window in the currently open remote session.

**Architecture:** Extend the existing `AppKeyboardCommand` registry and terminal-scoped routing so Command-N reaches the same topology action used by the window chooser's `New Window` button. Keep palette query/selection as local value state initialized synchronously, and give the UIKit search field priority `UIKeyCommand` entries for Up, Down, Return, and Escape. Drive the floating card's bounded height from small, pure layout metrics rather than another presentation controller.

**Tech Stack:** Swift 6, SwiftUI, UIKit responder-chain key commands, XCTest, XCUITest, the existing tmux/Ghostty terminal adapter, and the existing live-SSH cleanup harness.

## Global Constraints

- Keep the existing opaque Remux palette surfaces, separator, corner treatment, shadow, and dimming scrim.
- Cap the floating card at 620 points wide with at least 20-point screen margins.
- Keep the search field to one intrinsic single-line row; it must never flex vertically.
- Show at most six result rows before scrolling.
- Establish the first enabled selection synchronously before the field can receive a key.
- Up and Down select enabled results before any query is typed; Return invokes; Escape dismisses without reaching the terminal.
- Command-N defaults to `Command-N`, remains configurable, and is terminal-scoped.
- Command-N creates exactly one tmux window in the existing ready remote session by reusing the current `New Window` topology action.
- Command-N must not create a pane, Remux connection, or saved Remux session.
- Do not add a settings migration or any backward-compatibility path.
- Do not add dependencies or replace the existing window or pane chooser.
- Keep simulator, live-SSH, and physical-device evidence separate.
- Do not open a pull request until Jesse accepts the behavior on a real device with a physical keyboard.

---

## File Map

- `RemuxApp/Sources/Domain/AppKeyboardCommand.swift`
  - Owns the new command identifier, display title, and terminal scope.
- `RemuxApp/Sources/Domain/KeyboardSettings.swift`
  - Owns the fresh-install Command-N default.
- `RemuxApp/Sources/App/AppKeyboardCommandRouter.swift`
  - Enforces ready-terminal availability before handing Command-N to the selected terminal.
- `RemuxApp/Sources/Ghostty/GhosttySurfaceScreen.swift`
  - Maps the terminal command to the existing tmux-window topology action and shares that action with the chooser button.
- `RemuxApp/Sources/App/CommandPaletteSearch.swift`
  - Owns testable palette result and selection value state.
- `RemuxApp/Sources/App/CommandPaletteView.swift`
  - Owns compact card geometry, synchronous state construction, and priority navigation/dismissal key commands.
- `RemuxAppTests/KeyboardSettingsTests.swift`
  - Covers the new default and existing validation contracts.
- `RemuxAppTests/AppKeyboardCommandRouterTests.swift`
  - Covers terminal availability and terminal-surface command mapping.
- `RemuxAppTests/GhosttyTerminalResponderViewTests.swift`
  - Covers publication and dispatch of the configured Command-N key command.
- `RemuxAppTests/CommandPaletteSearchTests.swift`
  - Covers synchronous initial selection, movement, compact sizing, and actual `UIKeyCommand` actions.
- `RemuxAppUITests/RemuxAppUITests.swift`
  - Covers compact palette geometry, pre-query selection/navigation, and live remote-window creation.

---

### Task 1: Register and Route Command-N

**Files:**
- Modify: `RemuxApp/Sources/Domain/AppKeyboardCommand.swift:3-51`
- Modify: `RemuxApp/Sources/Domain/KeyboardSettings.swift:28-67`
- Modify: `RemuxApp/Sources/App/AppKeyboardCommandRouter.swift:13-49`
- Test: `RemuxAppTests/KeyboardSettingsTests.swift:5-52`
- Test: `RemuxAppTests/AppKeyboardCommandRouterTests.swift:5-124`
- Test: `RemuxAppTests/GhosttyTerminalResponderViewTests.swift:70-118`

**Interfaces:**
- Consumes: existing `KeyboardKeyBinding`, `KeyboardKeyModifiers`, and `AppKeyboardCommandRouteContext`.
- Produces: `AppKeyboardCommand.newWindow`, display title `"New Window"`, fresh default `Command-N`, and `.terminal(.newWindow)` routing for a ready selected terminal.

- [ ] **Step 1: Write failing default and availability tests**

Add this assertion to
`KeyboardSettingsTests.testDefaultsAssignEveryDocumentedCommand()`:

```swift
XCTAssertEqual(
    settings.binding(for: .newWindow),
    KeyboardKeyBinding(input: "n", modifiers: [.command])
)
```

Extend `AppKeyboardCommandRouterTests.testSelectedTerminalCommandsRouteLocally()`:

```swift
XCTAssertEqual(
    AppKeyboardCommandRouter.route(.newWindow, in: context),
    .terminal(.newWindow)
)
```

Extend
`AppKeyboardCommandRouterTests.testDisconnectedSelectedTerminalDisablesTerminalCommands()`:

```swift
XCTAssertEqual(
    AppKeyboardCommandRouter.route(.newWindow, in: context),
    .unavailable
)
```

Add a focused responder assertion to
`GhosttyTerminalResponderViewTests.testResponderPublishesPriorityAppKeyCommandsAndDispatchesSelection()` after obtaining `commands`:

```swift
let newWindow = try! XCTUnwrap(
    commands.first {
        $0.input == "n"
            && $0.modifierFlags == [.command]
    }
)
view.perform(newWindow.action, with: newWindow)
XCTAssertEqual(receivedCommands.last, .newWindow)
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2' \
  -only-testing:RemuxTests/KeyboardSettingsTests \
  -only-testing:RemuxTests/AppKeyboardCommandRouterTests \
  -only-testing:RemuxTests/GhosttyTerminalResponderViewTests
```

Expected: compilation fails because `AppKeyboardCommand` has no member
`newWindow`. This is the intended RED failure.

- [ ] **Step 3: Add the command and its fresh default**

Add `newWindow` next to the existing window commands in
`AppKeyboardCommand.swift`:

```swift
enum AppKeyboardCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case previousWindow
    case nextWindow
    case previousSession
    case nextSession
    case home
    case windows
    case newWindow
    case panes
    case attachments
    case increaseFontSize
    case decreaseFontSize
    case commandPalette
```

Add the display title:

```swift
case .newWindow:
    "New Window"
```

Keep it terminal-scoped:

```swift
case .previousWindow, .nextWindow, .windows, .newWindow, .panes, .attachments:
    true
```

Add the default in `KeyboardSettings.default.bindings`:

```swift
.newWindow: KeyboardKeyBinding(input: "n", modifiers: [.command]),
```

Do not change decoding, repository loading, or `validated()`. The user
explicitly rejected a migration.

- [ ] **Step 4: Route the command only for a ready selected terminal**

Add `.newWindow` to the terminal-scoped branch in
`AppKeyboardCommandRouter.route(_:in:)`:

```swift
case .previousWindow, .nextWindow, .windows, .newWindow, .panes, .attachments:
    guard
        context.selectedSessionID != nil,
        context.isSelectedTerminalReady
    else {
        return .unavailable
    }
    return .terminal(command)
```

No separate settings or palette code is required: both enumerate
`AppKeyboardCommand.allCases`.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the command from Step 2.

Expected: all `KeyboardSettingsTests`, `AppKeyboardCommandRouterTests`, and
`GhosttyTerminalResponderViewTests` pass.

- [ ] **Step 6: Commit**

Immediately inspect status, then stage only the task files:

```bash
git status --short
git add \
  RemuxApp/Sources/Domain/AppKeyboardCommand.swift \
  RemuxApp/Sources/Domain/KeyboardSettings.swift \
  RemuxApp/Sources/App/AppKeyboardCommandRouter.swift \
  RemuxAppTests/KeyboardSettingsTests.swift \
  RemuxAppTests/AppKeyboardCommandRouterTests.swift \
  RemuxAppTests/GhosttyTerminalResponderViewTests.swift
git commit -m "Add configurable Command-N remote windows" \
  -m "Register New Window as a terminal-scoped app command with a fresh Command-N default. Route it only when the selected remote terminal is ready, and cover resolver publication and unavailable states without adding a settings migration."
```

---

### Task 2: Reuse the Existing New Window Topology Action

**Files:**
- Modify: `RemuxApp/Sources/Ghostty/GhosttySurfaceScreen.swift:719-735,2120-2135`
- Test: `RemuxAppTests/AppKeyboardCommandRouterTests.swift`

**Interfaces:**
- Consumes: `AppKeyboardCommand.newWindow`,
  `GhosttyTmuxTopologyActionInteractionEffect`,
  `model.createTmuxWindowInteractionEffect()`, and
  `model.createTmuxWindow()`.
- Produces: `GhosttySurfaceKeyboardCommandRoute.createWindow`,
  `GhosttySurfaceKeyboardCommandRouter.route(_:)`, and one shared
  `createTmuxWindow(event:)` path used by both keyboard and chooser actions.

- [ ] **Step 1: Write a failing terminal-surface mapping test**

Add this test to `AppKeyboardCommandRouterTests`:

```swift
func testTerminalSurfaceMapsNewWindowToTopologyCreation() {
    XCTAssertEqual(
        GhosttySurfaceKeyboardCommandRouter.route(.newWindow),
        .createWindow
    )
    XCTAssertEqual(
        GhosttySurfaceKeyboardCommandRouter.route(.commandPalette),
        .forward(.commandPalette)
    )
}
```

- [ ] **Step 2: Run the mapping test and verify RED**

Run:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2' \
  -only-testing:RemuxTests/AppKeyboardCommandRouterTests/testTerminalSurfaceMapsNewWindowToTopologyCreation
```

Expected: compilation fails because
`GhosttySurfaceKeyboardCommandRouter` does not exist.

- [ ] **Step 3: Add the testable terminal-surface route**

Add these internal types in `GhosttySurfaceScreen.swift`, immediately before
`GhosttySurfaceScreen`:

```swift
enum GhosttySurfaceKeyboardCommandRoute: Equatable {
    case previousWindow
    case nextWindow
    case showWindows
    case createWindow
    case showPanes
    case toggleAttachments
    case forward(AppKeyboardCommand)
}

enum GhosttySurfaceKeyboardCommandRouter {
    static func route(
        _ command: AppKeyboardCommand
    ) -> GhosttySurfaceKeyboardCommandRoute {
        switch command {
        case .previousWindow:
            .previousWindow
        case .nextWindow:
            .nextWindow
        case .windows:
            .showWindows
        case .newWindow:
            .createWindow
        case .panes:
            .showPanes
        case .attachments:
            .toggleAttachments
        case .previousSession, .nextSession, .home, .commandPalette,
             .increaseFontSize, .decreaseFontSize:
            .forward(command)
        }
    }
}
```

This route is small domain behavior, not a view-testing shim. It makes the
terminal command/effect mapping independently testable and keeps the view's
dispatch switch exhaustive.

- [ ] **Step 4: Dispatch through the route and shared action**

Replace `performAppKeyboardCommand(_:)` with:

```swift
private func performAppKeyboardCommand(_ command: AppKeyboardCommand) {
    switch GhosttySurfaceKeyboardCommandRouter.route(command) {
    case .previousWindow:
        handleWindowSwipe(.previous)
    case .nextWindow:
        handleWindowSwipe(.next)
    case .showWindows:
        showWindows()
    case .createWindow:
        createTmuxWindow(event: "ui.keyCommand.newWindow")
    case .showPanes:
        showPanes()
    case .toggleAttachments:
        toggleAttachmentTray()
    case .forward(let command):
        onAppKeyboardCommand(command)
    }
}
```

Extract the current chooser behavior into a shared method:

```swift
private func createTmuxWindow(event: String) {
    GhosttyRuntimeTrace.flowBegin(
        "tmux.newWindow",
        event: event,
        fields: [
            "topLevelsBefore": "\(model.terminalInteractionProjection.windowCount)",
            "workspaceID": presentation.workspaceID.uuidString,
        ]
    )
    let effect = model.createTmuxWindowInteractionEffect()
    performTopologyActionInteraction(effect) {
        model.createTmuxWindow()
    }
}

private func createTmuxWindowFromSelectionSheet() {
    createTmuxWindow(event: "ui.tap.newWindow")
}
```

The existing `GhosttyWindowSelectionSheet(onCreateWindow:)` call remains
unchanged and therefore uses the same topology interaction effect and model
action as Command-N.

- [ ] **Step 5: Run focused routing and topology tests**

Run:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2' \
  -only-testing:RemuxTests/AppKeyboardCommandRouterTests \
  -only-testing:RemuxTests/GhosttyTerminalInputCoordinatorTests \
  -only-testing:RemuxTests/TmuxSessionControllerClientSizeTests
```

Expected: all selected tests pass, including the new `.createWindow` mapping.

- [ ] **Step 6: Commit**

```bash
git status --short
git add \
  RemuxApp/Sources/Ghostty/GhosttySurfaceScreen.swift \
  RemuxAppTests/AppKeyboardCommandRouterTests.swift
git commit -m "Route Command-N through tmux New Window" \
  -m "Map the terminal-scoped New Window command to the same topology interaction and model action used by the existing chooser button. Keep tracing source-specific while sharing focus reconciliation and creation behavior."
```

---

### Task 3: Make the Palette Compact and Immediately Keyboard-Operable

**Files:**
- Modify: `RemuxApp/Sources/App/CommandPaletteSearch.swift:29-64`
- Modify: `RemuxApp/Sources/App/CommandPaletteView.swift:1-238`
- Test: `RemuxAppTests/CommandPaletteSearchTests.swift:70-194`
- Test: `RemuxAppUITests/RemuxAppUITests.swift:143-176`

**Interfaces:**
- Consumes: `CommandPaletteItem`,
  `CommandPaletteSelection.initialID(in:)`,
  `CommandPaletteSelection.moving(from:direction:in:)`, and the existing Remux
  palette colors.
- Produces: `CommandPaletteState`,
  `CommandPaletteLayout.maximumVisibleResultCount`,
  `CommandPaletteLayout.resultAreaHeight(for:)`, synchronous view state,
  and priority Up/Down/Return/Escape `UIKeyCommand` entries.

- [ ] **Step 1: Write failing synchronous-state tests**

Add these tests to `CommandPaletteSearchTests`:

```swift
func testStateStartsWithCommandsAndFirstEnabledSelection() {
    let disabled = item(id: "disabled", isEnabled: false)
    let first = item(id: "first")
    let state = CommandPaletteState(results: [disabled, first])

    XCTAssertEqual(state.results, [disabled, first])
    XCTAssertEqual(state.selectedResultID, first.id)
    XCTAssertEqual(state.selectedResult, first)
}

func testStateCanMoveBeforeAQueryAndResetsWhenResultsChange() {
    let first = item(id: "first")
    let second = item(id: "second")
    var state = CommandPaletteState(results: [first, second])

    state.moveSelection(.next)
    XCTAssertEqual(state.selectedResultID, second.id)

    let replacement = item(id: "replacement")
    state.replaceResults([replacement])
    XCTAssertEqual(state.selectedResultID, replacement.id)
}
```

- [ ] **Step 2: Write failing layout and priority-command tests**

Add this layout test:

```swift
func testFloatingLayoutCapsAtSixRowsAndKeepsEmptyStateCompact() {
    XCTAssertEqual(CommandPaletteLayout.inputRowHeight, 44)
    XCTAssertEqual(CommandPaletteLayout.resultAreaHeight(for: 0), 120)
    XCTAssertEqual(CommandPaletteLayout.resultAreaHeight(for: 1), 56)
    XCTAssertEqual(CommandPaletteLayout.resultAreaHeight(for: 6), 336)
    XCTAssertEqual(CommandPaletteLayout.resultAreaHeight(for: 9), 336)
}
```

Replace the final key-command assertions in
`testSearchFieldRoutesNavigationAndActivationKeysWithoutModifiers()` with:

```swift
XCTAssertEqual(
    field.keyCommands?.compactMap(\.input),
    [
        UIKeyCommand.inputUpArrow,
        UIKeyCommand.inputDownArrow,
        "\r",
        UIKeyCommand.inputEscape,
    ]
)
XCTAssertTrue(
    field.keyCommands?.allSatisfy(\.wantsPriorityOverSystemBehavior)
        == true
)
```

Add a separate test that invokes the real selectors rather than the raw helper:

```swift
@MainActor
func testPriorityKeyCommandsMoveActivateAndDismiss() throws {
    let field = CommandPaletteTextField()
    var actions: [String] = []
    field.onMoveSelection = {
        switch $0 {
        case .previous:
            actions.append("previous")
        case .next:
            actions.append("next")
        }
    }
    field.onActivateSelection = { actions.append("activate") }
    field.onDismiss = { actions.append("dismiss") }

    for input in [
        UIKeyCommand.inputUpArrow,
        UIKeyCommand.inputDownArrow,
        "\r",
        UIKeyCommand.inputEscape,
    ] {
        let command = try XCTUnwrap(
            field.keyCommands?.first(where: { $0.input == input })
        )
        field.perform(command.action, with: command)
    }

    XCTAssertEqual(
        actions,
        ["previous", "next", "activate", "dismiss"]
    )
}
```

- [ ] **Step 3: Add the failing compact-geometry UI assertion**

In
`RemuxAppUITests.testCommandPaletteSupportsKeyboardSelectionAndDismissal()`,
after the palette appears, add:

```swift
let search = app.textFields["command-palette.search"]
XCTAssertTrue(search.waitForExistence(timeout: 2))
XCTAssertLessThanOrEqual(search.frame.height, 44.5)
XCTAssertLessThanOrEqual(
    palette.frame.height,
    430,
    "The chooser should remain a compact floating card with six visible rows."
)
```

Keep the existing first-result `.isSelected` assertion and unmodified
Down-arrow action before any `typeText` call. Do not add an XCUITest Escape
assertion: on this simulator XCUITest maps Escape to software-keyboard
dismissal instead of a physical Escape event. The real selector test above and
the device gate below cover that contract honestly.

- [ ] **Step 4: Run the tests and verify RED**

Run:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2' \
  -only-testing:RemuxTests/CommandPaletteSearchTests
```

Expected: compilation fails because `CommandPaletteState` and
`CommandPaletteLayout` do not exist. After adding only enough declarations to
compile, the priority-command assertion must still fail because Up and Down are
not yet published as priority commands.

Run the UI test:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2' \
  -only-testing:RemuxUITests/RemuxAppUITests/testCommandPaletteSupportsKeyboardSelectionAndDismissal
```

Expected: FAIL because the current palette expands to its 520-point maximum
rather than the new compact bound.

- [ ] **Step 5: Add synchronous palette value state**

Add this value type to `CommandPaletteSearch.swift`:

```swift
struct CommandPaletteState: Equatable {
    private(set) var results: [CommandPaletteItem]
    private(set) var selectedResultID: CommandPaletteItem.ID?

    init(results: [CommandPaletteItem]) {
        self.results = results
        selectedResultID = CommandPaletteSelection.initialID(in: results)
    }

    var selectedResult: CommandPaletteItem? {
        guard let selectedResultID else { return nil }
        return results.first {
            $0.id == selectedResultID && $0.isEnabled
        }
    }

    mutating func replaceResults(_ newResults: [CommandPaletteItem]) {
        results = newResults
        selectedResultID = CommandPaletteSelection.initialID(in: newResults)
    }

    mutating func moveSelection(
        _ direction: CommandPaletteSelectionDirection
    ) {
        selectedResultID = CommandPaletteSelection.moving(
            from: selectedResultID,
            direction: direction,
            in: results
        )
    }
}
```

In `CommandPaletteView`, replace the separate `results` and
`selectedResultID` state with:

```swift
@State private var paletteState: CommandPaletteState
```

Add an explicit initializer that stores the closures and initializes state
synchronously:

```swift
init(
    commands: [CommandPaletteItem],
    snapshots: @escaping () -> [TerminalViewportSnapshot],
    onSelect: @escaping (CommandPaletteAction) -> Void,
    onDismiss: @escaping () -> Void
) {
    self.commands = commands
    self.snapshots = snapshots
    self.onSelect = onSelect
    self.onDismiss = onDismiss
    _paletteState = State(
        initialValue: CommandPaletteState(results: commands)
    )
}
```

Use `paletteState.results`, `paletteState.selectedResultID`,
`paletteState.replaceResults(_:)`, `paletteState.moveSelection(_:)`, and
`paletteState.selectedResult` throughout the view. Remove the `.task` that
previously populated results after presentation.

- [ ] **Step 6: Add compact, deterministic card metrics**

Add this internal layout contract to `CommandPaletteView.swift`:

```swift
enum CommandPaletteLayout {
    static let maximumVisibleResultCount = 6
    static let inputRowHeight: CGFloat = 44
    static let resultRowHeight: CGFloat = 56
    static let emptyResultHeight: CGFloat = 120

    static func resultAreaHeight(for resultCount: Int) -> CGFloat {
        guard resultCount > 0 else { return emptyResultHeight }
        return CGFloat(min(resultCount, maximumVisibleResultCount))
            * resultRowHeight
    }
}
```

Change the input row from unrestricted `.padding()` to:

```swift
.padding(.horizontal, 12)
.frame(height: CommandPaletteLayout.inputRowHeight)
.background(LibraryHomePalette.rowSurface)
```

For each result button label, enforce one predictable row:

```swift
.frame(
    maxWidth: .infinity,
    minHeight: CommandPaletteLayout.resultRowHeight,
    alignment: .leading
)
```

Use zero vertical list insets so the pure metric matches rendering:

```swift
.listRowInsets(
    EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
)
```

Give the list and empty state the bounded result-area height:

```swift
.frame(
    height: CommandPaletteLayout.resultAreaHeight(
        for: paletteState.results.count
    )
)
```

Remove `.frame(maxWidth: 620, maxHeight: 520)` and use:

```swift
.frame(maxWidth: 620)
.fixedSize(horizontal: false, vertical: true)
```

Keep the existing rounded opaque background, separator stroke, shadow, and
outer `.padding(CommandPaletteLayout.screenMargin)` with a 20-point value so
the card remains centered with the approved margins.

- [ ] **Step 7: Publish priority arrow commands alongside Return and Escape**

Return these commands from `CommandPaletteTextField.keyCommands` in this order:

```swift
[
    priorityKeyCommand(
        input: UIKeyCommand.inputUpArrow,
        action: #selector(selectPreviousResult)
    ),
    priorityKeyCommand(
        input: UIKeyCommand.inputDownArrow,
        action: #selector(selectNextResult)
    ),
    priorityKeyCommand(
        input: "\r",
        action: #selector(activateSelection)
    ),
    priorityKeyCommand(
        input: UIKeyCommand.inputEscape,
        action: #selector(dismissPalette)
    ),
]
```

Add the two selectors:

```swift
@objc
private func selectPreviousResult() {
    onMoveSelection?(.previous)
}

@objc
private func selectNextResult() {
    onMoveSelection?(.next)
}
```

Keep `wantsPriorityOverSystemBehavior = true`. Apple documents that this
reverses iOS 15+'s default text-input-first delivery order, which is required
for arrows to select results rather than move the text cursor:
`https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior`.

- [ ] **Step 8: Run focused unit and UI tests and verify GREEN**

Run both commands from Step 4.

Expected: `CommandPaletteSearchTests` pass; the palette UI test shows the first
enabled result selected before typing, Down selects the next option, Return
activates it, the search field is one line high, and the card is at most 430
points high.

- [ ] **Step 9: Commit**

```bash
git status --short
git add \
  RemuxApp/Sources/App/CommandPaletteSearch.swift \
  RemuxApp/Sources/App/CommandPaletteView.swift \
  RemuxAppTests/CommandPaletteSearchTests.swift \
  RemuxAppUITests/RemuxAppUITests.swift
git commit -m "Make Command-K a compact keyboard chooser" \
  -m "Initialize palette results and selection synchronously, cap the floating card at six rows, and keep the search control to one line. Publish priority Up, Down, Return, and Escape commands so text input cannot consume palette navigation or dismissal."
```

---

### Task 4: Prove Live Command-N and Ship the Device Candidate

**Files:**
- Modify: `RemuxAppUITests/RemuxAppUITests.swift`

**Interfaces:**
- Consumes: `launchLiveSSHAppIfConfigured`,
  `generatedLiveLatencySessionName`, `waitForLiveTerminalReady`,
  `openWindowsSheet`, and `recordLiveTmuxWindowCountExpectation`.
- Produces: a live-SSH acceptance test showing Command-N creates exactly one
  new remote tmux window.

- [ ] **Step 1: Add the live-SSH Command-N test**

Add this test beside the other generated live tmux action tests:

```swift
func testLiveSSHCommandNCreatesRemoteWindowWhenConfigured() throws {
    let sessionName = try generatedLiveLatencySessionName("command-n")
    defer {
        cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
    }

    try launchLiveSSHAppIfConfigured(
        traceRuntime: true,
        sessionNameOverride: sessionName
    )
    openFirstSavedSession()
    waitForLiveTerminalReady(timeout: 90)

    app.typeKey("n", modifierFlags: .command)
    waitForLiveTerminalReady(timeout: 30)

    openWindowsSheet()
    XCTAssertTrue(
        app.buttons["terminal.window.tile.1"]
            .waitForExistence(timeout: 10)
    )
    XCTAssertTrue(
        app.buttons["terminal.window.tile.2"]
            .waitForExistence(timeout: 10)
    )
    XCTAssertFalse(
        app.buttons["terminal.window.tile.3"]
            .waitForExistence(timeout: 2),
        "Command-N should create exactly one additional tmux window."
    )
    recordLiveTmuxWindowCountExpectation(
        sessionName: sessionName,
        expectedCount: 2
    )
}
```

- [ ] **Step 2: Run the live test through the cleanup harness**

Run:

```bash
scripts/remux_live_ui_test_with_cleanup.sh \
  --destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2' \
  --only-testing RemuxUITests/RemuxAppUITests/testLiveSSHCommandNCreatesRemoteWindowWhenConfigured
```

Expected: PASS, and the harness verifies the remote tmux window count is two
before deleting only the generated allowlisted session.

- [ ] **Step 3: Commit the live acceptance test**

```bash
git status --short
git add RemuxAppUITests/RemuxAppUITests.swift
git commit -m "Cover Command-N against live tmux" \
  -m "Drive the configured Command-N shortcut through the live SSH UI harness and require exactly one additional remote tmux window, with allowlisted cleanup and remote count verification."
```

- [ ] **Step 4: Run the full unit suite**

Run:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2'
```

Expected: exit 0. Record any pre-existing warnings separately; do not call the
gate green if a test fails.

- [ ] **Step 5: Run the full non-live UI suite**

Run:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2'
```

Expected: all non-live UI tests pass and configured live tests skip. If
XCUITest reports infrastructure errors such as process-termination or event
synthesis timeouts, inspect the `.xcresult` and rerun only the affected tests;
report the original failure and focused result separately.

- [ ] **Step 6: Inspect the final branch**

Run:

```bash
git diff --check
git status --short --branch
git log --oneline --decorate -8
```

Expected: no tracked changes remain, `git diff --check` emits nothing, and the
four existing untracked `.worktrees` directories remain untouched.

- [ ] **Step 7: Build and verify the signed iPhone app**

Run:

```bash
xcodebuild build -quiet \
  -project Remux.xcodeproj \
  -scheme Remux \
  -configuration Debug \
  -destination 'id=6A5C05AA-0987-5ECC-9937-7E3073636F1D' \
  -derivedDataPath .local/device-build \
  DEVELOPMENT_TEAM=87WJ58S66M \
  PRODUCT_BUNDLE_IDENTIFIER=com.fsck.dev.remux.app \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development'

codesign --verify --deep --strict --verbose=2 \
  .local/device-build/Build/Products/Debug-iphoneos/Remux.app
```

Expected: build exit 0 and codesign reports that the app is valid on disk and
satisfies its designated requirement.

- [ ] **Step 8: Install and launch on Jesse's iPhone**

First verify the device is available and unlocked:

```bash
xcrun devicectl device info lockState \
  --device 6A5C05AA-0987-5ECC-9937-7E3073636F1D
```

Then install and launch:

```bash
xcrun devicectl device install app \
  --device 6A5C05AA-0987-5ECC-9937-7E3073636F1D \
  .local/device-build/Build/Products/Debug-iphoneos/Remux.app

xcrun devicectl device process launch \
  --device 6A5C05AA-0987-5ECC-9937-7E3073636F1D \
  com.fsck.dev.remux.app \
  --terminate-existing

xcrun devicectl device info processes \
  --device 6A5C05AA-0987-5ECC-9937-7E3073636F1D |
  rg 'Remux.app/Remux'
```

Expected: install succeeds, launch succeeds on an unlocked phone, and the
process list contains `Remux.app/Remux`.

- [ ] **Step 9: Hand off the physical-keyboard acceptance gate**

Ask Jesse to verify on the installed build:

1. Command-K opens a centered compact card from Home and a terminal.
2. The input remains one line high.
3. The first option is selected before typing.
4. Up and Down move selection before typing.
5. Return invokes the selected option.
6. Escape dismisses without sending input to the terminal.
7. Command-N in a ready remote session creates one new tmux window.
8. Command-N outside a ready remote session has no Remux action.

Do not create a pull request until Jesse confirms this gate.
