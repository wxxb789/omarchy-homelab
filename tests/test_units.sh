#!/bin/bash
# Static invariants for the systemd user units. This keeps CI meaningful on
# machines without an Omarchy/Hyprland session and complements
# systemd-analyze verify.

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

new_sandbox

inhibit="$repo_dir/systemd/user/homelab-inhibit.service"
lid="$repo_dir/systemd/user/homelab-lid.service"

assert_contains "$inhibit" 'ConditionPathExists=%h/.local/state/homelab/enabled' \
  "the inhibitor starts only when the mode flag exists"
assert_contains "$inhibit" '--what=handle-lid-switch' \
  "the inhibitor covers the lid switch"
assert_contains "$inhibit" '--mode=block' \
  "the inhibitor blocks logind instead of delaying"
assert_contains "$inhibit" 'sleep infinity' \
  "the inhibitor is held for the whole session"
assert_contains "$inhibit" 'WantedBy=default.target' \
  "the inhibitor is enabled at boot"

assert_contains "$lid" 'PartOf=graphical-session.target' \
  "the lid watcher follows the graphical session"
assert_contains "$lid" 'After=graphical-session.target' \
  "the lid watcher starts after the graphical session"
assert_contains "$lid" 'ConditionEnvironment=WAYLAND_DISPLAY' \
  "the lid watcher only runs in a Wayland session"
assert_contains "$lid" 'ExecStart=%h/.local/bin/homelab-lid-watch' \
  "the lid watcher launches the installed helper"
assert_contains "$lid" 'Restart=always' \
  "the lid watcher restarts if it exits"
assert_contains "$lid" 'WantedBy=graphical-session.target' \
  "the lid watcher is enabled with the graphical session"
