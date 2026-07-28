# Command Palette Spacing and Typography Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the approved Balanced spacing and Dynamic Type treatment to the
floating Command-K palette without changing its keyboard or search behavior.

**Architecture:** Keep `CommandPaletteView` as the palette's single view
composition. Add named layout values beside its existing row-height values,
apply the internal inset and clipping with SwiftUI modifiers, and configure the
specialized UIKit search field with a semantic font in its initializer. Extend
the existing unit and UI tests so the visual contract is checked through the
real field and rendered palette geometry.

**Tech Stack:** Swift 6, SwiftUI, UIKit, XCTest, XCUITest, XcodeBuildMCP,
Xcode 26.

## Global Constraints

- The palette remains centered and its width remains capped at 620 points.
- The outer card remains at least 20 points from every edge of its presentation
  container.
- The outer card has a 10-point inset around the grouped search and result
  surfaces.
- The inner group uses a 12-point continuous corner radius.
- The outer card keeps its existing opaque background, 18-point corner radius,
  border, shadow, and Remux semantic colors.
- Result titles use SwiftUI's dynamic `subheadline` style.
- The UIKit search field uses `UIFont.preferredFont(forTextStyle: .footnote)`
  and adjusts for Dynamic Type.
- Search and result row heights remain exactly 44 and 56 points.
- Search focus, Escape dismissal, arrow selection, Return activation, result
  filtering, and terminal-focus restoration do not change.
- Do not modify or stage `.superpowers/brainstorm/` or the four unrelated
  `.worktrees/` directories.

---

### Task 1: Apply the Balanced palette presentation

**Files:**

- Modify: `RemuxApp/Sources/App/CommandPaletteView.swift:4-223`
- Modify: `RemuxAppTests/CommandPaletteSearchTests.swift:148-190`
- Modify: `RemuxAppUITests/RemuxAppUITests.swift:146-181`

**Interfaces:**

- Consumes: `LibraryHomePalette` semantic colors,
  `CommandPaletteLayout.resultAreaHeight(for:)`, and the established
  `CommandPaletteTextField` responder behavior.
- Produces: `CommandPaletteLayout.screenMargin`,
  `CommandPaletteLayout.cardInset`,
  `CommandPaletteLayout.innerCornerRadius`, a compact Dynamic Type font on
  `CommandPaletteTextField`, and rendered card geometry with the approved
  margins.

- [ ] **Step 1: Add unit tests for the spacing and search-field type contracts**

Add these tests beside
`testFloatingLayoutCapsAtSixRowsAndKeepsEmptyStateCompact()` in
`RemuxAppTests/CommandPaletteSearchTests.swift`:

```swift
func testFloatingLayoutUsesBalancedSpacing() {
    XCTAssertEqual(CommandPaletteLayout.screenMargin, 20)
    XCTAssertEqual(CommandPaletteLayout.cardInset, 10)
    XCTAssertEqual(CommandPaletteLayout.innerCornerRadius, 12)
}

@MainActor
func testSearchFieldUsesCompactDynamicTypeFont() {
    let field = CommandPaletteTextField()
    let expected = UIFont.preferredFont(forTextStyle: .footnote)

    XCTAssertEqual(field.font?.pointSize, expected.pointSize)
    XCTAssertEqual(
        field.font?.fontDescriptor.object(forKey: .textStyle) as? String,
        UIFont.TextStyle.footnote.rawValue
    )
    XCTAssertTrue(field.adjustsFontForContentSizeCategory)
}
```

The spacing test catches a regression to the former 16-point screen padding or
the loss of the approved internal grouping. The field test catches a return to
the default body-sized UIKit font, a fixed 13-point font, or disabled Dynamic
Type scaling.

- [ ] **Step 2: Run the unit tests and verify RED**

With the XcodeBuildMCP defaults set to project `Remux.xcodeproj`, scheme
`Remux`, and simulator `9ECEBD90-D99E-4EBA-B233-A5D3CD6024F2`, run:

```text
test_sim(
  extraArgs: ["-only-testing:RemuxTests/CommandPaletteSearchTests"],
  progress: false
)
```

Expected: build failure because `screenMargin`, `cardInset`, and
`innerCornerRadius` do not exist. If compilation is temporarily limited to the
font test, it fails because the field still uses UIKit's default body-sized
font.

- [ ] **Step 3: Add a rendered-geometry UI assertion**

In
`testCommandPaletteSupportsKeyboardSelectionAndDismissal()`, immediately after
the palette appears, add:

```swift
let appFrame = app.frame
let minimumScreenMargin: CGFloat = 19.5
XCTAssertGreaterThanOrEqual(
    palette.frame.minX - appFrame.minX,
    minimumScreenMargin
)
XCTAssertGreaterThanOrEqual(
    appFrame.maxX - palette.frame.maxX,
    minimumScreenMargin
)
XCTAssertGreaterThanOrEqual(
    palette.frame.minY - appFrame.minY,
    minimumScreenMargin
)
XCTAssertGreaterThanOrEqual(
    appFrame.maxY - palette.frame.maxY,
    minimumScreenMargin
)
```

The half-point tolerance allows pixel alignment while still rejecting the
existing 16-point treatment. The assertion exercises the rendered card rather
than only the named value.

- [ ] **Step 4: Run the UI test and verify RED**

Set the XcodeBuildMCP scheme to `RemuxUIOnly` and run:

```text
test_sim(
  extraArgs: [
    "-only-testing:RemuxUITests/RemuxAppUITests/testCommandPaletteSupportsKeyboardSelectionAndDismissal"
  ],
  progress: false
)
```

Expected: FAIL because at least one horizontal palette margin is below
19.5 points under the current 16-point treatment. Restore the scheme to `Remux`
after recording the expected failure.

