#!/bin/bash
# Doctor: dependencies, laptop detection, units, lock, panel, power, and state.

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

new_sandbox

homelab="$repo_dir/bin/homelab"
state_dir="$XDG_STATE_HOME/homelab"
flag="$state_dir/enabled"

set_lid open

out=$("$homelab" doctor)
assert_line "$out" '^\[ok\]   laptop lid detected$' \
  "doctor detects the laptop"
assert_line "$out" '^\[ok\]   consistent$' \
  "doctor reports a clean Laptop mode"

if "$homelab" doctor extra >/dev/null 2>&1; then
  fail "doctor should reject arguments"
fi

# A non-laptop fails the hardware check.
FAKE_LAPTOP=no
if out=$("$homelab" doctor 2>&1); then
  fail "doctor should fail without a laptop lid"
fi
assert_line "$out" '^\[fail\] no laptop lid detected$' \
  "doctor reports the missing lid"
FAKE_LAPTOP=yes

# A unit without the actual logind lock is a hard failure.
mkdir -p "$state_dir"
: >"$flag"
systemctl --user start homelab-inhibit.service
if out=$(FAKE_LOCK=missing "$homelab" doctor 2>&1); then
  fail "doctor should fail when the inhibitor unit has no lock"
fi
assert_line "$out" '^\[fail\] inhibitor unit active but no handle-lid-switch lock$' \
  "doctor reports an active unit without a lock"
"$homelab" off >/dev/null

# Battery and linger warnings are not failures.
set_battery 15
FAKE_AC=no FAKE_LINGER=no "$homelab" on >/dev/null 2>&1
if ! out=$(FAKE_AC=no FAKE_LINGER=no "$homelab" doctor 2>&1); then
  fail "doctor warnings should not be failures"
fi
assert_line "$out" '^\[warn\] linger no; mode starts after login only$' \
  "doctor warns about missing linger"
assert_line "$out" '^\[warn\] on battery at 15%; HomeLab mode will drain it$' \
  "doctor warns about a battery-powered hold"
"$homelab" off >/dev/null

ok "doctor checks the full mode contract"
