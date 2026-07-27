# Command Palette Focus and Surfaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Command-K palette own keyboard input immediately and render it and the Physical Keyboard settings row with Remux's established opaque app surfaces.

**Architecture:** Propagate the root palette-presentation state into the selected terminal screen as an app-level transient input owner, then fold it into the existing terminal responder focus policy. Expose the existing app palette under a domain-appropriate shared name and apply its dynamic background, row, and separator colors to the command palette and keyboard settings entry.

**Tech Stack:** Swift 6, SwiftUI, UIKit responder integration, XCTest, XCUITest, Xcode

## Global Constraints

- Preserve touch-first behavior when the command palette is closed.
- Use Remux's existing dynamic grouped background, row surface, separator, corner treatment, and color-scheme behavior.
- The palette panel and list must be opaque; terminal content must not bleed through.
- Typing immediately after Command-K must enter the palette query without a tap or terminal input leakage.
- Dismissing the palette must restore the terminal's existing focus policy.
- Keep the change limited to palette focus and the two requested surfaces.

---

### Task 1: Command Palette Input Ownership

**Files:**
- Modify: `RemuxAppUITests/RemuxAppUITests.swift:186`
- Modify: `RemuxApp/Sources/App/RootView.swift:192`
- Modify: `RemuxApp/Sources/App/RootView.swift:399`
- Modify: `RemuxApp/Sources/Ghostty/GhosttySurfaceScreen.swift:52`
- Modify: `RemuxApp/Sources/App/CommandPaletteView.swift:3`

**Interfaces:**
- Consumes: `RemuxWorkspaceShell.isCommandPalettePresented: Bool` and `GhosttyTerminalResponderFocusPolicy.isTransientInputOwnerPresented: Bool`
- Produces: `ActiveTerminalSessionView.isAppInputOwnerPresented: Bool` and `GhosttySurfaceScreen.init(..., isAppInputOwnerPresented: Bool = false, ...)`

- [ ] **Step 1: Write the failing live UI regression**

Extend `testLivePhysicalKeyboardRevealsFloatingButtonBarAndOpensCommandPaletteWhenConfigured()` so it types without tapping the search field:

```swift
let searchField = app.textFields["command-palette.search"]
XCTAssertTrue(searchField.waitForExistence(timeout: 2))

app.typeText("palette focus")

XCTAssertEqual(searchField.value as? String, "palette focus")
```

- [ ] **Step 2: Run the regression to verify it fails**

Run:

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxAppUITests/RemuxAppUITests/testLivePhysicalKeyboardRevealsFloatingButtonBarAndOpensCommandPaletteWhenConfigured
```

Expected: the palette appears, but the search field does not receive the typed text because the selected terminal remains eligible to reclaim first responder.

- [ ] **Step 3: Propagate app input ownership to the terminal**

Add `isAppInputOwnerPresented` to `ActiveTerminalSessionView` and `GhosttySurfaceScreen`, pass `isCommandPalettePresented` from `RemuxWorkspaceShell`, and combine it with the existing focus gate:

```swift
private var isTransientInputOwnerPresented: Bool {
    isAppInputOwnerPresented
        || isAttachmentInputOwnerPresented
        || terminalCoverPhase.ownsTerminalInput
}
```

- [ ] **Step 4: Request search focus after responder reconciliation**

Replace the immediate `onAppear` focus request with a view task that seeds results, yields once on the main actor, and then focuses the search field:

```swift
.task {
    results = commands
    await Task.yield()
    isSearchFocused = true
}
```

- [ ] **Step 5: Run the regression to verify it passes**

Run the Step 2 command.

Expected: PASS; typing immediately after Command-K updates `command-palette.search`.

- [ ] **Step 6: Commit the input ownership fix**

```bash
git add RemuxAppUITests/RemuxAppUITests.swift \
  RemuxApp/Sources/App/RootView.swift \
  RemuxApp/Sources/Ghostty/GhosttySurfaceScreen.swift \
  RemuxApp/Sources/App/CommandPaletteView.swift
