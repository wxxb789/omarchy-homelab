#!/bin/bash
# Exercise the real lid-watcher loop against fake Hyprland/Omarchy commands.
# The fake sleep shortens each tick, so the whole test stays well under the
# 15 second limit while still running the actual loop. The fakes model DPMS
# state changes so the watcher's post-dispatch verification works normally.

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
monitor_log="$FAKE_LOG_DIR/monitor.log"
tick_log="$FAKE_LOG_DIR/ticks.log"
watcher_pid=""

reset_watch_state() {
  rm -f "$flag" "$blanked"
  set_monitor_name eDP-1
  set_lid open
  : >"$hypr_log"
  : >"$monitor_log"
  : >"$tick_log"
}

start_watcher() {
  timeout 15 "$watcher" \
    >"$FAKE_LOG_DIR/watcher.out" 2>"$FAKE_LOG_DIR/watcher.err" &
  watcher_pid=$!
  track_pid "$watcher_pid"
}

stop_watcher() {
  stop_pid "$watcher_pid"
  watcher_pid=""
}

# Laptop mode: a closed lid must not touch DPMS, and the watcher exits rather
# than lingering when the mode flag is absent.
reset_watch_state
set_lid closed
if ! timeout 15 "$watcher" \
  >"$FAKE_LOG_DIR/watcher.out" 2>"$FAKE_LOG_DIR/watcher.err"; then
  fail "the watcher should exit 0 in Laptop mode"
fi
ok "Laptop mode with the lid closed exits cleanly"
assert_count "$hypr_log" 'dispatch' 0 \
  "Laptop mode with the lid closed makes no Hyprland dispatch calls"
assert_count "$hypr_log" 'action = "off"' 0 \
  "Laptop mode with the lid closed makes no DPMS off calls"
assert_no_file "$blanked" \
  "Laptop mode with the lid closed creates no blanked marker"

# HomeLab mode: closing the lid blanks the internal panel and records which
# output it owns.
reset_watch_state
set_lid closed
: >"$flag"
start_watcher
wait_for "the blanked marker" file_present "$blanked"
assert_contains "$blanked" 'eDP-1' \
  "the blanked marker records the internal output"
assert_contains "$hypr_log" 'action = "off"' \
  "HomeLab mode with the lid closed sends DPMS off"
assert_contains "$hypr_log" 'monitor = "eDP-1"' \
  "the DPMS call targets the internal output"
assert_dpms false "the fake monitor reports DPMS off after blanking"

# Opening the lid restores DPMS and removes the marker.
set_lid open
wait_for "the blanked marker to be removed" file_absent "$blanked"
wait_for_count "$hypr_log" 'action = "on"' 1
assert_contains "$hypr_log" 'action = "on"' \
  "opening the lid sends DPMS on"
assert_dpms true "the fake monitor reports DPMS on after restoring"
stop_watcher

# The unit's ExecStopPost calls --restore, which must work from the marker
# alone, even when the mode flag is already gone.
reset_watch_state
set_fake_dpms false
printf 'eDP-1\n' >"$blanked"
if ! "$watcher" --restore; then
  fail "--restore should succeed from a blanked marker"
fi
ok "--restore restores a marker left by a previous watcher"
assert_no_file "$blanked" "--restore removes the blanked marker"
assert_dpms true "--restore turns the internal output back on"
assert_contains "$hypr_log" 'action = "on"' \
  "--restore sends DPMS on for the saved output"

# Clamshell/external-monitor case: the internal output is already disabled,
# so the watcher must leave it alone and not create a marker.
reset_watch_state
set_lid closed
set_internal_disabled true
: >"$flag"
start_watcher
wait_for_count "$hypr_log" 'monitors all -j' 2
assert_count "$hypr_log" 'action = "off"' 0 \
  "a disabled internal output is not blanked in clamshell mode"
assert_no_file "$blanked" "clamshell mode creates no blanked marker"
stop_watcher

# An unsafe output name must never reach Hyprland's Lua dispatch.
reset_watch_state
set_monitor_name 'eDP-1;evil'
set_lid closed
: >"$flag"
start_watcher
wait_for_count "$monitor_log" 'omarchy-hyprland-monitor-laptop' 2
assert_count "$hypr_log" 'dispatch' 0 \
  "an unsafe output name produces no dispatch"
assert_no_file "$blanked" "an unsafe output name creates no blanked marker"
stop_watcher

# A failed DPMS-off dispatch must not leave a marker claiming the panel is
# blanked.
reset_watch_state
set_lid closed
: >"$flag"
export FAKE_DPMS_OFF=fail
start_watcher
wait_for_count "$hypr_log" 'action = "off"' 1
assert_no_file "$blanked" "a failed DPMS-off dispatch writes no marker"
assert_dpms true "a failed DPMS-off dispatch leaves the monitor on"
stop_watcher
unset FAKE_DPMS_OFF

# Removing the mode flag while the watcher is running restores the panel and
# exits cleanly instead of leaving a stray watcher behind.
reset_watch_state
set_lid closed
: >"$flag"
start_watcher
wait_for "the blanked marker" file_present "$blanked"
rm -f "$flag"
wait_for "the watcher to exit" pid_not_running "$watcher_pid"
if wait "$watcher_pid" 2>/dev/null; then
  ok "the watcher exits 0 after the mode flag is removed"
else
  fail "the watcher should exit 0 after the mode flag is removed"
fi
watcher_pid=""
assert_no_file "$blanked" \
  "removing the mode flag restores and clears the blanked marker"
assert_dpms true "removing the mode flag turns the internal panel back on"
assert_contains "$hypr_log" 'action = "on"' \
  "removing the mode flag sends DPMS on"
