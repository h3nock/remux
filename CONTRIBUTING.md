# Contributing

- [docs/development.md](docs/development.md): set up, build, and run Remux.
- [docs/testing.md](docs/testing.md): unit, simulated UI, and live UI tests,
  and what CI runs.

## Pull Requests

- Keep each pull request to one change. Put unrelated fixes in their own pull
  request.
- Say what changed, why, and how you checked it.
- Run the unit tests. If you change `project.yml` or add, remove, or rename
  files, run `xcodegen generate` and commit the updated project.
- Changes to terminal rendering, keyboard handling, viewport geometry,
  scrolling, tmux pane or session state, or perceived latency need an
  end-to-end check on the simulator or a device, with a real tmux session.
  Unit tests, a passing build, or reading the code don't show that such a
  change works. Include screenshots, a video, or frame captures for visual
  changes, and before and after timings for latency changes. The
  [live UI tests](docs/testing.md#live-ui-tests) cover many of these paths.
- If you change libghostty, build GhosttyKit yourself (see
  [development.md](docs/development.md#building-ghosttykit-yourself)) and
  check Remux with that build.
- Don't commit credentials, server details, test result bundles, or build
  products.
