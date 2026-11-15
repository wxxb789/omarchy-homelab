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
  export HOMELAB_POWER_SUPPLY_PATH="$FAKE_STATE/power"
  export HOMELAB_THERMAL_PATH="$FAKE_STATE/thermal"
  export PATH="$test_tmp/bin:$PATH"

  # Deterministic defaults for the knobs the fakes understand.
  export FAKE_LAPTOP=yes
  export FAKE_LINGER=yes
  export FAKE_LOCK=present
  export FAKE_MAINPID=4242
  export FAKE_AC=yes
  export FAKE_MONITOR=${FAKE_MONITOR:-eDP-1}
  unset FAKE_DPMS_ON FAKE_DPMS_OFF FAKE_HYPR

  unset HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY

  mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" \
    "$FAKE_STATE" "$FAKE_LOG_DIR" "$test_tmp/bin" \
    "$FAKE_STATE/power/BAT0" "$FAKE_STATE/thermal/thermal_zone0"

  printf '%s\n' "$FAKE_MONITOR" >"$FAKE_STATE/internal-monitor"
  printf '80\n' >"$FAKE_STATE/power/BAT0/capacity"
  printf 'Discharging\n' >"$FAKE_STATE/power/BAT0/status"
  printf '50000\n' >"$FAKE_STATE/thermal/thermal_zone0/temp"
  reset_fake_monitors
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
now=0
property=""
property_next=0
units=()

for arg in "$@"; do
  case $arg in
    --user|--no-pager|--quiet|--value) ;;
    --now) now=1 ;;
    -p) property_next=1 ;;
    -*) ;;
    *)
      if [[ -z $action ]]; then
        action=$arg
      elif (( property_next )); then
        property=$arg
        property_next=0
      else
        units+=("$arg")
      fi
      ;;
  esac
done

unit_active() { [[ -f $state/$1.active ]]; }
unit_enabled() { [[ -f $state/$1.enabled ]]; }
unit_failed() { [[ -f $state/$1.failed ]]; }

start_unit() {
  local unit=$1

  if [[ -f $FAKE_STATE/fail-start-$unit ]]; then
    : >"$state/$unit.failed"
    return 1
  fi
  : >"$state/$unit.active"
  printf '%s\n' "${FAKE_MAINPID:-4242}" >"$state/$unit.mainpid"
}

stop_unit() {
  local unit=$1

  if [[ -f $FAKE_STATE/fail-stop-$unit ]]; then
    return 1
  fi
  rm -f "$state/$unit.active" "$state/$unit.mainpid"
}

restart_unit() {
  local unit=$1

  stop_unit "$unit" || return 1
  start_unit "$unit"
}

case $action in
  start)
    rc=0
    for unit in "${units[@]}"; do
      if ! start_unit "$unit"; then
        rc=1
      fi
    done
    exit "$rc"
    ;;
  stop)
    rc=0
    for unit in "${units[@]}"; do
      if ! stop_unit "$unit"; then
        rc=1
      fi
    done
    exit "$rc"
    ;;
  restart)
    rc=0
    for unit in "${units[@]}"; do
      if ! restart_unit "$unit"; then
        rc=1
      fi
    done
    exit "$rc"
    ;;
  try-restart)
    rc=0
    for unit in "${units[@]}"; do
      if unit_active "$unit"; then
        if ! restart_unit "$unit"; then
          rc=1
        fi
      fi
    done
    exit "$rc"
    ;;
  enable)
    rc=0
    for unit in "${units[@]}"; do
      : >"$state/$unit.enabled"
      if (( now )) && ! start_unit "$unit"; then
        rc=1
      fi
    done
    exit "$rc"
    ;;
  disable)
    rc=0
    for unit in "${units[@]}"; do
      rm -f "$state/$unit.enabled"
      if (( now )) && ! stop_unit "$unit"; then
        rc=1
      fi
    done
    exit "$rc"
    ;;
  reset-failed)
    for unit in "${units[@]}"; do
      rm -f "$state/$unit.failed"
    done
    exit 0
    ;;
  is-active)
    rc=0
    for unit in "${units[@]}"; do
      if ! unit_active "$unit"; then
        rc=3
      fi
    done
    exit "$rc"
    ;;
  is-enabled)
    rc=0
    for unit in "${units[@]}"; do
      if ! unit_enabled "$unit"; then
        rc=1
      fi
    done
    exit "$rc"
    ;;
  show)
    if [[ $property == MainPID ]]; then
      if (( ${#units[@]} > 0 )) && unit_active "${units[0]}" &&
        [[ -f $state/${units[0]}.mainpid ]]; then
        cat "$state/${units[0]}.mainpid"
      else
        printf '0\n'
      fi
    fi
    exit 0
    ;;
  status)
    unit=${units[0]:-}
    if unit_active "$unit"; then
      printf 'active\n'
      exit 0
    elif unit_failed "$unit"; then
      printf 'failed\n'
      exit 3
    else
      printf 'inactive\n'
      exit 3
    fi
    ;;
  daemon-reload|daemon-reexec)
    exit 0
    ;;
  *)
    printf 'systemctl fake: unsupported action: %s\n' "${action:-<none>}" >&2
    exit 1
    ;;
