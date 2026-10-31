# Find in pane implementation plan

Status: design approved; implementation planning complete. First milestone is a
real endpoint feasibility experiment, before finishing the production UI.

- Branch: `feat/herdr-find-in-pane`
- Base: `main` at `250a2f5926b9b3948581bb1afe4e667feb2d827f`
- Approved prototype: Site `fd963992ccbd7805f7e667127f69abaa40666712`
- Independent investigation: Astra (`gpt-6-astra`), high effort, 31 October 2026.
  Its original response is preserved in the Find item in Remux Review.

## Contract

From the normal terminal, open Panes, hold a pane, then choose Find in pane. Keep
the approved native query field, clear, count, previous/next and close. There is
no search-options menu. Search is scoped to that pane's retained terminal output;
it does not inspect other panes or an application's private history.

Typing, paste, IME and hardware keys edit Find without reaching the terminal.
Hiding the query keyboard keeps Find active for reading. Closing removes its
decoration, retains the passage and leaves terminal typing off. Explicit Keyboard
resumes normal terminal input. Existing selection and Copy remain separate from
search highlights.

Use Herdr's matching semantics: literal text, Unicode smart case, non-overlapping
occurrences, soft wraps joined, hard lines separate. Preserve query text and
report the server's 4096 UTF-8 byte limit; do not silently trim, lowercase or
truncate it. Initial search starts near the reading position, using Herdr's
direction/wrap rules; keep the origin stable while refining a query rather than
letting intermediate searches move its starting point.

## What the code establishes

The installed CLI/default local server report Herdr 0.9.5. Astra checked its bundled
schema and tagged source `7573e821895d32c8d1f78b3f6c9a2f85a46df4ac`; relevant search
functions match the older local source checkout. Saved SSH hosts still require
their own negotiated method checks.

- `HerdrPaneProducer` holds no scrollback. The phone receives displayed cells;
  local Ghostty search cannot find the server's historical output.
- `pane.copy_search` returns an exact total and global ordinal, but at most 1024
  coordinate ranges around the selected match. This is a result window, not a
  limit on the number of occurrences.
- The server checks an exact, even content revision before and after its scan.
  Output, pruning, reflow and screen changes can invalidate coordinates. A stale
  response is not a zero-result response.
- Each search exports retained terminal text and its cell map, then scans it.
  The response cap does not bound server CPU, lock duration or temporary memory.
- Endpoint commands share one serial lane. Cancelling a Swift task does not
  retract a request already sent to the server.
- Revealing an offscreen match uses `pane.scroll`, followed by a new frame. That
  command has no revision precondition and changes Herdr's shared pane viewport.
  A client-side check cannot make this search/reveal pair atomic.
- Search decoration must match the content accepted by the terminal producer,
  not merely the latest topology snapshot. Existing selection owns Copy/handles
  and must not become search's multi-range highlight store.

## Approaches and selected baseline

| Approach | Why or why not |
| --- | --- |
| Existing server search + absolute scroll | Selected baseline: authoritative history and terminal-cell mapping, bounded replies, existing transport. Must measure full scans, stale responses and dependent reveal. |
| Local navigation through the current returned window | Use while its revision is valid. Saves another search for known adjacent hits; offscreen hits still need scroll/frame delivery. |
| Download history and search on the phone | Current APIs lack a complete, revision-safe history/cell export. Adds transfer, memory and synchronization ownership. Do not build this as a fallback. |
| Narrow server search/reveal extension | Contingency if normal streaming output or two-step reveal fails the feasibility experiment. Define revision/frame identity and live versus snapshot behavior explicitly. |
| Server incremental native search | Investigate only if measured scan costs justify it. Herdr does not currently wire it into this API; lifecycle and matching semantics differ. |
| Search only the phone's terminal surface | Does not meet retained-history scope. |

These choices are based on contracts, not a measured performance win. No search
latency benchmark has been run yet.

## Ownership, scheduling and presentation

Keep one active Find session scoped to connection generation, server boot and
pane ID. Its query generation, source revision/geometry, bounded result window
and selected ordinal belong with the existing Herdr engine. The screen owns
native field focus; the adapter projects availability, state and actions. Keep
backend state out of SwiftUI and command scheduling out of the field delegate.

Keep the existing command lane. Allow one in-flight search and one replaceable
latest intent, not a FIFO task for every keystroke or arrow tap. Check intent and
source validity again when work reaches dispatch. Empty query clears locally.
Closing drops unsent Find work; sent commands drain normally and their replies
cannot revive a closed or replaced Find session. Do not start another connection
or release the lane early to simulate cancellation. Select any short typing
coalescing interval from measurements; it is not the correctness mechanism.

