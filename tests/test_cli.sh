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
systemctl_log="$FAKE_LOG_DIR/systemctl.log"
notify_log="$FAKE_LOG_DIR/notify-send.log"

set_lid open

status=$("$homelab" status)
assert_line "$status" '^Mode:[[:space:]]+Laptop$' \
  "status reports Laptop mode by default"
assert_line "$status" '^Lid suspend:[[:space:]]+enabled' \
  "status reports lid suspend enabled by default"
assert_line "$status" '^At boot:[[:space:]]+Laptop \(default\)$' \
  "status reports Laptop as the boot default"

out=$("$homelab" on)
assert_file "$flag" "homelab on writes the mode flag"
assert_contains "$systemctl_log" 'enable --now homelab-lid.service' \
  "homelab on enables and starts the lid watcher"
assert_contains "$systemctl_log" 'enable homelab-inhibit.service' \
  "homelab on enables the inhibitor at boot"
assert_contains "$systemctl_log" 'start homelab-inhibit.service' \
  "homelab on starts the inhibitor"
assert_file "$FAKE_STATE/systemd/homelab-inhibit.service.active" \
  "the inhibitor is active after homelab on"
assert_line "$out" '^HomeLab mode on\.' \
  "homelab on explains the new mode"
assert_contains "$notify_log" 'HomeLab mode' \
  "homelab on sends a desktop notification"

status=$("$homelab" status)
assert_line "$status" '^Mode:[[:space:]]+HomeLab$' \
  "status reports HomeLab mode"
assert_line "$status" '^Lid suspend:[[:space:]]+inhibited' \
  "status reports the lid inhibitor"
assert_line "$status" '^At boot:[[:space:]]+HomeLab \(persistent, linger: yes\)$' \
  "status reports boot persistence and lingering"
assert_line "$status" '^Internal display:[[:space:]]+eDP-1 \(enabled\)$' \
  "status reports the internal display state"

out=$("$homelab" off)
assert_no_file "$flag" "homelab off removes the mode flag"
assert_contains "$systemctl_log" 'stop homelab-inhibit.service' \
  "homelab off stops the inhibitor"
assert_no_file "$FAKE_STATE/systemd/homelab-inhibit.service.active" \
  "the inhibitor is inactive after homelab off"
assert_line "$out" '^HomeLab mode off\. Closing the lid suspends as before\.$' \
  "homelab off explains the restored laptop behavior"

status=$("$homelab" status)
assert_line "$status" '^Mode:[[:space:]]+Laptop$' \
  "status returns to Laptop mode after homelab off"

# A failed inhibitor start must not leave the mode flag behind.
touch "$FAKE_STATE/fail-start-homelab-inhibit.service"
if out=$("$homelab" on 2>&1); then
  fail "homelab on should fail when the inhibitor cannot start"
fi
assert_no_file "$flag" "a failed homelab on leaves no mode flag"
assert_line "$out" 'Could not take the lid inhibitor' \
  "a failed homelab on explains the failure"
rm -f "$FAKE_STATE/fail-start-homelab-inhibit.service"

# install.sh help and argument validation run before any Omarchy requirement.
help=$("$repo_dir/install.sh" --help)
assert_line "$help" '^Usage:' "install.sh --help prints usage"
if "$repo_dir/install.sh" not-a-mode >/dev/null 2>&1; then
  fail "install.sh should reject unknown arguments"
fi
ok "install.sh rejects unknown arguments"