esac
EOF

  write_fake systemd-inhibit <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'systemd-inhibit %s\n' "$*" >>"$FAKE_LOG_DIR/systemd-inhibit.log"

state="$FAKE_STATE/systemd"
pid_file="$state/homelab-inhibit.service.mainpid"
active_file="$state/homelab-inhibit.service.active"
count_file="$FAKE_STATE/systemd-inhibit-list-count"

pid=0
if [[ -f $active_file && -f $pid_file ]]; then
  pid=$(<"$pid_file")
  [[ $pid =~ ^[1-9][0-9]*$ ]] || pid=0
fi

locked=0
case ${FAKE_LOCK:-present} in
  present) locked=1 ;;
  missing) locked=0 ;;
  delayed:*)
    delay=${FAKE_LOCK#delayed:}
    count=0
    [[ -r $count_file ]] && count=$(<"$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if (( count > delay )); then
      locked=1
    fi
    ;;
  *) locked=0 ;;
esac

if (( pid == 0 )); then
  locked=0
fi

if [[ " $* " != *" --list "* ]]; then
  exit 0
fi

if [[ " $* " == *" --json=short "* || " $* " == *" --json "* ]]; then
  if (( locked )); then
    jq -n --argjson pid "$pid" \
      '[{what:"handle-lid-switch",who:"HomeLab",why:"HomeLab mode: keep the machine running with the lid closed",mode:"block",uid:1000,pid:$pid}]'
  else
    printf '[]\n'
  fi
else
  if (( locked )); then
    printf 'HomeLab 1000 user %s systemd-inhibit handle-lid-switch HomeLab mode: keep the machine running with the lid closed block\n' "$pid"
  fi
fi
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

if [[ ${FAKE_HYPR:-up} == down ]]; then
  exit 1
fi

case ${1:-} in
  monitors)
    cat "$FAKE_STATE/monitors.json"
    ;;
  dispatch)
    shift
    request="$*"
    tmp="$FAKE_STATE/monitors.json.$$"

    if [[ $request == *'action = "off"'* ]]; then
      [[ ${FAKE_DPMS_OFF:-ok} == fail ]] && exit 1
      monitor=""
      if [[ $request =~ monitor\ =\ \"([^\"]+)\" ]]; then
        monitor=${BASH_REMATCH[1]}
      fi
      if [[ -n $monitor ]] &&
        jq -e --arg m "$monitor" 'any(.[]; .name == $m)' \
          "$FAKE_STATE/monitors.json" >/dev/null; then
        jq --arg m "$monitor" \
          'map(if .name == $m then .dpmsStatus = false else . end)' \
          "$FAKE_STATE/monitors.json" >"$tmp"
      else
        jq 'map(.dpmsStatus = false)' "$FAKE_STATE/monitors.json" >"$tmp"
      fi
      mv "$tmp" "$FAKE_STATE/monitors.json"
    elif [[ $request == *'action = "on"'* ]]; then
      [[ ${FAKE_DPMS_ON:-ok} == fail ]] && exit 1
      monitor=""
      if [[ $request =~ monitor\ =\ \"([^\"]+)\" ]]; then
        monitor=${BASH_REMATCH[1]}
      fi
      if [[ -n $monitor ]] &&
        jq -e --arg m "$monitor" 'any(.[]; .name == $m)' \
          "$FAKE_STATE/monitors.json" >/dev/null; then
        jq --arg m "$monitor" \
          'map(if .name == $m then .dpmsStatus = true else . end)' \
          "$FAKE_STATE/monitors.json" >"$tmp"
      else
        jq 'map(.dpmsStatus = true)' "$FAKE_STATE/monitors.json" >"$tmp"
      fi
      mv "$tmp" "$FAKE_STATE/monitors.json"
    fi
    ;;
esac

exit 0
EOF

  write_fake notify-send <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'notify-send %s\n' "$*" >>"$FAKE_LOG_DIR/notify-send.log"
exit 0
EOF

  write_fake omarchy-power-present <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'omarchy-power-present\n' >>"$FAKE_LOG_DIR/power.log"
[[ ${FAKE_AC:-yes} == yes ]]
EOF

  write_fake omarchy-hw-laptop <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'omarchy-hw-laptop\n' >>"$FAKE_LOG_DIR/laptop.log"
[[ ${FAKE_LAPTOP:-yes} == yes ]]
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
if [[ -n ${FAKE_MONITOR:-} ]]; then
  printf '%s\n' "$FAKE_MONITOR"
elif [[ -r $FAKE_STATE/internal-monitor ]]; then
  cat "$FAKE_STATE/internal-monitor"
else
  printf 'eDP-1\n'
fi
EOF

  # Keep the watcher loop fast and deterministic. The product uses sleep for
  # both its 2-second loop and its 0.1-second restore retries; shortening every
  # sleep keeps the whole suite quick. Tests must use wait_for helpers rather
  # than assuming a particular number of ticks.
  write_fake sleep <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'tick\n' >>"$FAKE_LOG_DIR/ticks.log"
"$REAL_SLEEP" "${FAKE_SLEEP_SECONDS:-0.05}"
EOF
}

set_ac() {
  export FAKE_AC=$1
}

set_battery() {
  local percent=$1 status=${2:-Discharging}

  printf '%s\n' "$percent" >"$FAKE_STATE/power/BAT0/capacity"
  printf '%s\n' "$status" >"$FAKE_STATE/power/BAT0/status"
}

set_temperature() {
  local celsius=$1

  printf '%s\n' "$((celsius * 1000))" >"$FAKE_STATE/thermal/thermal_zone0/temp"
}

set_lid() {
  local state=$1

  printf 'state: %s\n' "$state" >"$FAKE_STATE/lid"
  mkdir -p "$FAKE_STATE/acpi-lid/LID0"
  printf 'state:      %s\n' "$state" >"$FAKE_STATE/acpi-lid/LID0/state"
}

fake_monitor_name() {
  if [[ -n ${FAKE_MONITOR:-} ]]; then
    printf '%s\n' "$FAKE_MONITOR"
  elif [[ -r $FAKE_STATE/internal-monitor ]]; then
    cat "$FAKE_STATE/internal-monitor"
  else
    printf 'eDP-1\n'
  fi
}

reset_fake_monitors() {
  local name

  name=$(fake_monitor_name)
  jq -n --arg name "$name" \
    '[{name:$name,disabled:false,dpmsStatus:true}]' \
    >"$FAKE_STATE/monitors.json"
}

set_monitor_name() {
  export FAKE_MONITOR=$1
  printf '%s\n' "$FAKE_MONITOR" >"$FAKE_STATE/internal-monitor"
  reset_fake_monitors
}

set_internal_disabled() {
  local disabled=$1
  local name tmp

  name=$(fake_monitor_name)
  tmp=$(mktemp "$FAKE_STATE/monitors.XXXXXX")
  jq --arg name "$name" --argjson disabled "$disabled" '
    if any(.[]; .name == $name) then
      map(if .name == $name then .disabled = $disabled else . end)
    else
      . + [{name:$name, disabled:$disabled, dpmsStatus:true}]
    end' "$FAKE_STATE/monitors.json" >"$tmp"
  mv "$tmp" "$FAKE_STATE/monitors.json"
}

set_fake_dpms() {
  local dpms=$1
  local name tmp

  name=$(fake_monitor_name)
  tmp=$(mktemp "$FAKE_STATE/monitors.XXXXXX")
  jq --arg name "$name" --argjson dpms "$dpms" '
    if any(.[]; .name == $name) then
      map(if .name == $name then .dpmsStatus = $dpms else . end)
    else
      . + [{name:$name, disabled:false, dpmsStatus:$dpms}]
    end' "$FAKE_STATE/monitors.json" >"$tmp"
  mv "$tmp" "$FAKE_STATE/monitors.json"
}

fake_dpms() {
  local name

  name=$(fake_monitor_name)
  jq -r --arg name "$name" \
    '.[] | select(.name == $name) | .dpmsStatus' \
    "$FAKE_STATE/monitors.json" | head -n 1
}

track_pid() {
  test_pids+=("$1")
}

stop_pid() {
  local pid=$1

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

pid_running() {
  kill -0 "$1" 2>/dev/null
}

pid_not_running() {
  ! pid_running "$1"
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

log_line_number() {
  local file=$1 needle=$2

  [[ -f $file ]] || return 0
  awk -v needle="$needle" 'index($0, needle) { print NR; exit }' "$file"
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

assert_before() {
  local file=$1 first=$2 second=$3 message=$4
  local first_line second_line

  first_line=$(log_line_number "$file" "$first")
  second_line=$(log_line_number "$file" "$second")

  [[ -n $first_line ]] || fail "$message (missing '$first' in $file)"
  [[ -n $second_line ]] || fail "$message (missing '$second' in $file)"
  (( first_line < second_line )) ||
    fail "$message ('$first' at line $first_line, '$second' at line $second_line)"
  ok "$message"
}

assert_eq() {
  local actual=$1 expected=$2 message=$3

  [[ $actual == "$expected" ]] ||
    fail "$message (expected '$expected', got '$actual')"
  ok "$message"
}

assert_dpms() {
  local expected=$1 message=$2
  local actual

  actual=$(fake_dpms)
  assert_eq "$actual" "$expected" "$message"
}
