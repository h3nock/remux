# Find in pane implementation plan

Status: approved design implemented in Remux using existing Herdr APIs. Simulator
validation and regression checks are recorded in [find-in-pane-validation.md](find-in-pane-validation.md).
Physical-phone functional checks also pass after the viewport-resize follow-up.
Performance budgets, independent code review and App CI remain release checks.

- Branch: `feat/herdr-find-in-pane`
- Base: `main` at `250a2f5926b9b3948581bb1afe4e667feb2d827f`
- Approved prototype: Site `fd963992ccbd7805f7e667127f69abaa40666712`
- Independent investigation: Astra (`gpt-6-astra`), high effort, 31 October 2026.
  Its original response and subsequent client-only reassessment are preserved in
  the Find item in Remux Review. The original upstream-change contingency was a
  planning error; the reassessment below uses only currently available APIs.

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

Herdr is an upstream dependency, not a repository we own. This implementation
changes Remux and uses Herdr's currently advertised APIs. It does not include a
Herdr patch, protocol extension, custom server fork or dependency on an upstream
release. If a measured API limit affects the approved UX, explain the feasible
Remux behavior and bring any meaningful UX compromise to the user. An upstream
proposal would be separate work, not an assumed implementation escape hatch.

| Approach | Why or why not |
| --- | --- |
| Existing server search + absolute scroll | Selected baseline: authoritative history and terminal-cell mapping, bounded replies, existing transport. Must measure full scans, stale responses and dependent reveal. |
| Local navigation through the current returned window | Use while its revision is valid. Saves another search for known adjacent hits; offscreen hits still need scroll/frame delivery. |
| Download history and search on the phone | Current APIs lack a complete, revision-safe history/cell export. Adds transfer, memory and synchronization ownership. Do not build this as a fallback. |
| Upstream search/reveal or incremental-search changes | Outside this Remux implementation. Astra considered these to identify API limits; they are not available client-side approaches or prerequisites we can assume. |
| Search only the phone's terminal surface | Does not meet retained-history scope. |

These choices are based on contracts, not a measured performance win. No search
latency comparison between client scheduling policies has been run yet.

### Client-only reassessment and evidence

The original exploration did not sufficiently compare client behavior after
freshness failures because it left an upstream change available as a fallback.
That recommendation is withdrawn. Astra re-examined the available client choices
at high effort and reviewed actual installed-0.9.5 endpoint probes.

| Client choice | Decision |
| --- | --- |
| Require Return to search | Fewer requests, but changes the approved typeahead flow. No demonstrated need for that interaction change. |
| Short trailing coalescing + latest-only dispatch | First baseline to measure: native editing stays immediate while obsolete queries are replaced before submission. |
| Eager latest-only throttle | Compare against the baseline for final-edit latency, scans and lane occupancy. Earlier dispatch alone does not establish better UX. |
| Keep old counts/highlights as current after output | Reject. A successful snapshot does not establish current global ordinals or coordinates after mutation. Keep the query and show pending in the existing status area. |
| Read a revision with copy-motion before each search | Not justified: scrolled-back probes continued receiving metadata; this adds another serial request without curing transmission races. |
| Export text via selection-read | Available copying is not a lossless history/cell/wrap export. A separate transcript reader changes the approved UX. |

In isolated fixed-80x24 fixtures, quiet 1k/10k histories each succeeded 20/20 and
reported exact counts, with a 1024-range window for 10k matches. Quiet search,
absolute scroll and the returned frame preserved content revision. With a target
50 writes/second and an artificial 50 ms outbound-only gap after capturing the
revision, all 20 searches were stale, both live and scrolled back. At 10 writes/
second and that gap, 9/20 live and 10/20 scrolled-back searches succeeded. This
supports bounded recovery; it does not prove failure for ordinary agent output.

These are local Unix endpoint observations, not SSH, iOS rendering or phone
latency measurements. Twenty requests per case do not establish universal success
rates. Fast stale errors are not successful-search performance wins. The probes
used the official installed binary, isolated XDG state and owned disposable
sessions; both servers stopped and their temporary directories were removed.
The raw receipts and harness are under
`.local/find-pane-implementation-20261031/` in the primary workspace.

## Ownership, scheduling and presentation

Keep one active Find session scoped to connection generation, server boot and
pane ID. Its query generation, source revision/geometry, bounded result window
and selected ordinal belong with Remux's existing `HerdrTerminalEngine`. The screen owns
native field focus; the adapter projects availability, state and actions. Keep
backend state out of SwiftUI and command scheduling out of the field delegate.

Keep the existing command lane. Allow one in-flight search and one replaceable
latest intent, not a FIFO task for every keystroke or arrow tap. Check intent and
source validity again when work reaches dispatch. Empty query clears locally.
Closing drops unsent Find work; sent commands drain normally and their replies
cannot revive a closed or replaced Find session or initiate another reveal. An
absolute scroll already sent can still complete: the API has no cancellation.
Preserve the last requested passage and never add an entry-offset/bottom reset.
Test close during reveal rather than promising that a remote action can be undone.
Do not start another connection
or release the lane early to simulate cancellation. Select any short typing
coalescing interval from measurements; it is not the correctness mechanism.

Use a finite freshness state: initial attempt, then at most one prompt retry on a
newer even painted revision. After that, wait for a revision-quiet interval before
one recovery attempt. Content revision changes reset the quiet deadline; they do not issue
a search per frame. A successful result invalidated by background output enters
quiet refresh directly. A new query or explicit navigation gets its own prompt
budget and replaces obsolete work. Keep pending distinct from a valid zero result
in the existing count/status area; preserve the query and add no new control.
No production coalescing/quiet interval is established by the current probes.

Navigate within the valid returned window locally. Derive global position from
`current_global - current`; fetch the next window at a boundary. Wrap locally
only when the whole result set is present. Rapid arrow taps update a desired
index or bounded signed step count, not a FIFO request per tap and not only the
last direction, which would lose intended steps. No speculative window prefetch.

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
   and streaming output with the bounded client algorithm. Compare trailing
   coalescing against eager latest-only throttling using realistic edit traces and
   lane waits; measure recovery after output stops. Existing endpoint-only probes
   establish backend behavior, not this complete client path.
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
reading; no obsolete local decoration or new unsent reveal work after scope
changes (already-issued scroll can drain); bounded pending
work; correct global ordinals beyond 1024 matches; correct Unicode/wrap mapping;
restored styles on close; readable passage through keyboard transitions; and no
ongoing search work when Find is closed. Validate two attached clients, width
changes, pruning, alternate-screen changes, selection/Copy and reconnects.

## Product tradeoffs requiring attention

The existing shared-scroll behavior means a desktop viewer of the same pane can
see Remux's jump, just as with ordinary history scrolling. Highlights stay local.
A private search viewport is not supplied by the current API; this implementation
preserves existing Herdr scroll semantics rather than promising one.

Exact results during continuously changing output are the main unresolved
feasibility question. Keep the query, distinguish pending/stale from zero, and
never draw coordinates known to be invalid. Do not solve it with unbounded retries,
assumed append-only output or a silently frozen terminal. First measure ordinary
agent streaming with the bounded algorithm. Arbitrarily fast continuous output
cannot be promised an exact fresh result at every instant; keep the interface
responsive and recover when a usable revision becomes available. Only an observed
conflict with the approved UX justifies proposing a product compromise. Do not
silently require Return, add Refresh/freeze controls or introduce another reader.
Bring any demonstrated need for a UX change to the user first. No Herdr change is
a prerequisite, and coordinate correctness remains intact.
