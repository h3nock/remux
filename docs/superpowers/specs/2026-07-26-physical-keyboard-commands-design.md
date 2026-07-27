# Physical Keyboard Commands and Floating Chrome

## Goal

Make Remux efficient on iPads with a connected physical keyboard without
changing its touch-first behavior when no physical keyboard is present.

The feature adds configurable app commands, a global command palette, exact
search over currently visible terminal text, and a setting that lets the
terminal use the full viewport while a physical keyboard is connected.

## Command Model

Remux owns a fixed set of app command actions. Each action has one optional,
persisted key binding. Bindings accept a key plus one or more of Command,
Shift, Option, and Control. Users may clear a binding. Remux rejects duplicate
bindings rather than choosing an arbitrary winner.

The default bindings are:

| Binding | Action |
| --- | --- |
| Command-Left Arrow | Focus the previous tmux window, matching the current swipe gesture |
| Command-Right Arrow | Focus the next tmux window, matching the current swipe gesture |
| Command-Shift-Left Arrow | Focus the previous active Remux session |
| Command-Shift-Right Arrow | Focus the next active Remux session |
| Command-H | Show Home |
| Command-O | Show the existing current-session window popup |
| Command-P | Show the existing pane popup |
| Command-A | Show the existing attachment menu |
| Command-K | Show the Remux command palette |

Window and session cycling wrap at both ends. Session cycling uses the same
ordering as Home's Active Sessions section. Commands that require a selected
terminal are unavailable outside an active terminal. Command-K is global and
works from Home as well as a terminal.

Command-H conflicts with an iPadOS system shortcut. Remux will request priority
over system behavior for configured app commands, but this behavior requires a
physical-device acceptance check and will not be claimed from simulator tests
alone.

## Persistence and Settings

Keyboard settings use a separate repository and JSON file rather than changing
the existing terminal-settings schema. This keeps existing terminal appearance
data independent and avoids a migration.

The keyboard settings screen is reachable from the existing settings flow and
contains:

- one editor row per app command;
- a capture control for assigning a modified key;
- a clear action for making a command unassigned;
- inline duplicate-binding validation;
- a global `Hide button bar when a physical keyboard is connected` toggle.

The hide-button-bar toggle defaults to enabled.

## Physical Keyboard Detection and Button Bar

Remux observes GameController's coalesced physical keyboard and its connection
and disconnection notifications. This covers Bluetooth keyboards, Apple's
Magic Keyboard attachment, and wired keyboards reported by iOS. Software
keyboard visibility is not treated as physical keyboard attachment.

Without a physical keyboard, the existing button bar and software-keyboard
layout remain unchanged.

With a physical keyboard connected:

- the button bar overlays the terminal instead of reducing terminal height;
- when the hide setting is enabled, the bar starts hidden;
- tapping a terminal surface reveals the bar without changing terminal size;
- the revealed bar hides after three seconds of inactivity;
- interacting with the bar restarts the three-second timer;
- when the hide setting is disabled, the floating bar remains visible;
- disconnecting the physical keyboard immediately restores the existing
  touch/software-keyboard layout.

Overlay presentation must not send a smaller viewport to tmux. The terminal
continues to occupy the full available window, and the bar may cover the bottom
edge temporarily.

## Command Routing

A central command registry owns action metadata, defaults, validation, and
display labels. A central router receives a resolved action and delegates it to
the current app state:

- Root navigation handles Home, active-session cycling, and the global command
  palette.
- The selected terminal screen handles adjacent tmux windows and the existing
  window, pane, and attachment presentations.
- Unsupported actions are disabled and do not leak through to the remote
  terminal.
- Unmatched physical-keyboard input continues through the existing Ghostty
  terminal input path.

The same action methods back button taps and keyboard commands so the two input
paths cannot drift.

## Command Palette

Command-K presents one global palette over the current route. It is separate
from Remux's existing saved-command Shortcut Palette.

With an empty query, the palette offers:

- `Add Connection`, which opens the existing connection setup;
- one `New Session on <host>` action per saved host, which opens the existing
  new-session form preselected for that host;
- available navigation and overlay commands.

Typing filters command actions and, after a short debounce, searches the
currently visible text of every pane in every tmux window belonging to every
active Remux session. Search is case-insensitive. Results show a short matching
line, session name, host, window name or index, and pane index.

Selecting a text result closes the palette and focuses its exact Remux session,
tmux window, and pane. No persistent match highlighting is added. Search covers
only the visible viewport; scrollback indexing is out of scope.

If a surface disappears while a search is running, its result is omitted. A
failed snapshot from one surface does not block results from other surfaces.
The palette cancels obsolete searches when the query changes or the palette
closes.

## GhosttyKit Boundary

The pinned GhosttyKit terminal-surface API can read a user selection but does
not expose a non-mutating snapshot of visible viewport text. Remux will add the
smallest required API to its GhosttyKit fork:

- read the currently presented viewport for one terminal surface;
- return owned UTF-8 text plus enough row information to form result snippets;
- avoid changing selection, scroll position, focus, or renderer state;
- expose only the visible presentation, not full scrollback;
- free returned storage through the matching terminal-surface allocator.

Remux wraps that API in `GhosttyKitControlSurface` and projects searchable
surface metadata through the existing tmux adapter. It does not reconstruct
terminal state from the byte stream or issue network `capture-pane` requests.

## Failure Handling

- Invalid or duplicate user bindings are not saved.
- A configured command that cannot act in the current route is ignored and is
  shown disabled in the palette.
- A disconnected session remains eligible for session navigation but has no
  searchable terminal results.
- Physical-keyboard connect/disconnect notifications are reconciled against
  the current coalesced keyboard value so duplicate or stale notifications do
  not strand the button bar.
- Search snapshot failures remain local to the affected pane.

## Testing and Acceptance

Focused tests cover:

- default bindings, clearing, custom capture, and duplicate rejection;
- repository round trips and missing-file defaults;
- route-aware command availability and dispatch;
- wrapping window and active-session navigation;
- palette command filtering, search debouncing, cancellation, result metadata,
  and selection routing;
- physical-keyboard connection projection and floating-bar visibility/timer
  state;
- GhosttyKit viewport snapshot ownership, visible-row boundaries, alternate
  screen behavior, and no selection/scroll mutation.

UI tests cover settings editing, global palette actions, reuse of the existing
window/pane/attachment presentations, and floating chrome geometry using a
deterministic physical-keyboard override.

Acceptance evidence remains separated:

1. focused automated tests for domain and routing behavior;
2. the full Remux simulator test suite;
3. rendered simulator checks proving the floating bar overlays rather than
   shrinks the terminal;
4. a physical iPad keyboard check for connection detection, command delivery,
   and the Command-H system-priority behavior.
