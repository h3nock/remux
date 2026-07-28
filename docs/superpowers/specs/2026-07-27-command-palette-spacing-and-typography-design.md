# Command Palette Spacing and Typography

## Goal

Give the floating Command-K palette enough space to read as a distinct window
and reduce its type scale so more results fit comfortably without weakening
its keyboard-first behavior.

This is a focused visual refinement of
`2026-07-27-floating-command-palette-and-new-remote-window-design.md`. Where
that design specified 16-point minimum screen margins, this refinement replaces
them with the approved 20-point margin.

## Approved Treatment

Use the Balanced treatment:

- keep the palette centered and cap its width at 620 points;
- keep at least 20 points between the palette card and each screen edge;
- add a 10-point inset between the outer card and the grouped search and
  result surfaces;
- render result titles with SwiftUI's dynamic `subheadline` text style;
- render the UIKit search field with the dynamic `footnote` text style;
- keep result subtitles at their existing caption styles;
- preserve the 44-point search row and 56-point result rows.

The 20-point value is external space around the card. The 10-point value is
visible internal space inside it. They are not interchangeable and must remain
independently testable.

## Card and Surface Structure

The outer card retains Remux's existing opaque background, 18-point corner
radius, border, and shadow. It provides the 10-point inset around one inner
rounded group containing the search row, separator, results, and empty state.

The inner group clips its row backgrounds and separators to a 12-point
continuous rounded rectangle, matching Remux's existing grouped surfaces. This
keeps list surfaces away from the outer card edge without introducing new
colors or a nested shadow. Search and result surfaces continue to use the
established Remux background, row, selection, and separator colors.

The card continues sizing to its content. Up to six results are visible;
additional results scroll inside the existing result area. The inset must not
increase the intrinsic search or result row heights.

## Typography

Result titles use `subheadline`, approximately 15 points at the default content
size. The UIKit search field uses
`UIFont.preferredFont(forTextStyle: .footnote)`, approximately 13 points at the
default content size, and adjusts for Dynamic Type. Existing caption and
caption2 styles remain unchanged for result descriptions and shortcut labels.

These are semantic text styles rather than fixed point sizes. Dynamic Type can
therefore increase them while the default presentation remains denser than the
current body-sized controls.

## Interaction Contract

This refinement does not change palette behavior. The search field still
becomes first responder when the palette opens. Escape dismisses it, Up and
Down change the selection before or after typing, and Return invokes the
selected result. Selection highlighting, accessibility identifiers, result
ordering, filtering, and terminal-focus restoration remain unchanged.

The scrim and tap-to-dismiss behavior also remain unchanged.

## Testing and Acceptance

Focused tests cover the independent layout constants for the 20-point screen
margin and 10-point card inset, the existing 44-point and 56-point row heights,
and the UIKit search field's semantic font style and Dynamic Type behavior.

A UI geometry assertion verifies that the rendered card remains at least
20 points from every edge of its presentation container. Existing focused UI
tests continue to verify first-responder ownership, keyboard selection,
activation, dismissal, and compact single-line input geometry.

Visual acceptance checks the default content size on Jesse's iPhone:

- the card reads as a floating window rather than an edge-to-edge sheet;
- the outer background is visibly present around the grouped rows;
- titles and search input are smaller without becoming difficult to scan;
- row and separator colors still match the surrounding app.

## Out of Scope

- Changing palette commands, search scope, ordering, or result contents.
- Changing keyboard bindings or responder-chain behavior.
- Changing the number of visible results or the established row heights.
- Introducing fixed font sizes, custom fonts, or a new palette color scheme.
