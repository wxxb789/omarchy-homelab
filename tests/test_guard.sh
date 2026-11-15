#!/bin/bash
# Safety guard: critical battery and high temperature turn the mode off.

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

new_sandbox

homelab="$repo_dir/bin/homelab"
state_dir="$XDG_STATE_HOME/homelab"
flag="$state_dir/enabled"
notify_log="$FAKE_LOG_DIR/notify-send.log"

set_lid open
export WAYLAND_DISPLAY=wayland-test

# Critical battery on AC-less power turns the mode off.
set_ac no
set_battery 5 Discharging
set_temperature 55
"$homelab" on >/dev/null
"$homelab" guard-check
assert_no_file "$flag" "the guard turns off on critical battery"
assert_contains "$notify_log" 'HomeLab guard' \
  "the guard sends a notification"
assert_contains "$notify_log" 'battery at 5%' \
  "the guard notification names the battery"

# High temperature turns the mode off even on AC.
set_ac yes
set_battery 80 "Not charging"
set_temperature 96
"$homelab" on >/dev/null
"$homelab" guard-check
assert_no_file "$flag" "the guard turns off on high temperature"
assert_contains "$notify_log" 'temperature at 96C' \
  "the guard notification names the temperature"

# Safe power and temperature leave the mode running.
set_ac no
set_battery 50 Discharging
set_temperature 60
"$homelab" on >/dev/null
"$homelab" guard-check
assert_file "$flag" "the guard leaves a safe mode running"
"$homelab" off >/dev/null

# Nothing to do when the mode is already off.
"$homelab" guard-check
assert_no_file "$flag" "the guard is a no-op outside HomeLab mode"

ok "the safety guard handles battery, temperature, and safe cases"
