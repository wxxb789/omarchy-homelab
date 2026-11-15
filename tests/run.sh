#!/bin/bash
# Run every tests/test_*.sh file and print a clear summary.
#
# Usage: tests/run.sh [test-file ...]

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$repo_dir"

if (( $# > 0 )); then
  tests=("$@")
else
  shopt -s nullglob
  tests=(tests/test_*.sh)
fi

if (( ${#tests[@]} == 0 )); then
  echo "No tests found." >&2
  exit 1
fi

failures=0
passed=0

for test in "${tests[@]}"; do
  printf '\n==> %s\n' "$test"
  if bash "$test"; then
    printf 'PASS %s\n' "$test"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$test" >&2
    failures=$((failures + 1))
  fi
done

printf '\n%s passed, %s failed (%s total)\n' \
  "$passed" "$failures" "${#tests[@]}"

(( failures == 0 ))
