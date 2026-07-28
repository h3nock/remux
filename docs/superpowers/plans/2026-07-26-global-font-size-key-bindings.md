# Global Font Size Key Bindings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add configurable Command-Plus and Command-Minus bindings that adjust Remux's app-global terminal font size by one point.

**Architecture:** Extend the existing `AppKeyboardCommand` registry and `KeyboardSettings.default` rather than introducing a second shortcut path. Route both commands globally through `RemuxRootModel`, where a pure `TerminalSettings` mutation starts from the current effective device size when automatic sizing is active, clamps to the existing range, persists through the existing repository, and refreshes all active sessions.

**Tech Stack:** Swift 6, SwiftUI, UIKit `UIKeyCommand`, XCTest, XCUITest

## Global Constraints

- Default Increase Font Size to Command-+ and Decrease Font Size to Command--.
- Font-size commands are app-global and work from Home, terminals, and the command palette.
- Each activation changes the font by exactly one point.
- Automatic sizing starts from the current effective device font size.
- Clamp results to `TerminalSettings.minimumFontSize` (8) and `TerminalSettings.maximumFontSize` (24).
- Persist through the existing terminal-settings repository and refresh every active terminal.
- Add the commands to the original keyboard-settings schema and defaults; do not add migration or backward-compatibility code.
- Preserve existing custom-binding validation, duplicate rejection, and Command-H reservation.
- Make the smallest reasonable changes and preserve unrelated worktree contents.

---

### Task 1: Configurable App-Global Font Size Commands

**Files:**
- Modify: `RemuxApp/Sources/Domain/AppKeyboardCommand.swift`
- Modify: `RemuxApp/Sources/Domain/KeyboardSettings.swift`
- Modify: `RemuxApp/Sources/Domain/TerminalSettings.swift`
- Modify: `RemuxApp/Sources/App/AppKeyboardCommandRouter.swift`
- Modify: `RemuxApp/Sources/App/RemuxRootModel.swift`
- Modify: `RemuxApp/Sources/App/RootView.swift`
- Modify: `RemuxApp/Sources/Ghostty/GhosttySurfaceScreen.swift`
- Modify: `RemuxAppTests/KeyboardSettingsTests.swift`
- Modify: `RemuxAppTests/TerminalSettingsTests.swift`
- Modify: `RemuxAppTests/AppKeyboardCommandRouterTests.swift`
- Modify: `RemuxAppTests/RemuxRootModelTests.swift`
- Modify: `RemuxAppUITests/RemuxAppUITests.swift`

**Interfaces:**
- Consumes: `GhosttyTerminalAppearancePolicy.currentDeviceFontSize(settings:) -> Float32?`
- Consumes: `RemuxRootModel.updateTerminalSettings(_:) async`
- Produces: `AppKeyboardCommand.increaseFontSize`
- Produces: `AppKeyboardCommand.decreaseFontSize`
- Produces: `AppKeyboardCommandRoute.adjustFontSize(by: Float32)`
- Produces: `TerminalSettings.adjustFontSize(by:effectiveDefault:)`
- Produces: `RemuxRootModel.adjustTerminalFontSize(by:effectiveDefault:) async`

- [ ] **Step 1: Add failing tests for defaults, adjustment rules, routing, persistence, and settings visibility**

In `RemuxAppTests/KeyboardSettingsTests.swift`, extend
`testDefaultsAssignEveryDocumentedCommand()`:

```swift
XCTAssertEqual(
    settings.binding(for: .increaseFontSize),
    KeyboardKeyBinding(input: "+", modifiers: [.command])
)
XCTAssertEqual(
    settings.binding(for: .decreaseFontSize),
    KeyboardKeyBinding(input: "-", modifiers: [.command])
)
```

In `RemuxAppTests/TerminalSettingsTests.swift`, add:

