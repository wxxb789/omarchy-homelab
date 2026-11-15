#!/bin/bash
# CLI invariants for bin/homelab with fake systemd, logind, Hyprland and
# Omarchy helpers. Nothing here talks to the real session.

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

new_sandbox

export HYPRLAND_INSTANCE_SIGNATURE=test-instance
export WAYLAND_DISPLAY=wayland-test

homelab="$repo_dir/bin/homelab"
state_dir="$XDG_STATE_HOME/homelab"
flag="$state_dir/enabled"
blanked="$state_dir/lid-blanked"
unit_state="$FAKE_STATE/systemd"
systemctl_log="$FAKE_LOG_DIR/systemctl.log"
hypr_log="$FAKE_LOG_DIR/hyprctl.log"
inhibit_log="$FAKE_LOG_DIR/systemd-inhibit.log"
notify_log="$FAKE_LOG_DIR/notify-send.log"

set_lid open

status=$("$homelab" status)
assert_line "$status" '^Mode:[[:space:]]+Laptop$' \
  "status reports Laptop mode by default"
assert_line "$status" '^Lid suspend:[[:space:]]+enabled' \
  "status reports lid suspend enabled by default"
assert_line "$status" '^Lid watcher:[[:space:]]+inactive$' \
  "status reports the lid watcher inactive by default"
assert_line "$status" '^At boot:[[:space:]]+Laptop \(default\)$' \
  "status reports Laptop as the boot default"

# Successful enable: the inhibitor must be up and actually held before the
# watcher starts. The product verifies the lock with systemd-inhibit.
out=$("$homelab" on 2>&1)
assert_file "$flag" "homelab on writes the mode flag"
assert_file "$unit_state/homelab-inhibit.service.active" \
  "the inhibitor is active after homelab on"
assert_file "$unit_state/homelab-lid.service.active" \
  "the lid watcher is active after homelab on"
assert_contains "$systemctl_log" 'start homelab-inhibit.service' \
  "homelab on starts the inhibitor"
assert_contains "$systemctl_log" 'start homelab-lid.service' \
  "homelab on starts the lid watcher"
assert_before "$systemctl_log" 'start homelab-inhibit.service' \
  'start homelab-lid.service' \
  "homelab on starts the inhibitor before the watcher"
assert_contains "$inhibit_log" '--list --json=short --no-pager' \
  "homelab on verifies the held inhibitor lock"
assert_contains "$systemctl_log" \
  'enable homelab-inhibit.service homelab-lid.service' \
  "homelab on enables both units at boot"
assert_line "$out" '^HomeLab mode on\.' \
  "homelab on explains the new mode"
assert_contains "$notify_log" 'HomeLab mode' \
  "homelab on sends a desktop notification"

status=$("$homelab" status)
assert_line "$status" '^Mode:[[:space:]]+HomeLab$' \
  "status reports HomeLab mode"
assert_line "$status" '^Lid suspend:[[:space:]]+inhibited' \
  "status reports the lid inhibitor"
assert_line "$status" '^Lid watcher:[[:space:]]+active$' \
  "status reports the active lid watcher"
assert_line "$status" '^At boot:[[:space:]]+HomeLab \(persistent, linger: yes\)$' \
  "status reports boot persistence and lingering"
assert_line "$status" '^Internal display:[[:space:]]+eDP-1 \(enabled\)$' \
  "status reports the internal display state"

# Disable must stop the watcher first so its ExecStopPost can restore DPMS
# while Hyprland is still alive, then release the inhibitor. Simulate a panel
# the watcher has already blanked.
set_fake_dpms false
printf 'eDP-1\n' >"$blanked"
out=$("$homelab" off 2>&1)
assert_no_file "$flag" "homelab off removes the mode flag"
assert_before "$systemctl_log" 'stop homelab-lid.service' \
  'stop homelab-inhibit.service' \
  "homelab off stops the watcher before the inhibitor"
assert_no_file "$blanked" "homelab off restores a blanked panel"
assert_dpms true "homelab off turns the internal panel back on"
assert_contains "$hypr_log" 'action = "on"' \
  "homelab off restores DPMS through the watcher"
assert_no_file "$unit_state/homelab-inhibit.service.active" \
  "the inhibitor is inactive after homelab off"
assert_no_file "$unit_state/homelab-lid.service.active" \
  "the lid watcher is inactive after homelab off"
assert_line "$out" '^HomeLab mode off\. Closing the lid suspends as before\.$' \
  "homelab off explains the restored laptop behavior"

status=$("$homelab" status)
assert_line "$status" '^Mode:[[:space:]]+Laptop$' \
  "status returns to Laptop mode after homelab off"
assert_line "$status" '^Lid watcher:[[:space:]]+inactive$' \
  "the watcher is reported inactive after homelab off"

# A failed inhibitor start must not leave the mode flag behind.
touch "$FAKE_STATE/fail-start-homelab-inhibit.service"
if out=$("$homelab" on 2>&1); then
  fail "homelab on should fail when the inhibitor cannot start"
fi
assert_no_file "$flag" "a failed homelab on leaves no mode flag"
assert_no_file "$unit_state/homelab-inhibit.service.active" \
  "a failed homelab on stops the inhibitor"
assert_line "$out" 'lid inhibitor did not start' \
  "a failed homelab on explains the failure"
