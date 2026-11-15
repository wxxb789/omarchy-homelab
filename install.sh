#!/bin/bash
# Install the HomeLab mode helpers for the current user.
#
# The checkout stays the source of truth: the commands and units are symlinked
# into ~/.local/bin and ~/.config/systemd/user, so editing this repository
# changes what the machine runs.

set -eu

if [[ -z ${HOME:-} || $HOME != /* || $HOME == / ]]; then
  echo "error: HOME must be an absolute path under /." >&2
  exit 1
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bin_dir="$HOME/.local/bin"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/homelab"
plugin_id="io.github.wxxb789.homelab"
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--uninstall]

Installs symlinks from this checkout into:
  $bin_dir
  $unit_dir

and enables the two systemd user units. Laptop mode stays the default; run
"homelab on" when you want the machine to keep running with the lid closed.

It also installs and enables an Omarchy bar widget under:
  $plugin_dir

  --uninstall   Stop and disable the units, remove the symlinks and bar widget,
                and return to Laptop mode. This checkout is left untouched.
EOF
}

require() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "error: $cmd not found. This expects an Omarchy session." >&2
      exit 1
    fi
  done
}

link() {
  local src="$1" dst="$2"

  mkdir -p "$(dirname "$dst")"

  if [[ -e $dst && ! -L $dst ]]; then
    if cmp -s "$src" "$dst"; then
      rm -f "$dst"
    else
      mv "$dst" "$dst.bak.$(date +%s)"
    fi
  fi

  ln -sfn "$src" "$dst"
}

remove_link() {
  local dst="$1"
  if [[ -L $dst && $(readlink -f -- "$dst") == "$repo_dir"/* ]]; then
    rm -f -- "$dst"
  fi
}

install_plugin() {
  local omarchy_bin source_dir target_dir
  omarchy_bin=$(command -v omarchy 2>/dev/null || true)
  if [[ -z $omarchy_bin ]]; then
    echo "warning: omarchy CLI not found; skipping the bar widget." >&2
    return 0
  fi

  source_dir=$(cd -- "$repo_dir" && pwd)
  target_dir=""
  if [[ -d $plugin_dir ]]; then
    target_dir=$(cd -- "$plugin_dir" && pwd) || target_dir=""
  fi

  if [[ $source_dir != "$target_dir" ]]; then
    if ! mkdir -p "$plugin_dir/plugin" ||
      ! cp -f "$repo_dir/manifest.json" "$plugin_dir/manifest.json" ||
      ! cp -f "$repo_dir/plugin/BarWidget.qml" "$plugin_dir/plugin/BarWidget.qml"; then
      echo "warning: could not install the bar widget into $plugin_dir." >&2
      return 0
    fi
  fi

  # The running shell only learns about a new directory after a rescan, and
  # the rescan finishes asynchronously. Retry briefly: the first enable can
  # still answer "unknown" while the registry is catching up.
  local attempt=0
  while (( attempt < 5 )); do
    attempt=$((attempt + 1))
    "$omarchy_bin" shell shell rescanPlugins >/dev/null 2>&1 || true
    "$omarchy_bin" plugin enable "$plugin_id" --section right >/dev/null 2>&1 || true
    if "$omarchy_bin" plugin list --json 2>/dev/null |
      jq -e --arg id "$plugin_id" 'any(.[]; .id == $id and .enabled == true)' >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done

  if ! "$omarchy_bin" plugin list --json 2>/dev/null |
    jq -e --arg id "$plugin_id" 'any(.[]; .id == $id and .enabled == true)' >/dev/null 2>&1; then
    echo "warning: the bar widget is installed but not enabled." >&2
    echo "         Run: omarchy-shell shell rescanPlugins" >&2
    echo "              omarchy plugin enable $plugin_id --section right" >&2
  fi
}

refuse_root() {
  if (( ${EUID:-$(id -u)} == 0 )); then
    echo "error: run install.sh as your desktop user, not with sudo or as root." >&2
    exit 1
  fi
}

uninstall() {
  refuse_root
  # Stop the watcher first: its ExecStopPost restores DPMS while Hyprland is
  # still alive. Then release the inhibitor, which may suspend a closed lid.
  timeout 30 systemctl --user disable --now homelab-lid.service >/dev/null 2>&1 || true

  if [[ -f $state_dir/lid-blanked ]]; then
    "$bin_dir/homelab-lid-watch" --restore >/dev/null 2>&1 || true
  fi

  if omarchy-hw-laptop-closed >/dev/null 2>&1; then
    echo "warning: the lid is closed; releasing the inhibitor may suspend the machine." >&2
  fi
  timeout 30 systemctl --user disable --now homelab-inhibit.service >/dev/null 2>&1 || true

  if command -v omarchy >/dev/null 2>&1; then
    omarchy plugin remove "$plugin_id" --yes >/dev/null 2>&1 || true
  fi
  case "$plugin_dir" in
    "$HOME"/.config/omarchy/plugins/*) rm -rf -- "$plugin_dir" ;;
    *)
      echo "warning: refusing to remove unexpected plugin path: $plugin_dir" >&2
      ;;
  esac

  remove_link "$bin_dir/homelab"
  remove_link "$bin_dir/homelab-lid-watch"
  remove_link "$unit_dir/homelab-lid.service"
  remove_link "$unit_dir/homelab-inhibit.service"
  rm -f "$state_dir/enabled" "$state_dir/lid-blanked" "$state_dir/lock"

  timeout 20 systemctl --user daemon-reload

  echo "HomeLab mode helpers removed. Laptop mode is active."
  echo "The checkout at $repo_dir was not touched."
}

case "${1:-install}" in
  --uninstall|uninstall)
    uninstall
    exit 0
    ;;
  --help|-h|help)
    usage
    exit 0
    ;;
  install|"") ;;
  *)
    usage >&2
    exit 1
    ;;
esac

refuse_root
require hyprctl jq systemctl systemd-inhibit loginctl flock timeout omarchy-hw-laptop omarchy-hw-laptop-closed omarchy-hyprland-monitor-laptop

chmod +x "$repo_dir/bin/homelab" "$repo_dir/bin/homelab-lid-watch"

link "$repo_dir/bin/homelab" "$bin_dir/homelab"
link "$repo_dir/bin/homelab-lid-watch" "$bin_dir/homelab-lid-watch"
link "$repo_dir/systemd/user/homelab-inhibit.service" "$unit_dir/homelab-inhibit.service"
link "$repo_dir/systemd/user/homelab-lid.service" "$unit_dir/homelab-lid.service"

mkdir -p "$state_dir"

timeout 20 systemctl --user daemon-reload
if ! timeout 20 systemctl --user enable homelab-inhibit.service homelab-lid.service; then
  echo "warning: could not enable the HomeLab user units." >&2
fi
timeout 20 systemctl --user reset-failed homelab-lid.service homelab-inhibit.service >/dev/null 2>&1 || true
if [[ -f $state_dir/enabled ]]; then
  if ! timeout 20 systemctl --user start homelab-lid.service; then
    echo "warning: HomeLab is on, but the lid watcher did not start." >&2
  fi
fi

# A lingering user manager is what lets the inhibitor start at boot, before
# anyone logs in. It is already enabled on most Omarchy installs.
user_name=$(id -un)
linger=$(timeout 5 loginctl show-user "$user_name" -p Linger --value 2>/dev/null || true)
if [[ $linger != yes ]]; then
  if timeout 10 loginctl --no-ask-password enable-linger "$user_name" >/dev/null 2>&1; then
    echo "Enabled systemd lingering for $user_name (HomeLab mode survives reboot)."
  else
    echo "warning: could not enable lingering for $user_name." >&2
    echo "         HomeLab mode will start at boot only after you log in." >&2
  fi
fi

install_plugin

echo
echo "Installed. Laptop mode is the default."
"$bin_dir/homelab" status || true
echo
echo "Switch with: homelab on    (HomeLab mode)"
echo "             homelab off   (Laptop mode)"
echo "             homelab status"
echo "Or click the HomeLab icon in the bar."
