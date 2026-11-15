#!/bin/bash
# Manifest invariants that CI can check without an Omarchy session.

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

new_sandbox

manifest="$repo_dir/manifest.json"
entry=$(jq -r '.entryPoints.barWidget // ""' "$manifest")
id=$(jq -r '.id // ""' "$manifest")
section=$(jq -r '.barWidget.defaultSection // ""' "$manifest")

jq -e . "$manifest" >/dev/null || fail "manifest is not valid JSON"
[[ $(jq -r '.schemaVersion' "$manifest") == 1 ]] ||
  fail "manifest schemaVersion must be 1"
[[ -n $id && $id != omarchy.* ]] ||
  fail "manifest id must be non-empty and outside the reserved omarchy.* namespace"
[[ -n $entry && $entry != /* && $entry != *".."* ]] ||
  fail "barWidget entry point must be a safe relative path"
[[ -f $repo_dir/$entry ]] ||
  fail "barWidget entry point does not exist: $entry"
[[ $(jq -r '.license // ""' "$manifest") == MIT ]] ||
  fail "manifest license must be MIT"
[[ $(jq -r '(.kinds // []) | index("bar-widget")' "$manifest") != null ]] ||
  fail "manifest must declare the bar-widget kind"
case $section in
  left|centerBegin|center|centerEnd|tray|right) ;;
  *) fail "invalid barWidget.defaultSection: $section" ;;
esac

ok "manifest has a valid id, entry point, license, kind, and section"