rm -f "$FAKE_STATE/fail-start-homelab-inhibit.service"

# A running inhibitor unit without a held logind lock is not good enough.
# The loop must notice, clean up, and refuse to turn the mode on.
export FAKE_LOCK=missing
if out=$("$homelab" on 2>&1); then
  fail "homelab on should fail when the inhibitor holds no lock"
fi
assert_no_file "$flag" "an unheld inhibitor leaves no mode flag"
assert_no_file "$unit_state/homelab-inhibit.service.active" \
  "an unheld inhibitor is stopped"
assert_no_file "$unit_state/homelab-lid.service.active" \
  "an unheld inhibitor does not leave the watcher running"
assert_line "$out" 'no lid inhibitor is held' \
  "homelab on explains the missing lock"

# The lock can appear shortly after Type=simple reports the unit started.
rm -f "$FAKE_STATE/systemd-inhibit-list-count"
export FAKE_LOCK=delayed:2
out=$("$homelab" on 2>&1)
assert_file "$flag" "homelab on waits for a delayed inhibitor lock"
assert_file "$unit_state/homelab-inhibit.service.active" \
  "the inhibitor is active after a delayed lock"
assert_line "$out" '^HomeLab mode on\.' \
  "the delayed lock still produces a successful message"
"$homelab" off >/dev/null 2>&1
export FAKE_LOCK=present
rm -f "$FAKE_STATE/systemd-inhibit-list-count"

# The inhibitor is the guarantee: a watcher failure is a warning, not a
# reason to give up the mode.
touch "$FAKE_STATE/fail-start-homelab-lid.service"
if ! out=$("$homelab" on 2>&1); then
  fail "homelab on should succeed when only the watcher fails"
fi
assert_file "$flag" "a watcher failure keeps HomeLab mode on"
assert_file "$unit_state/homelab-inhibit.service.active" \
  "a watcher failure keeps the inhibitor active"
assert_no_file "$unit_state/homelab-lid.service.active" \
  "a watcher failure leaves the watcher inactive"
assert_line "$out" 'panel watcher did not start' \
  "a watcher failure prints a warning"
rm -f "$FAKE_STATE/fail-start-homelab-lid.service"
"$homelab" off >/dev/null 2>&1
assert_no_file "$flag" "homelab off cleans up after a watcher failure"

# Status is a health check: flag set with no inhibitor is an error.
: >"$flag"
if out=$("$homelab" status 2>&1); then
  fail "status should exit 1 when the mode flag is set and the inhibitor is inactive"
fi
assert_line "$out" \
  '^Health:[[:space:]]+inconsistent: mode flag set, inhibitor inactive$' \
  "status reports a flag without an inhibitor"
assert_line "$out" '^Lid watcher:[[:space:]]+inactive$' \
  "status reports the missing watcher in the inconsistent state"
rm -f "$flag"

# The same health check catches the opposite mismatch.
systemctl --user start homelab-inhibit.service
if out=$("$homelab" status 2>&1); then
  fail "status should exit 1 when the inhibitor is active without the mode flag"
fi
assert_line "$out" \
  '^Health:[[:space:]]+inconsistent: inhibitor active, mode flag absent$' \
  "status reports an inhibitor without a mode flag"
systemctl --user stop homelab-inhibit.service

# Only enabling HomeLab mode needs laptop hardware. Turning it off must keep
# working even if Omarchy no longer reports a laptop lid.
export FAKE_LAPTOP=no
if out=$("$homelab" on 2>&1); then
  fail "homelab on should require laptop hardware"
fi
assert_line "$out" 'no laptop lid detected' \
  "homelab on explains the missing laptop lid"
assert_no_file "$flag" "a non-laptop homelab on leaves no mode flag"

export FAKE_LAPTOP=yes
"$homelab" on >/dev/null 2>&1
export FAKE_LAPTOP=no
out=$("$homelab" off 2>&1)
assert_no_file "$flag" "homelab off works without laptop detection"
assert_no_file "$unit_state/homelab-inhibit.service.active" \
  "homelab off releases the inhibitor without laptop detection"
assert_line "$out" '^HomeLab mode off\.' \
  "homelab off succeeds on a machine that no longer looks like a laptop"
export FAKE_LAPTOP=yes

# Concurrent mode changes are serialized with flock.
mkdir -p "$state_dir"
rm -f "$FAKE_STATE/lock-held"
(
  exec 9>"$state_dir/lock"
  flock -n 9 || exit 1
  : >"$FAKE_STATE/lock-held"
  "$REAL_SLEEP" 0.3
) &
locker_pid=$!
track_pid "$locker_pid"
wait_for "the lock holder" file_present "$FAKE_STATE/lock-held"
if out=$("$homelab" toggle 2>&1); then
  fail "toggle should fail while another mode change holds the lock"
fi
assert_line "$out" 'another mode change is already running' \
  "a concurrent toggle is refused"
assert_no_file "$flag" "a refused toggle leaves the mode unchanged"
wait "$locker_pid" 2>/dev/null || true

# install.sh help and argument validation run before any Omarchy requirement.
help=$("$repo_dir/install.sh" --help)
assert_line "$help" '^Usage:' "install.sh --help prints usage"
if "$repo_dir/install.sh" not-a-mode >/dev/null 2>&1; then
  fail "install.sh should reject unknown arguments"
fi
ok "install.sh rejects unknown arguments"
