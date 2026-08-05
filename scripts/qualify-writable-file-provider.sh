#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

xcodegen generate
test -z "$(git diff --name-only -- Remux.xcodeproj/project.pbxproj RemuxFileProvider/Info.plist)"
rg -q 'NSExtensionFileProviderUploadPipelineDepth' project.yml
rg -q 'NSExtensionFileProviderMetadataOnlyUploadPipelineDepth' project.yml
if rg -q 'NSExtensionFileProviderReadOnly' project.yml RemuxFileProvider/Info.plist; then
  echo "read-only File Provider key is still present" >&2
  exit 1
fi

echo "Automated configuration checks passed."
echo "Live gate: manually reset only the development simulator domain."
echo "Live gate: run Files create/edit/rename/move/delete checks in the spec."
echo "Live gate: confirm non-empty directory deletion preserves every child."
