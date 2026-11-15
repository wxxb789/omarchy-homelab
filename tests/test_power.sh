#!/bin/bash
# Power and thermal visibility: warnings on battery and high temperature, and
# the same values in status --json.

set -euo pipefail
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

new_sandbox

homelab="$repo_dir/bin/homelab"

set_lid open
set_ac no
set_battery 15 Discharging
set_temperature 95

out=$("$homelab" on 2>&1)
assert_line "$out" '^warning: no AC power' \
  "homelab on warns when running on battery"
assert_line "$out" '^warning: battery is at 15%' \
  "homelab on warns about a low battery"
assert_line "$out" '^warning: CPU temperature is 95C' \
  "homelab on warns about a hot CPU"

status=$("$homelab" status)
assert_line "$status" '^Power:[[:space:]]+battery, 15%, Discharging, 95C$' \
  "status reports AC, battery, and temperature"
assert_line "$status" '^~ on battery at 15%; HomeLab mode will drain it$' \
  "status repeats the battery warning"
assert_line "$status" '^~ on battery without a deadline; prefer homelab on --for$' \
  "status asks for a deadline on battery"
assert_line "$status" '^~ CPU temperature is 95C; check ventilation$' \
  "status repeats the thermal warning"

json=$("$homelab" status --json)
jq -e '
  .power.ac == false
  and .power.batteryPercent == 15
  and .power.batteryStatus == "Discharging"
  and .power.temperatureC == 95
' <<<"$json" >/dev/null || fail "status --json should report power and temperature"

"$homelab" off >/dev/null

# AC power and normal temperature are reported without warnings.
set_ac yes
set_battery 80 "Not charging"
set_temperature 60
"$homelab" on >/dev/null
status=$("$homelab" status)
assert_line "$status" '^Power:[[:space:]]+AC, 80%, Not charging, 60C$' \
  "status reports AC power and battery state"
assert_not_contains "$status" '^~ on battery' \
  "AC power does not trigger the battery warning"
assert_not_contains "$status" '^~ CPU temperature' \
  "a normal temperature does not trigger the thermal warning"
"$homelab" off >/dev/null

ok "power and thermal state is reported and warned about"
