#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt ReleaseFast GhosttyKit.xcframework release asset and
# places it at the path configured in project.yml, so building Remux does not
# require Zig or a Ghostty checkout.

release_tag="ghosttykit-20260804"
asset_sha256="194b9edeaf146672a95716c61877b198105551917f5dd33ec48a6cff7f2f9de4"
asset_url="https://github.com/h3nock/remux-ghostty/releases/download/${release_tag}/GhosttyKit.xcframework.zip"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Must match the framework path in project.yml.
framework_parent="$repo_root/../ghostty-remux-upstream-rebuild/macos"
framework_path="$framework_parent/GhosttyKit.xcframework"
# Written by this script and build_release_ghosttykit.sh so an installed
# framework can be matched against the pinned release above.
provenance_path="$framework_parent/.ghosttykit-provenance"

force=0
if [[ "${1:-}" == "--force" ]]; then
  force=1
elif [[ -n "${1:-}" ]]; then
  echo "Usage: scripts/fetch_ghosttykit.sh [--force]" >&2
  exit 2
fi

if [[ -d "$framework_path" && "$force" -ne 1 ]]; then
  installed_kind=""
  installed_ref=""
  installed_sha=""
  if [[ -f "$provenance_path" ]]; then
    read -r installed_kind installed_ref installed_sha <"$provenance_path" || true
  fi

  if [[ "$installed_kind" == "release" &&
    "$installed_ref" == "$release_tag" &&
    "$installed_sha" == "$asset_sha256" ]]; then
    echo "GhosttyKit release $release_tag already installed at:"
    echo "  $framework_path"
    exit 0
  fi

  if [[ "$installed_kind" == "release" ]]; then
    echo "Installed GhosttyKit ($installed_ref) does not match pinned release $release_tag; reinstalling."
  else
    echo "Keeping existing GhosttyKit at:"
    echo "  $framework_path"
    if [[ "$installed_kind" == "local-build" ]]; then
      echo "It was built locally from $installed_ref; the pinned release is $release_tag."
    else
      echo "It has no provenance record; the pinned release is $release_tag."
    fi
    echo "Re-run with --force to replace it with release $release_tag."
    exit 0
  fi
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
zip_path="$workdir/GhosttyKit.xcframework.zip"

echo "Downloading GhosttyKit ($release_tag)..."
curl --fail --location --progress-bar --output "$zip_path" "$asset_url"

echo "Verifying checksum..."
actual_sha256="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
if [[ "$actual_sha256" != "$asset_sha256" ]]; then
  echo "Checksum mismatch for downloaded GhosttyKit archive." >&2
  echo "  expected: $asset_sha256" >&2
  echo "  actual:   $actual_sha256" >&2
  exit 1
fi

echo "Installing to $framework_path"
mkdir -p "$framework_parent"
rm -f "$provenance_path"
rm -rf "$framework_path"
ditto -x -k "$zip_path" "$framework_parent"

if [[ ! -d "$framework_path" ]]; then
  echo "Archive did not contain GhosttyKit.xcframework at its root." >&2
  exit 1
fi

printf 'release %s %s\n' "$release_tag" "$asset_sha256" >"$provenance_path"

echo "Done. Generate the project with 'xcodegen generate' and build."