```swift
func testFontSizeAdjustmentStartsFromEffectiveDefaultAndThenUsesExplicitSize() {
    var settings = TerminalSettings(fontSize: nil, theme: .remuxDark)

    settings.adjustFontSize(by: 1, effectiveDefault: 12)
    XCTAssertEqual(settings.fontSize, 13)

    settings.adjustFontSize(by: -1, effectiveDefault: 20)
    XCTAssertEqual(settings.fontSize, 12)
}

func testFontSizeAdjustmentClampsToSupportedRange() {
    var maximum = TerminalSettings(
        fontSize: TerminalSettings.maximumFontSize,
        theme: .remuxDark
    )
    var minimum = TerminalSettings(
        fontSize: TerminalSettings.minimumFontSize,
        theme: .remuxDark
    )

    maximum.adjustFontSize(by: 1, effectiveDefault: 10)
    minimum.adjustFontSize(by: -1, effectiveDefault: 10)

    XCTAssertEqual(maximum.fontSize, TerminalSettings.maximumFontSize)
    XCTAssertEqual(minimum.fontSize, TerminalSettings.minimumFontSize)
}
```

In `RemuxAppTests/AppKeyboardCommandRouterTests.swift`, add:

```swift
func testFontSizeCommandsAreGlobalAdjustments() {
    let context = AppKeyboardCommandRouteContext(
        selectedSessionID: nil,
        isSelectedTerminalReady: false,
        orderedActiveSessionIDs: []
    )

    XCTAssertEqual(
        AppKeyboardCommandRouter.route(.increaseFontSize, in: context),
        .adjustFontSize(by: 1)
    )
    XCTAssertEqual(
        AppKeyboardCommandRouter.route(.decreaseFontSize, in: context),
        .adjustFontSize(by: -1)
    )
}
```

In `RemuxAppTests/RemuxRootModelTests.swift`, add:

```swift
func testAdjustTerminalFontSizePersistsAppGlobalSetting() async throws {
    let harness = makeHarness(
        settings: TerminalSettings(fontSize: nil, theme: .remuxDark)
    )
    await harness.model.load()

    await harness.model.adjustTerminalFontSize(
        by: 1,
        effectiveDefault: 12
    )

    XCTAssertEqual(harness.model.terminalSettings.fontSize, 13)
    let saved = try await harness.settingsRepository.loadSettings()
    XCTAssertEqual(saved.fontSize, 13)
}
```

In `RemuxAppUITests/RemuxAppUITests.swift`, extend
`testSettingsExposePhysicalKeyboardDefaults()`:

```swift
XCTAssertTrue(app.staticTexts["Increase Font Size"].waitForExistence(timeout: 2))
XCTAssertTrue(app.staticTexts["Decrease Font Size"].waitForExistence(timeout: 2))
XCTAssertTrue(app.staticTexts["⌘ +"].waitForExistence(timeout: 2))
XCTAssertTrue(app.staticTexts["⌘ -"].waitForExistence(timeout: 2))
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2' \
  -only-testing:RemuxTests/KeyboardSettingsTests \
  -only-testing:RemuxTests/TerminalSettingsTests \
  -only-testing:RemuxTests/AppKeyboardCommandRouterTests \
  -only-testing:RemuxTests/RemuxRootModelTests/testAdjustTerminalFontSizePersistsAppGlobalSetting
```

Expected: compilation fails because the two commands, adjustment route, and
font-size mutation APIs do not exist.

- [ ] **Step 3: Extend the command registry and configurable defaults**

In `RemuxApp/Sources/Domain/AppKeyboardCommand.swift`, add the cases:

```swift
case increaseFontSize
case decreaseFontSize
```

Add their display titles:

```swift
case .increaseFontSize:
    "Increase Font Size"
case .decreaseFontSize:
    "Decrease Font Size"
```

Treat them as global commands:

```swift
case .previousSession, .nextSession, .home, .commandPalette,
     .increaseFontSize, .decreaseFontSize:
    false
```

In `RemuxApp/Sources/Domain/KeyboardSettings.swift`, add these entries to
`KeyboardSettings.default.bindings`:

```swift
.increaseFontSize: KeyboardKeyBinding(input: "+", modifiers: [.command]),
.decreaseFontSize: KeyboardKeyBinding(input: "-", modifiers: [.command]),
```

Do not add decoding fallbacks, schema versions, or migrations.

- [ ] **Step 4: Add the bounded `TerminalSettings` mutation**

