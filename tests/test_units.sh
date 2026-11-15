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
deadline="$repo_dir/systemd/user/homelab-deadline.service"
guard="$repo_dir/systemd/user/homelab-guard.service"
guard_timer="$repo_dir/systemd/user/homelab-guard.timer"

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

assert_contains "$deadline" 'ConditionPathExists=%S/homelab/enabled' \
  "the deadline service requires the mode flag"
assert_contains "$deadline" 'ConditionPathExists=%S/homelab/deadline' \
  "the deadline service requires a deadline"
assert_contains "$deadline" 'ExecStart=%h/.local/bin/homelab-deadline' \
  "the deadline service launches the installed helper"
assert_contains "$deadline" 'Restart=no' \
  "the deadline service does not restart after firing"
assert_contains "$deadline" 'WantedBy=default.target' \
  "the deadline service is enabled at boot"
assert_contains "$deadline" 'StateDirectory=homelab' \
  "the deadline service owns the private state directory"
assert_contains "$deadline" 'ReadWritePaths=%S/homelab' \
  "the deadline service may write the state directory"
assert_contains "$deadline" 'TimeoutStopSec=5' \
  "the deadline service has a bounded stop timeout"

assert_contains "$guard" 'ConditionPathExists=%S/homelab/enabled' \
  "the guard runs only in HomeLab mode"
assert_contains "$guard" 'ExecStart=%h/.local/bin/homelab guard-check' \
  "the guard runs the CLI check"
assert_contains "$guard" 'Type=oneshot' \
  "the guard is a one-shot service"
assert_contains "$guard" 'StateDirectory=homelab' \
  "the guard owns the private state directory"
assert_contains "$guard" 'ReadWritePaths=%S/homelab' \
  "the guard may write the state directory"
assert_contains "$guard_timer" 'ConditionPathExists=%S/homelab/enabled' \
  "the guard timer runs only in HomeLab mode"
assert_contains "$guard_timer" 'OnBootSec=1min' \
  "the guard runs after boot"
assert_contains "$guard_timer" 'OnUnitActiveSec=1min' \
  "the guard runs every minute"
assert_contains "$guard_timer" 'WantedBy=timers.target' \
  "the guard timer is enabled with timers.target"