Navigate within the valid returned window locally. Derive global position from
`current_global - current`; fetch the next window at a boundary. Wrap locally
only when the whole result set is present. No speculative window prefetch.

For an offscreen target, compute one absolute `pane.scroll` from current geometry,
then wait for the matching painted passage. Do not synthesize wheel input, which
could be forwarded to a fullscreen application. A local index change is not proof
that navigation has finished. Revalidate revision, width, active screen and scope
before drawing. Keep ordinary manual reading from being recentered on every new
frame or keyboard notification.

Try derived styling in `HerdrPanePainter` first. Keep canonical server cells,
hyperlinks and colors unchanged; apply highlight styles while serializing visible
rows. Repaint the old/new affected rows for Find-only changes and restore original
styles on clear/close. Feed text and decoration together under the engine's
existing producer transaction. Do not clone full frames per query or scan hidden
panes. Validate wide cells, graphics and reverse-video styling visually.

A UIKit overlay preserves text but adds temporal synchronization and composition
work; cell geometry alone cannot prevent a wrong-frame flash. A native decoration
API is a larger dependency. Use either only if the painter experiment demonstrates
a concrete limitation. Rebuild GhosttyKit before validation if native code changes.

Find remains an input owner with its keyboard hidden. Integrate with the existing
input/focus policy, suppress Panes-sheet keyboard restoration before dismissing
that sheet, and audit central key/paste/composer paths plus deferred input. Do not
toggle the pane's backend input setting. Pane navigation, popup takeover,
disconnect, boot replacement and pane deletion end Find; no silent retargeting.
Rotation/reflow invalidates coordinates. A keyboard height change keeps the query
and reconciles the passage against the actual new frame.

Offer the action only for supported Herdr endpoints/targets. Popup search and tmux
search are outside this first implementation; do not introduce a generic search
framework or hardcoded agent-specific behavior.

## Implementation and evidence sequence

1. **Feasibility slice.** Through the real Remux endpoint/lane, search known text,
   reveal an offscreen match and identify its accepted frame. Instrument queue,
   request/response, decode, reveal and first correct highlighted frame. Use a
   disposable session, leaving the user's working panes untouched. Exercise idle
   and streaming output before treating the existing API as sufficient.
2. **Bounded state and requests.** Add typed request/reply validation, latest-intent
   dispatch, result-window navigation and lifecycle invalidation. Cover delayed
   replies, clear/close, partial windows and connection replacement.
3. **Real terminal highlights.** Add the paint decoration, including explicit
   repaint when only Find changes, and verify original style/selection preservation.
4. **Approved native flow.** Add the pane action and bar, independent input owner,
   keyboard hide/close/read behavior and explicit return to terminal typing. Reuse
   existing focus, topology and viewport transitions.
5. **End-to-end verification.** Use the existing lean simulator setup with the real
   Herdr session/pane, then the phone. Record compact actual-interaction evidence.
   Add focused regression tests after proving the behavior; build/unit success
   alone does not establish a terminal UX or latency result.

Measure 1k/10k/large retained buffers at fixed geometry, sparse/dense/absent
queries, full/partial result windows, realistic agent output and controlled
continuous output. Include real SSH/Wi-Fi and added RTT. Report query-to-highlight
and arrow-to-correct-frame p50/p95, command count/bytes, queue depth, stale rate,
CPU/memory, and time to a usable result while output changes. Separate backend
search cost from network, lane wait, reveal and rendering. Establish numerical
budgets from this baseline rather than inventing a claim of instant results.

Correctness gates: no PTY input while Find owns input or after closing into
reading; no obsolete query decoration/reveal after scope changes; bounded pending
work; correct global ordinals beyond 1024 matches; correct Unicode/wrap mapping;
restored styles on close; readable passage through keyboard transitions; and no
ongoing search work when Find is closed. Validate two attached clients, width
changes, pruning, alternate-screen changes, selection/Copy and reconnects.

## Product tradeoffs requiring attention

The existing shared-scroll behavior means a desktop viewer of the same pane can
see Remux's jump, just as with ordinary history scrolling. Highlights stay local.
A private search viewport would require a different server boundary, not a local
scroll calculation.

Exact results during continuously changing output are the main unresolved
feasibility question. Keep the query, distinguish pending/stale from zero, and
never draw coordinates known to be invalid. Do not solve it with unbounded retries,
assumed append-only output or a silently frozen terminal. First measure ordinary
agent streaming. If useful results cannot be obtained promptly, bring back the
demonstrated tradeoff: accept a clearly defined refresh behavior, or make a narrow
server snapshot/search/reveal extension a prerequisite. This is the decision the
user may need to make; the source/API checks above are engineering work.
