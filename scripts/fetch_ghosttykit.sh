#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt ReleaseFast GhosttyKit.xcframework release asset and
# places it at the path configured in project.yml, so building Remux does not
# require Zig or a Ghostty checkout.

release_tag="ghosttykit-20261024"
asset_sha256="5b8e54fe13521aa0ab2d3f23f179d43545acc1cb992d85eb0055980dad22f18f"
asset_url="https://github.com/h3nock/remux-ghostty/releases/download/${release_tag}/GhosttyKit.xcframework.zip"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Must match the framework path in project.yml.
framework_parent="$repo_root/../ghostty-remux-upstream-rebuild/macos"
framework_path="$framework_parent/GhosttyKit.xcframework"
# Written by this script and build_release_ghosttykit.sh so an installed
# framework can be matched against the pinned release above.
provenance_path="$framework_parent/.ghosttykit-provenance"

usage() {
  echo "Usage: scripts/fetch_ghosttykit.sh [--force | --verify]" >&2
  exit 2
}

mode="install"
case "${1:-}" in
  "") ;;
  --force) mode="force" ;;
  --verify) mode="verify" ;;
  *) usage ;;
esac
[[ $# -le 1 ]] || usage

# Hashes every file in the framework. It is recorded at install so a build
# written over this path later no longer passes as the release: Ghostty's own
# build writes here without touching the provenance record.
framework_digest() {
  (cd "$framework_path" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) |
    shasum -a 256 | awk '{print $1}'
}

installed_kind=""
installed_ref=""
installed_sha=""
installed_digest=""
if [[ -f "$provenance_path" ]]; then
  read -r installed_kind installed_ref installed_sha installed_digest <"$provenance_path" || true
fi

installed_state() {
  if [[ ! -d "$framework_path" ]]; then
    echo missing
  elif [[ "$installed_kind" == "local-build" ]]; then
    echo local-build
  elif [[ "$installed_kind" != "release" ]]; then
    echo unrecorded
  elif [[ "$installed_ref" != "$release_tag" || "$installed_sha" != "$asset_sha256" ]]; then
    echo other-release
  elif [[ -z "$installed_digest" ]]; then
    echo undigested
  elif [[ "$installed_digest" != "$(framework_digest)" ]]; then
    echo modified
  else
    echo pinned
  fi
}

describe_state() {
  case "$1" in
    missing) echo "No GhosttyKit is installed." ;;
    local-build) echo "It was built locally from $installed_ref." ;;
    unrecorded) echo "It has no provenance record." ;;
    other-release) echo "It is release $installed_ref." ;;
    undigested) echo "It was installed before file digests were recorded, so its contents can't be checked." ;;
    modified) echo "Its files have changed since release $release_tag was installed." ;;
  esac
}

state="$(installed_state)"

if [[ "$mode" == "verify" ]]; then
  if [[ "$state" != "pinned" ]]; then
    echo "GhosttyKit at $framework_path is not the pinned release $release_tag." >&2
    describe_state "$state" >&2
    echo "Run scripts/fetch_ghosttykit.sh --force to install it." >&2
    exit 1
  fi
  echo "Verified GhosttyKit release $release_tag at $framework_path"
  exit 0
fi

if [[ "$mode" == "install" ]]; then
  case "$state" in
    pinned)
      echo "GhosttyKit release $release_tag already installed at:"
      echo "  $framework_path"
      exit 0
      ;;
    missing) ;;
    other-release)
      echo "Installed GhosttyKit ($installed_ref) does not match pinned release $release_tag; reinstalling."
      ;;
    *)
      echo "Keeping existing GhosttyKit at:"
      echo "  $framework_path"
      echo "$(describe_state "$state") The pinned release is $release_tag."
      echo "Re-run with --force to replace it with release $release_tag."
      exit 0
      ;;
  esac
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

printf 'release %s %s %s\n' "$release_tag" "$asset_sha256" "$(framework_digest)" >"$provenance_path"

echo "Done. Generate the project with 'xcodegen generate' and build."