- [ ] **Step 5: Add the minimal layout and typography implementation**

Add the approved geometry beside the existing values in
`CommandPaletteLayout`:

```swift
static let screenMargin: CGFloat = 20
static let cardInset: CGFloat = 10
static let innerCornerRadius: CGFloat = 12
```

Give the result title its semantic style:

```swift
Text(item.title)
    .font(.subheadline)
    .lineLimit(1)
```

Clip the existing search/results stack and insert the internal space before
the outer card's frame and background:

```swift
.clipShape(
    RoundedRectangle(
        cornerRadius: CommandPaletteLayout.innerCornerRadius,
        style: .continuous
    )
)
.padding(CommandPaletteLayout.cardInset)
.frame(maxWidth: 620)
```

Keep the existing `fixedSize`, outer background, stroke, and shadow modifiers.
Apply the accessibility container and `command-palette` identifier to the card,
then replace the final screen padding with:

```swift
.padding(CommandPaletteLayout.screenMargin)
```

The accessibility identifier must continue containing the independently
addressable `command-palette.search` text field. Do not add an intermediate
accessibility container for the clipped group.

Configure the specialized field in `CommandPaletteTextField.init(frame:)`
before installing its delegate:

```swift
font = UIFont.preferredFont(forTextStyle: .footnote)
adjustsFontForContentSizeCategory = true
```

Do not change palette state, search, responder, or command-routing code.

- [ ] **Step 6: Run the unit tests and verify GREEN**

Set the XcodeBuildMCP scheme to `Remux` and run the focused unit class:

```text
test_sim(
  extraArgs: ["-only-testing:RemuxTests/CommandPaletteSearchTests"],
  progress: false
)
```

Expected: all palette unit tests pass with no failures.

- [ ] **Step 7: Run the focused UI tests and verify GREEN**

Set the XcodeBuildMCP scheme to `RemuxUIOnly` and run:

```text
test_sim(
  extraArgs: [
    "-only-testing:RemuxUITests/RemuxAppUITests/testCommandPaletteSupportsKeyboardSelectionAndDismissal",
    "-only-testing:RemuxUITests/RemuxAppUITests/testCommandPaletteReceivesImmediateTyping"
  ],
  progress: false
)
```

Expected: both tests pass. The geometry assertion proves the external margin,
and the immediate-typing test proves the visual wrapper did not disturb field
focus.

- [ ] **Step 8: Inspect and commit the implementation**

Run:

```bash
git diff --check
git status --short
git diff -- RemuxApp/Sources/App/CommandPaletteView.swift \
  RemuxAppTests/CommandPaletteSearchTests.swift \
  RemuxAppUITests/RemuxAppUITests.swift
```

Confirm only the three intended files changed. Then commit:

```bash
git add RemuxApp/Sources/App/CommandPaletteView.swift \
  RemuxAppTests/CommandPaletteSearchTests.swift \
  RemuxAppUITests/RemuxAppUITests.swift
git commit -m "Refine command palette spacing and type" \
  -m "Apply the approved Balanced palette treatment with a 20-point presentation margin, a 10-point inset around a clipped grouped surface, and smaller semantic Dynamic Type styles. Preserve the established row heights, colors, keyboard focus, and selection behavior." \
  -m "Cover the named layout contract, the real UIKit field configuration, rendered screen margins, and immediate keyboard focus."
```

### Task 2: Verify and install the finished build

**Files:**

- Verify: `RemuxApp/Sources/App/CommandPaletteView.swift`
- Verify: `RemuxAppTests/CommandPaletteSearchTests.swift`
- Verify: `RemuxAppUITests/RemuxAppUITests.swift`

**Interfaces:**

- Consumes: the committed Task 1 implementation and the existing signed iPhone
  build configuration.
- Produces: full automated evidence plus an installed device build ready for
  Jesse's visual and physical-keyboard acceptance.

- [ ] **Step 1: Run the full unit suite**

Set the XcodeBuildMCP scheme to `Remux` and run `test_sim(progress: false)`
without `only-testing` arguments.

Expected: every unit test passes. Record counts, failures, and warnings
separately.

- [ ] **Step 2: Run the full non-live UI suite**

Set the XcodeBuildMCP scheme to `RemuxUIOnly` and run
`test_sim(progress: false)` without `only-testing` arguments.

Expected: all non-live UI tests pass and configured live tests skip. If
XCUITest reports an infrastructure timeout, inspect the result and rerun the
affected test individually; report both outcomes rather than replacing the
original result.

- [ ] **Step 3: Inspect the final branch**

Run:

```bash
git diff --check
git status --short --branch
git log --oneline --decorate -10
```

Expected: no tracked changes remain. The brainstorm artifacts and four
unrelated worktrees remain untracked and untouched.

- [ ] **Step 4: Build, sign, install, and launch on Jesse's iPhone**

Use the existing device configuration:

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

xcrun devicectl device install app \
  --device 6A5C05AA-0987-5ECC-9937-7E3073636F1D \
  .local/device-build/Build/Products/Debug-iphoneos/Remux.app

xcrun devicectl device process launch \
  --device 6A5C05AA-0987-5ECC-9937-7E3073636F1D \
  com.fsck.dev.remux.app
```

Expected: the signed app verifies, installs, and launches on the unlocked
iPhone.

- [ ] **Step 5: Request hardware acceptance**

Ask Jesse to open Command-K and confirm:

- the palette reads as a floating card with visible space around and inside it;
- the search input and result titles are smaller but legible;
- typing still lands in the search field immediately;
- arrows, Return, and Escape still work.

Do not open a pull request until Jesse accepts this exact installed build.
