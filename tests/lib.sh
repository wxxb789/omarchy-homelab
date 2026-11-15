#!/bin/bash
# Shared helpers for the HomeLab test suite.
#
# Each test sources this file and calls new_sandbox. The sandbox redirects
# HOME, XDG_STATE_HOME, XDG_CONFIG_HOME and XDG_RUNTIME_DIR into a temporary
# directory, and puts fake Omarchy/systemd commands ahead of the real PATH.
# Nothing outside the sandbox is read or written.

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export repo_dir

test_tmp=""
declare -a test_pids=()

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '  ok: %s\n' "$*"
}

cleanup() {
  local pid

  for pid in "${test_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  if [[ -n ${test_tmp:-} && -d $test_tmp ]]; then
    rm -rf "$test_tmp"
  fi
}

new_sandbox() {
  test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-homelab-test.XXXXXX")
  trap cleanup EXIT

  REAL_SLEEP=$(command -v sleep)
  export REAL_SLEEP

  FAKE_STATE="$test_tmp/fake"
  FAKE_LOG_DIR="$test_tmp/log"
  export FAKE_STATE FAKE_LOG_DIR

  export HOME="$test_tmp/home"
  export XDG_STATE_HOME="$test_tmp/state"
  export XDG_CONFIG_HOME="$test_tmp/config"
  export XDG_RUNTIME_DIR="$test_tmp/run"
  export OMARCHY_ACPI_LID_PATH="$FAKE_STATE/acpi-lid"
  export PATH="$test_tmp/bin:$PATH"

  unset HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY

  mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" \
    "$FAKE_STATE" "$FAKE_LOG_DIR" "$test_tmp/bin"

  printf '[{"name":"eDP-1","disabled":false}]\n' >"$FAKE_STATE/monitors.json"
  set_lid open

  install_fakes
}

write_fake() {
  local name=$1

  cat >"$test_tmp/bin/$name"
  chmod +x "$test_tmp/bin/$name"
}

install_fakes() {
  write_fake systemctl <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"$FAKE_LOG_DIR/systemctl.log"

state="$FAKE_STATE/systemd"
mkdir -p "$state"

action=""
unit=""
now=0
for arg in "$@"; do
  case $arg in
    --user|--no-pager|--quiet) ;;
    --now) now=1 ;;
    -*) ;;
    *)
      if [[ -z $action ]]; then
        action=$arg
      elif [[ -z $unit ]]; then
        unit=$arg
      fi
      ;;
  esac
done

case $action in
  enable)
    touch "$state/$unit.enabled"
    if (( now )); then touch "$state/$unit.active"; fi
    ;;
  disable)
    rm -f "$state/$unit.enabled"
    if (( now )); then rm -f "$state/$unit.active"; fi
    ;;
  start)
    if [[ -f $FAKE_STATE/fail-start-$unit ]]; then exit 1; fi
    touch "$state/$unit.active"
    ;;
  stop)
    rm -f "$state/$unit.active"
    ;;
  restart)
    if [[ -f $FAKE_STATE/fail-start-$unit ]]; then exit 1; fi
    touch "$state/$unit.active"
    ;;
  is-active)
    [[ -f $state/$unit.active ]] && exit 0 || exit 3
    ;;
  is-enabled)
    [[ -f $state/$unit.enabled ]] && exit 0 || exit 1
    ;;
  status)
    if [[ -f $state/$unit.active ]]; then
      printf 'active\n'
    else
      printf 'inactive\n'
      exit 3
    fi
    ;;
  daemon-reload|daemon-reexec) ;;
esac

exit 0
EOF

  write_fake loginctl <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'loginctl %s\n' "$*" >>"$FAKE_LOG_DIR/loginctl.log"

case ${1:-} in
  show-user) printf '%s\n' "${FAKE_LINGER:-yes}" ;;
esac

exit 0
EOF

  write_fake hyprctl <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'hyprctl %s\n' "$*" >>"$FAKE_LOG_DIR/hyprctl.log"

case ${1:-} in
  monitors) cat "$FAKE_STATE/monitors.json" ;;
