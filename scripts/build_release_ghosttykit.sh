#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ghostty_root="${GHOSTTY_SOURCE_DIR:-$repo_root/../ghostty-remux-upstream-rebuild}"
xcframework="$ghostty_root/macos/GhosttyKit.xcframework"
window_close_patch="$repo_root/patches/ghostty-window-close.patch"

if [[ ! -f "$ghostty_root/build.zig" ]]; then
  printf 'Ghostty source checkout not found at %s\n' "$ghostty_root" >&2
  printf 'Set GHOSTTY_SOURCE_DIR to the checkout consumed by Remux.\n' >&2
  exit 2
fi

if ! command -v zig >/dev/null 2>&1; then
  printf 'zig is required to build GhosttyKit.\n' >&2
  exit 127
fi

if [[ ! -f "$window_close_patch" ]]; then
  printf 'Ghostty window-close patch not found at %s\n' "$window_close_patch" >&2
  exit 2
fi

# Apply the pinned source change idempotently. Refuse incompatible source
# instead of resetting, cleaning, or force-applying over the caller's work.
if (
  cd "$ghostty_root"
  git apply --reverse --check "$window_close_patch" >/dev/null 2>&1
); then
  printf 'Ghostty window-close patch is already applied.\n'
elif (
  cd "$ghostty_root"
  git apply --check "$window_close_patch" >/dev/null 2>&1
); then
  (
    cd "$ghostty_root"
    git apply "$window_close_patch"
  )
  printf 'Applied Ghostty window-close patch.\n'
else
  printf 'Ghostty window-close patch does not match %s; refusing to modify source.\n' "$ghostty_root" >&2
  exit 3
fi

printf 'Building ReleaseFast GhosttyKit from %s\n' "$ghostty_root"
(
  cd "$ghostty_root"
  # Unstripped, so the app's dSYM resolves Ghostty frames in crash reports to
  # file and line. The debug info stays in the dSYM; the app keeps Ghostty's
  # unwind tables.
  zig build \
    -Doptimize=ReleaseFast \
    -Dstrip=false \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    "$@"
)

GHOSTTYKIT_XCFRAMEWORK="$xcframework" \
  "$repo_root/scripts/verify_ghosttykit_release_mode.sh"

# Record what is installed so fetch_ghosttykit.sh can tell a local build
# apart from the pinned release instead of silently keeping either.
source_ref="$(git -C "$ghostty_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$ghostty_root" diff --quiet 2>/dev/null; then
  source_ref="${source_ref}-dirty"
fi
printf 'local-build %s\n' "$source_ref" >"$(dirname "$xcframework")/.ghosttykit-provenance"
printf 'Recorded local-build provenance (%s).\n' "$source_ref"
