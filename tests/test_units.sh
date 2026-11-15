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

# State follows XDG_STATE_HOME, which systemd expands as %S. The mode flag is
# the only condition; there is no Wayland-session environment gate anymore.
assert_contains "$inhibit" 'ConditionPathExists=%S/homelab/enabled' \
  "the inhibitor starts only when the mode flag exists"
assert_contains "$lid" 'ConditionPathExists=%S/homelab/enabled' \
  "the lid watcher starts only when the mode flag exists"
assert_not_contains "$inhibit" 'ConditionEnvironment=' \
  "the inhibitor has no Wayland environment condition"
assert_not_contains "$lid" 'ConditionEnvironment=' \
  "the lid watcher has no Wayland environment condition"
assert_not_contains "$inhibit" '%h/.local/state/homelab/enabled' \
  "the inhibitor does not hard-code the default state path"
assert_not_contains "$lid" '%h/.local/state/homelab/enabled' \
  "the lid watcher does not hard-code the default state path"

# The inhibitor is the guarantee; the watcher merely blanks the panel.
assert_contains "$inhibit" '--what=handle-lid-switch' \
  "the inhibitor covers the lid switch"
assert_contains "$inhibit" '--mode=block' \
  "the inhibitor blocks logind instead of delaying"
assert_contains "$inhibit" 'sleep infinity' \
  "the inhibitor is held for the whole session"
assert_contains "$inhibit" 'Restart=always' \
  "the inhibitor restarts if it exits"
assert_contains "$inhibit" 'TimeoutStopSec=5' \
  "the inhibitor has a bounded stop timeout"
assert_contains "$inhibit" 'StartLimitIntervalSec=30' \
  "the inhibitor has a start rate limit interval"
assert_contains "$inhibit" 'StartLimitBurst=5' \
  "the inhibitor has a start burst limit"
assert_contains "$inhibit" 'WantedBy=default.target' \
  "the inhibitor is enabled at boot"

assert_contains "$lid" 'PartOf=graphical-session.target' \
  "the lid watcher follows the graphical session"
assert_contains "$lid" 'Wants=homelab-inhibit.service' \
  "the lid watcher wants the inhibitor as a companion"
assert_contains "$lid" 'After=graphical-session.target homelab-inhibit.service' \
  "the lid watcher starts after the graphical session and inhibitor"
assert_contains "$lid" 'ExecStart=%h/.local/bin/homelab-lid-watch' \
  "the lid watcher launches the installed helper"
assert_contains "$lid" 'ExecStopPost=-%h/.local/bin/homelab-lid-watch --restore' \
  "stopping the lid watcher restores DPMS"
assert_contains "$lid" 'Restart=on-failure' \
  "the lid watcher restarts only after a failure"
assert_not_contains "$lid" 'Restart=always' \
  "the lid watcher does not spin after a clean exit"
assert_contains "$lid" 'TimeoutStopSec=5' \
  "the lid watcher has a bounded stop timeout"
assert_contains "$lid" 'StartLimitIntervalSec=30' \
  "the lid watcher has a start rate limit interval"
assert_contains "$lid" 'StartLimitBurst=3' \
  "the lid watcher has a start burst limit"
assert_contains "$lid" 'WantedBy=graphical-session.target' \
  "the lid watcher is enabled with the graphical session"
