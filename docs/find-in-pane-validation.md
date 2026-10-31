# Find in pane validation

Production implementation on `feat/herdr-find-in-pane`, based on main `250a2f59`.
Herdr remains an unmodified upstream dependency. Search requires advertised
`pane.copy_search` and `pane.scroll`; unsupported backends expose no Find action.

## End-to-end environment

Xcode 27 beta, iPhone 17 Pro / iOS 27 lean simulator `remux-find-in-pane`.
Official Herdr 0.9.5, isolated XDG directories and named `remux-ui` session,
connected through a dedicated loopback SSH server. No user working pane was used.
The existing pinned ReleaseFast GhosttyKit artifact was verified; native code did
not change. This is a production Remux build, not the standalone prototype.

CUA operated Device Hub, native controls and the onscreen keyboard. Screen
recordings and unmodified simulator PNGs are attached to the Find item in Remux
Review. Video compression preserves playback speed. The fixture records PTY bytes
independently, so search text appearing in the native field is not input evidence
by itself.

Verified in the initial production pass:

- Actual retained history search and previous/next reveal, with local highlights.
- Software-keyboard `warning` produces 13 matches: 12 diagnostic lines and the
  fixture's final sentence containing `warnings`. This differs from the
  standalone prototype's 12-match sample.
- Search hides the keyboard while Find remains. Close removes highlights and
  leaves the passage readable, with terminal keys disabled. Explicit Keyboard
  resumes typing. The PTY log stayed empty through query/navigation/close; only
  the subsequently typed `ok\r` reached it.
- A wide CJK character and a decomposed combining character retain their glyphs
  and receive the expected highlight. A single query spanning three soft-wrapped
  rows highlights its spaces and complete cell range. An absent query displays
  `0` and disables navigation.
- During controlled 10 Hz output, invalid coordinates are removed and status
  becomes `Searching…`. The query recovers automatically after output settles.
  This short pass sent two searches over about five seconds rather than one
  per arriving frame. It does not guarantee an exact result during arbitrary
  continuous output.
- A 1,600-match fixture verified forward/backward wrap outside the 1,024-range
  response window. The same pass exposed a resize refresh selecting the first
  visible occurrence rather than the active one. Refresh now uses the selected
  cell as a search hint, including Herdr's strict-after-cursor semantics; only a
  newly revision-checked result can restore decoration. Width/screen remaps reset
  that hint. This is not a guarantee of identity through history pruning.
- After the anchor fix, the settled keyboard-hide refresh retained `1600 of
  1600`; reopening the field retained it too. Final responder cleanup also
  verified close with the keyboard open → disabled terminal keys → one Keyboard
  tap → normal `ok` input. The combined PTY receipt contains exactly `ok\rok\r`
  from two explicit resume checks, with no search text.
- Find opened on an unfocused second pane, focused that pane, and returned only
  its `right-only` match. Native terminal selection/Copy remained independent:
  `right-only` was copied from highlighted terminal text and pasted into the
  native Composer without submitting it.

## Physical phone follow-up

Terra tested the Release build on an iPhone 14 Pro Max / iOS 27.2 through Device
Hub, using the saved Tailscale SSH connection over phone Wi-Fi and a disposable
Herdr session. This is not a direct-LAN latency benchmark.

The phone run reproduced a keyboard-resize issue in `c1490263`: file3 remained
selected at `3 of 12`, but reopening the keyboard moved it above the viewport.
`3666f4d8` makes geometry refresh request a newly validated reveal; ordinary
output refresh still preserves the reading position. The same case passed on the
phone with keyboard capture both on and off. The selected line briefly leaves
view during pending refresh, then becomes readable after it settles. Paired
stills document that result; the timed fixed-build recording ended before the
transition, so it is not transition evidence.

Other phone passes: retained search, next/previous, zero/clear, 1,600-match wrap
across the response window, changing-output pending/quiet recovery, Copy into
Composer and Find, an unfocused pane, a full wide glyph and a three-row wrapped
match. Closing Find preserved reading and required one Keyboard tap to resume.
The final onscreen `o`, `k`, Return check added exactly `ok\r` to the PTY log;
an earlier CR-only attempt was inconclusive for letters and was repeated. No
typed/pasted query or unsent Composer text appeared in that receipt.

The geometry change's 107-case Find/engine/painter run completed with
`TEST SUCCEEDED`. The fixed Release build remains installed. The disposable
server was stopped and keyboard capture restored off. The original Terra report,
phone captures and hashes are attached to the Find item in Remux Review. This is
functional validation; independent production code review is still pending.

## Timing policy

The implementation uses a 120 ms trailing edit pause and a 200 ms revision-quiet
recovery interval after the fresh-frame retry budget. Navigation inside a valid
response window uses cached coordinates; it does not rescan retained history.

A separate scheduling experiment used the installed Herdr endpoint, a fixed
80×24 owned fixture with 1,600 diagnostic matches, and eight trials per scenario.
The edit trace was synthetic; this is neither iOS presentation nor SSH latency.
The optional initial lane hold was a simulated admission delay.

| Edit spacing | Initial hold | Policy | Scans/query | Final edit → reply median / p95 |
| --- | --- | --- | --- | --- |
| 90 ms | 0 | trailing 120 ms | 1 | 145.9 / 151.0 ms |
| 90 ms | 0 | eager, throttled 120 ms | 6 | 74.4 / 91.0 ms |
| 180 ms | 0 | trailing 120 ms | 7 | 140.7 / 147.7 ms |
| 180 ms | 0 | eager, throttled 120 ms | 7 | 20.0 / 29.3 ms |
| 90 ms | 250 ms | trailing 120 ms | 1 | 143.9 / 151.2 ms |
| 90 ms | 250 ms | eager, throttled 120 ms | 4 | 97.4 / 104.0 ms |

The trailing policy reduces scans during bursts at the cost of its final pause;
it does not reduce scan work for slower typing. This supports the conservative
initial policy, not a universal performance win. No adaptive heuristics were added.

The initial real app pass committed query decoration to its terminal producer
about 131–150 ms after the final edit over loopback SSH. Cached arrow actions
committed in roughly 6–15 ms. These small samples are **producer commit** times,
not GPU-presented frame percentiles. The trace is named `find.committed` to keep
that distinction explicit.

## Regression coverage and limits

Focused tests cover dispatch-time revision capture, superseded/closed replies,
input blocking and explicit resume, one fresh-frame retry followed by quiet
recovery, taps during a sent reveal, reply identity/bounds, global window ordinals,
visible wrapped decoration, and connection-end projection cleanup. Existing
Herdr model, engine, painter and selection suites are also exercised.

The combined pre-anchor run reported 344 passing cases. Xcode hung while
finalizing its result bundle, so its retained console is the evidence for that
run. The separate nine-case boundary run completed with `TEST SUCCEEDED`.
After the anchor change, the 106-case Find/engine/painter run also completed with
`TEST SUCCEEDED`. The final responder-only change built successfully and was
verified through the actual keyboard-close/resume flow above.

Quantified physical-device/Wi-Fi latency, CPU/memory budgets, imposed network RTT, long
pruning runs, arbitrary IME/hardware keyboards, two visible clients and all
selection/graphics combinations are not established by these checks. Keep those
release gates separate from this implementation's simulator evidence. Find
preserves Herdr's shared runtime scroll behavior; highlights are local. A sent
scroll cannot be cancelled by the existing API, while unsent obsolete work is
discarded. No independent production code approval is claimed.