In `RemuxApp/Sources/Domain/TerminalSettings.swift`, add:

```swift
mutating func adjustFontSize(
    by delta: Float32,
    effectiveDefault: Float32
) {
    fontSize = Self.normalizedFontSize(
        (fontSize ?? effectiveDefault) + delta
    )
}
```

This reuses the existing normalization rule and makes the first adjustment
from automatic sizing explicit and testable.

- [ ] **Step 5: Route and persist the app-global adjustment**

In `RemuxApp/Sources/App/AppKeyboardCommandRouter.swift`, add:

```swift
case adjustFontSize(by: Float32)
```

Route the new commands before terminal-only routing:

```swift
case .increaseFontSize:
    return .adjustFontSize(by: 1)
case .decreaseFontSize:
    return .adjustFontSize(by: -1)
```

In `RemuxApp/Sources/App/RemuxRootModel.swift`, add:

```swift
func adjustTerminalFontSize(
    by delta: Float32,
    effectiveDefault: Float32
) async {
    await updateTerminalSettings { settings in
        settings.adjustFontSize(
            by: delta,
            effectiveDefault: effectiveDefault
        )
    }
}
```

In `RemuxApp/Sources/App/RootView.swift`, handle the new route:

```swift
case .adjustFontSize(let delta):
    let effectiveDefault =
        GhosttyTerminalAppearancePolicy.currentDeviceFontSize(
            settings: model.terminalSettings
        ) ?? TerminalSettings.defaultExplicitFontSize
    Task {
        await model.adjustTerminalFontSize(
            by: delta,
            effectiveDefault: effectiveDefault
        )
    }
```

The existing `updateTerminalSettings` path updates `terminalSettings`, refreshes
all active session models, and persists before returning.

- [ ] **Step 6: Forward font commands from an active terminal to root routing**

In `RemuxApp/Sources/Ghostty/GhosttySurfaceScreen.swift`, include the new global
commands in the forwarding branch of `performAppKeyboardCommand(_:)`:

```swift
case .previousSession, .nextSession, .home, .commandPalette,
     .increaseFontSize, .decreaseFontSize:
    onAppKeyboardCommand(command)
```

Do not alter terminal input for unmatched key events.

- [ ] **Step 7: Run focused unit tests and verify GREEN**

Run:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2' \
  -only-testing:RemuxTests/KeyboardSettingsTests \
  -only-testing:RemuxTests/TerminalSettingsTests \
  -only-testing:RemuxTests/AppKeyboardCommandRouterTests \
  -only-testing:RemuxTests/RemuxRootModelTests/testAdjustTerminalFontSizePersistsAppGlobalSetting
```

Expected: PASS.

- [ ] **Step 8: Run the focused settings UI test**

Run:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2' \
  -only-testing:RemuxUITests/RemuxAppUITests/testSettingsExposePhysicalKeyboardDefaults
```

Expected: PASS with both commands and their default bindings visible.

- [ ] **Step 9: Run full verification**

Run:

```bash
xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2'

xcodebuild test -quiet \
  -project Remux.xcodeproj \
  -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,id=9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2'

git diff --check
```

Expected: both schemes pass and `git diff --check` emits no output.

- [ ] **Step 10: Commit**

```bash
git status --short
git add \
  RemuxApp/Sources/Domain/AppKeyboardCommand.swift \
  RemuxApp/Sources/Domain/KeyboardSettings.swift \
  RemuxApp/Sources/Domain/TerminalSettings.swift \
  RemuxApp/Sources/App/AppKeyboardCommandRouter.swift \
  RemuxApp/Sources/App/RemuxRootModel.swift \
  RemuxApp/Sources/App/RootView.swift \
  RemuxApp/Sources/Ghostty/GhosttySurfaceScreen.swift \
  RemuxAppTests/KeyboardSettingsTests.swift \
  RemuxAppTests/TerminalSettingsTests.swift \
  RemuxAppTests/AppKeyboardCommandRouterTests.swift \
  RemuxAppTests/RemuxRootModelTests.swift \
  RemuxAppUITests/RemuxAppUITests.swift
git commit -m "Add global font size key bindings"
```