git commit -m "Keep command palette keyboard focus"
```

### Task 2: Remux Design-System Surfaces

**Files:**
- Modify: `RemuxApp/Sources/App/RootView.swift:799`
- Modify: `RemuxApp/Sources/App/RootView.swift:1345`
- Modify: `RemuxApp/Sources/App/CommandPaletteView.swift:14`

**Interfaces:**
- Consumes: the existing dynamic colors currently exposed privately by `LibraryHomePalette`
- Produces: shared `RemuxAppPalette.background`, `RemuxAppPalette.rowSurface`, and `RemuxAppPalette.separator` colors

- [ ] **Step 1: Expose the existing palette under an app-wide name**

Rename `LibraryHomePalette` to internal `RemuxAppPalette` and update its existing references without changing color values:

```swift
enum RemuxAppPalette {
    static let background = Color(uiColor: .libraryHomeBackground)
    static let rowSurface = Color(uiColor: .libraryHomeRowSurface)
    static let separator = Color(uiColor: .libraryHomeSeparator)
    // Preserve the remaining existing semantic colors.
}
```

- [ ] **Step 2: Apply the grouped surface to the Physical Keyboard settings entry**

Apply the existing row modifier to the first settings section:

```swift
Section {
    NavigationLink("Physical Keyboard") {
        KeyboardSettingsView(
            initialSettings: keyboardSettings,
            onChange: onKeyboardSettingsChange
        )
    }
    .accessibilityIdentifier("settings.physical-keyboard")
}
.libraryHomeListRowSurface()
```

- [ ] **Step 3: Replace the translucent palette material**

Hide the `List` scroll background, apply `RemuxAppPalette.rowSurface` to result rows, use `RemuxAppPalette.background` for the panel, and draw a subtle separator-colored border:

```swift
.listRowBackground(RemuxAppPalette.rowSurface)
.listRowSeparatorTint(RemuxAppPalette.separator)
```

```swift
.background(
    RemuxAppPalette.background,
    in: RoundedRectangle(cornerRadius: 18)
)
.overlay {
    RoundedRectangle(cornerRadius: 18)
        .stroke(RemuxAppPalette.separator, lineWidth: 1)
}
```

- [ ] **Step 4: Run focused and full simulator verification**

Run:

```bash
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxAppTests \
  -only-testing:RemuxAppUITests/RemuxAppUITests/testSettingsExposePhysicalKeyboardDefaults \
  -only-testing:RemuxAppUITests/RemuxAppUITests/testLivePhysicalKeyboardRevealsFloatingButtonBarAndOpensCommandPaletteWhenConfigured
```

Then run the repository's full documented simulator test command from `docs/development.md`.

Expected: all selected tests and the full suite pass.

- [ ] **Step 5: Commit the surface integration**

```bash
git add RemuxApp/Sources/App/RootView.swift \
  RemuxApp/Sources/App/CommandPaletteView.swift
git commit -m "Match palette and keyboard settings surfaces"
```

### Task 3: Physical Device Build

**Files:**
- No source changes expected.

**Interfaces:**
- Consumes: the completed Debug app and Jesse's registered iPhone 16 Pro
- Produces: installed and launched `com.fsck.dev.remux.app`

- [ ] **Step 1: Build for Jesse's iPhone**

Run:

```bash
xcodebuild build -project Remux.xcodeproj -scheme Remux -configuration Debug \
  -destination 'id=6A5C05AA-0987-5ECC-9937-7E3073636F1D' \
  -derivedDataPath .local/device-build \
  DEVELOPMENT_TEAM=87WJ58S66M \
  PRODUCT_BUNDLE_IDENTIFIER=com.fsck.dev.remux.app \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Install and launch**

Run:

```bash
xcrun devicectl device install app \
  --device 6A5C05AA-0987-5ECC-9937-7E3073636F1D \
  .local/device-build/Build/Products/Debug-iphoneos/Remux.app
xcrun devicectl device process launch \
  --device 6A5C05AA-0987-5ECC-9937-7E3073636F1D \
  --terminate-existing com.fsck.dev.remux.app
```

Expected: install and launch both succeed.

- [ ] **Step 3: Record final evidence**

Report focused-test results, full-suite results, device build/install/launch status, and the remaining manual visual/input acceptance boundary separately.
