#!/bin/bash
# Exercise the real lid-watcher loop against fake Hyprland/Omarchy commands.
# The fake sleep shortens each tick, so the whole test stays well under the
# 15 second limit while still running the actual loop.

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

new_sandbox

export HYPRLAND_INSTANCE_SIGNATURE=test-instance

watcher="$repo_dir/bin/homelab-lid-watch"
state_dir="$XDG_STATE_HOME/homelab"
flag="$state_dir/enabled"
blanked="$state_dir/lid-blanked"
hypr_log="$FAKE_LOG_DIR/hyprctl.log"
tick_log="$FAKE_LOG_DIR/ticks.log"

set_lid closed
# Make the Omarchy helper disagree: the watcher must prefer the ACPI path
# supplied through OMARCHY_ACPI_LID_PATH.
printf 'state: open\n' >"$FAKE_STATE/lid"

timeout 15 "$watcher" >"$FAKE_LOG_DIR/watcher.out" 2>"$FAKE_LOG_DIR/watcher.err" &
watcher_pid=$!
track_pid "$watcher_pid"

# Laptop mode: closing the lid must not touch DPMS.
wait_for_count "$tick_log" tick 2
assert_count "$hypr_log" 'action = "off"' 0 \
  "Laptop mode with the lid closed makes no DPMS off calls"
assert_count "$hypr_log" 'dispatch' 0 \
  "Laptop mode with the lid closed makes no Hyprland dispatch calls"
assert_no_file "$blanked" "Laptop mode with the lid closed creates no blanked flag"

# HomeLab mode: closing the lid blanks the internal panel.
: >"$flag"
wait_for "the blanked flag" file_present "$blanked"
assert_contains "$hypr_log" 'action = "off"' \
  "HomeLab mode with the lid closed sends DPMS off"
assert_contains "$hypr_log" 'monitor = "eDP-1"' \
  "the DPMS call targets the internal output"

# Opening the lid restores the panel and clears the flag.
set_lid open
wait_for_count "$hypr_log" 'action = "on"' 1
wait_for "the blanked flag to be removed" file_absent "$blanked"
assert_contains "$hypr_log" 'action = "on"' \
  "opening the lid sends DPMS on"

# Clamshell/external-monitor case: the internal output is already disabled,
# so the watcher must leave it alone and not create a blanked flag.
set_internal_disabled true
off_before=$(count_matches "$hypr_log" 'action = "off"')
monitors_before=$(count_matches "$hypr_log" 'monitors all -j')
ticks_before=$(count_matches "$tick_log" tick)
set_lid closed

wait_for_count "$tick_log" tick $((ticks_before + 2))
assert_count "$hypr_log" 'action = "off"' "$off_before" \
  "a disabled internal output is not blanked in clamshell mode"
assert_no_file "$blanked" "clamshell mode creates no blanked flag"
(( $(count_matches "$hypr_log" 'monitors all -j') > monitors_before )) ||
  fail "the watcher did not inspect monitor state in clamshell mode"
ok "the watcher inspected monitor state before skipping the disabled output"

kill "$watcher_pid" 2>/dev/null || true
wait "$watcher_pid" 2>/dev/null || true
