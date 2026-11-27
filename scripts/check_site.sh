#!/usr/bin/env bash
set -euo pipefail

# Checks the static site in remux-site: its script parses, and every asset the page names is in the folder.

site_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../remux-site" && pwd)"

node --check "${site_dir}/script.js"

while IFS= read -r asset; do
  test -f "${site_dir}/${asset}" || {
    printf 'Missing site asset: %s\n' "${asset}" >&2
    exit 1
  }
done < <(rg -o 'assets/[^"?, ]+' "${site_dir}/index.html" | sort -u)