esac

exit 0
EOF

  write_fake notify-send <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'notify-send %s\n' "$*" >>"$FAKE_LOG_DIR/notify-send.log"
exit 0
EOF

  write_fake omarchy-hw-laptop-closed <<'EOF'
#!/bin/bash
set -euo pipefail
[[ -r $FAKE_STATE/lid ]] || exit 1
[[ $(<"$FAKE_STATE/lid") == *closed* ]] && exit 0
exit 1
EOF

  write_fake omarchy-hyprland-monitor-laptop <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'omarchy-hyprland-monitor-laptop\n' >>"$FAKE_LOG_DIR/monitor.log"
printf 'eDP-1\n'
EOF

  # Keep the watcher loop fast and deterministic. The loop only depends on
  # tick counts, not on wall-clock time, so shortening sleep does not change
  # the behavior under test.
  write_fake sleep <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'tick\n' >>"$FAKE_LOG_DIR/ticks.log"
"$REAL_SLEEP" "${FAKE_SLEEP_SECONDS:-0.05}"
EOF
}

set_lid() {
  local state=$1

  printf 'state: %s\n' "$state" >"$FAKE_STATE/lid"
  mkdir -p "$FAKE_STATE/acpi-lid/LID0"
  printf 'state:      %s\n' "$state" >"$FAKE_STATE/acpi-lid/LID0/state"
}

set_internal_disabled() {
  local disabled=$1

  printf '[{"name":"eDP-1","disabled":%s}]\n' "$disabled" >"$FAKE_STATE/monitors.json"
}

track_pid() {
  test_pids+=("$1")
}

count_matches() {
  local file=$1 needle=$2 count=0

  if [[ -f $file ]]; then
    count=$(grep -Fc -- "$needle" "$file" || true)
  fi
  printf '%s\n' "${count:-0}"
}

file_present() {
  [[ -f $1 ]]
}

file_absent() {
  [[ ! -e $1 ]]
}

count_at_least() {
  (( $(count_matches "$1" "$2") >= $3 ))
}

wait_for() {
  local what=$1
  local deadline=$((SECONDS + 5))

  shift
  until "$@"; do
    (( SECONDS < deadline )) || fail "timed out waiting for $what"
    "$REAL_SLEEP" 0.02
  done
}

wait_for_count() {
  local file=$1 needle=$2 wanted=$3

  wait_for "$wanted occurrence(s) of '$needle'" \
    count_at_least "$file" "$needle" "$wanted"
}

assert_file() {
  local path=$1
  local message=${2:-"file exists: ${path#"$test_tmp"/}"}

  file_present "$path" || fail "$message (missing $path)"
  ok "$message"
}

assert_no_file() {
  local path=$1
  local message=${2:-"file does not exist: ${path#"$test_tmp"/}"}

  file_absent "$path" || fail "$message (found $path)"
  ok "$message"
}

assert_contains() {
  local file=$1 needle=$2
  local message=${3:-"$(basename "$file") contains '$needle'"}

  [[ -f $file ]] || fail "$message (missing file $file)"
  grep -Fq -- "$needle" "$file" || fail "$message (missing '$needle' in $file)"
  ok "$message"
}

assert_not_contains() {
  local file=$1 needle=$2
  local message=${3:-"$(basename "$file") does not contain '$needle'"}

  if [[ -f $file ]] && grep -Fq -- "$needle" "$file"; then
    fail "$message (found '$needle' in $file)"
  fi
  ok "$message"
}

assert_count() {
  local file=$1 needle=$2 expected=$3
  local message=${4:-"$(basename "$file") has $expected occurrence(s) of '$needle'"}
  local actual

  actual=$(count_matches "$file" "$needle")
  [[ $actual -eq $expected ]] ||
    fail "$message (expected $expected, got $actual)"
  ok "$message"
}

assert_line() {
  local text=$1 regex=$2 message=$3

  grep -Eq -- "$regex" <<<"$text" ||
    fail "$message (no line matching /$regex/)"
  ok "$message"
}
