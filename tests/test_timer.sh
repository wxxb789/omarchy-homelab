#!/bin/bash
# Timed-hold behavior: deadlines are written, reported, enforced, and cleared.

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

new_sandbox

homelab="$repo_dir/bin/homelab"
deadline_helper="$repo_dir/bin/homelab-deadline"
state_dir="$XDG_STATE_HOME/homelab"
flag="$state_dir/enabled"
deadline="$state_dir/deadline"
systemctl_log="$FAKE_LOG_DIR/systemctl.log"

set_lid open

# A timed on writes the deadline and starts the timer service.
out=$("$homelab" on --for 1h)
assert_file "$flag" "a timed on writes the mode flag"
assert_file "$deadline" "a timed on writes the deadline file"
assert_contains "$systemctl_log" 'restart homelab-deadline.service' \
  "a timed on starts the deadline service"
assert_line "$out" '^HomeLab mode on until ' \
  "the mode message includes the deadline"

json=$("$homelab" status --json)
jq -e '
  .deadline != null
  and .deadline.active == true
  and .deadline.remainingSeconds > 3500
  and .deadline.remainingSeconds <= 3600
' <<<"$json" >/dev/null || fail "status --json should report the active deadline"
json=$("$homelab" status --json --strict)
jq -e '.consistent == true' <<<"$json" >/dev/null ||
  fail "a timed on should be consistent"

# A normal off clears the deadline and stops the timer service.
"$homelab" off >/dev/null
assert_no_file "$deadline" "homelab off removes the deadline"
assert_no_file "$flag" "homelab off removes the mode flag"
assert_contains "$systemctl_log" 'stop homelab-deadline.service' \
  "homelab off stops the deadline service"

# Invalid deadlines fail before changing the mode.
if "$homelab" on --for 0 >/dev/null 2>&1; then
  fail "homelab on --for 0 should fail"
fi
if "$homelab" on --until 25:00 >/dev/null 2>&1; then
  fail "homelab on --until 25:00 should fail"
fi
if "$homelab" on --for 1h --until 23:00 >/dev/null 2>&1; then
  fail "homelab on should reject both --for and --until"
fi
assert_no_file "$flag" "an invalid deadline leaves no mode flag"

# Leading-zero durations are decimal, not octal.
"$homelab" on --for 08m >/dev/null
assert_file "$deadline" "a leading-zero duration writes a deadline"
"$homelab" off >/dev/null

# A stale deadline without the mode flag is reported.
mkdir -p "$state_dir"
printf '%s\n' "$(( $(date +%s) + 600 ))" >"$deadline"
systemctl --user start homelab-deadline.service
json=$("$homelab" status --json)
jq -e '
  (.warnings | index("a deadline is set while HomeLab mode is off"))
  and (.warnings | index("the deadline service is active while HomeLab mode is off"))
' <<<"$json" >/dev/null || fail "status should flag a deadline while the mode is off"
ok "status flags a stale deadline while the mode is off"
systemctl --user stop homelab-deadline.service
rm -f "$deadline"

# --until accepts a future wall-clock time.
until_time=$(date -d '+1 minute' +%H:%M)
"$homelab" on --until "$until_time" >/dev/null
assert_file "$deadline" "homelab on --until writes a deadline"
json=$("$homelab" status --json)
jq -e '.deadline != null and .deadline.remainingSeconds > 0' <<<"$json" >/dev/null ||
  fail "an --until deadline should be in the future"
"$homelab" off >/dev/null

# The deadline helper turns the mode off when the epoch has passed.
mkdir -p "$state_dir"
: >"$flag"
printf '%s\n' "$(( $(date +%s) - 1 ))" >"$deadline"
HOMELAB_BIN="$homelab" "$deadline_helper" >/dev/null
assert_no_file "$flag" "the deadline helper clears the mode flag"
assert_no_file "$deadline" "the deadline helper clears the deadline"
assert_no_file "$FAKE_STATE/systemd/homelab-inhibit.service.active" \
  "the deadline helper stops the inhibitor"

# The helper is a no-op when the mode is already off.
HOMELAB_BIN="$homelab" "$deadline_helper" >/dev/null
assert_no_file "$deadline" "the deadline helper is a no-op without a deadline"

ok "timed holds are written, reported, enforced, and cleared"
