# Floating Command Palette and New Remote Window

## Goal

Refine the global Command-K palette into a compact floating chooser that is
fully operable from a physical keyboard, and add a configurable Command-N
action that creates a new shell window inside the currently open remote tmux
session.

This is a focused extension of
`2026-07-26-physical-keyboard-commands-design.md`. It does not introduce a new
session model, pane type, or replacement terminal action.

## Floating Palette Presentation

The command palette appears as a centered, opaque card above the current route
and its existing dimming scrim. It uses the established Remux background, row
surface, separator, corner, and shadow styles.

The card sizes to its content rather than filling most of the display:

- its width is capped at 620 points with 16-point minimum screen margins;
- the input occupies one intrinsic single-line control row and never expands
  vertically;
- results size to their rows up to six visible items;
- additional results scroll within the card;
- the empty-search state remains compact rather than expanding to the previous
  520-point maximum height.

Tapping the scrim or close button dismisses the palette.

## Palette Keyboard Ownership

The search field becomes first responder as soon as the palette enters its
window. Palette results and the initial selection are established
synchronously, before the field can receive a physical-keyboard press.

The first enabled result is selected before any query is typed. Up and Down
move among enabled results and stop at the first or last item. Return invokes
the selected result. Escape dismisses the palette from its active responder
chain and does not leak to the terminal.

Changing the query replaces the result set and selects its first enabled item.
The selected row remains visibly highlighted and exposes the selected
accessibility trait.

## Command-N: New Remote Window

The command registry gains one configurable `New Window` action with
Command-N as its default binding.

The action is terminal-scoped:

- it is available only when a remote session is selected and ready;
- it creates one new tmux window in that existing remote session;
- it does not create a Remux connection, a new Remux saved session, or a tmux
  pane;
- outside a ready terminal it is unavailable and does not claim the key
  sequence.

Command-N calls the same tmux window-creation behavior used by the existing
`New Window` button. The keyboard path and button path share the topology
interaction effect, tracing, model call, and focus reconciliation. The
implementation does not synthesize a button tap or open the window chooser
first.

Because the command registry drives keyboard settings and palette command
items, `New Window` automatically appears in both places and can be rebound or
cleared under the existing validation rules.

No settings migration or backward-compatibility behavior is added. The
keyboard bindings have not shipped to users, so Command-N is introduced only
through the new default settings value.

## Error and Focus Behavior

If the selected remote terminal stops being ready before dispatch, the command
does nothing and sends no bytes to the remote shell. A rejected tmux topology
action follows the existing interaction-effect handling.

Dismissing the palette restores the terminal's established first-responder
policy. Unmodified text and unmatched key combinations continue through the
normal text-input path.

## Testing and Acceptance

Focused automated tests cover:

- Command-N's default binding, rebinding, clearing, and duplicate rejection
  through the existing settings contracts;
- terminal-scoped route availability;
- dispatch through the same new-window model action as the existing button;
- synchronous initial palette selection before typing;
- Up, Down, Return, and Escape handling;
- compact card sizing for zero, one, six, and more than six results.

UI tests cover opening the palette, seeing the first option already selected,
navigating before typing, invoking a result, dismissing with Escape where the
test driver can emit a physical Escape event, and verifying the compact
single-line input geometry.

Simulator evidence does not replace physical-keyboard acceptance. Before a
pull request, install a signed build on Jesse's iPhone and verify Command-K,
Escape, pre-query arrow navigation, Return activation, and Command-N against a
live remote tmux session.

## Out of Scope

- Changing the existing window chooser or pane chooser.
- Choosing a pane split direction for Command-N.
- Migrating an older keyboard-settings payload.
- Adding full-scrollback search or persistent result highlighting.
- Creating another Remux connection or saved session from Command-N.
