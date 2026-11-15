#!/bin/bash
# Install the HomeLab mode helpers for the current user.
#
# The checkout stays the source of truth: the commands and units are symlinked
# into ~/.local/bin and ~/.config/systemd/user, so editing this repository
# changes what the machine runs.

set -eu

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/homelab"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--uninstall]

Installs symlinks from this checkout into:
  $bin_dir
  $unit_dir

and enables the two systemd user units. Laptop mode stays the default; run
"homelab on" when you want the machine to keep running with the lid closed.

  --uninstall   Stop and disable the units, remove the symlinks, and return to
                Laptop mode. This checkout is left untouched.
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

uninstall() {
  if [[ -f $state_dir/lid-blanked ]]; then
    hyprctl dispatch 'hl.dsp.dpms({ action = "on" })' >/dev/null 2>&1 || true
  fi

  systemctl --user disable --now homelab-lid.service >/dev/null 2>&1 || true
  systemctl --user disable --now homelab-inhibit.service >/dev/null 2>&1 || true

  rm -f "$bin_dir/homelab" "$bin_dir/homelab-lid-watch"
  rm -f "$unit_dir/homelab-lid.service" "$unit_dir/homelab-inhibit.service"
  rm -f "$state_dir/enabled" "$state_dir/lid-blanked"

  systemctl --user daemon-reload

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

require hyprctl jq systemctl loginctl omarchy-hw-laptop-closed omarchy-hyprland-monitor-laptop

chmod +x "$repo_dir/bin/homelab" "$repo_dir/bin/homelab-lid-watch"

link "$repo_dir/bin/homelab" "$bin_dir/homelab"
link "$repo_dir/bin/homelab-lid-watch" "$bin_dir/homelab-lid-watch"
link "$repo_dir/systemd/user/homelab-inhibit.service" "$unit_dir/homelab-inhibit.service"
link "$repo_dir/systemd/user/homelab-lid.service" "$unit_dir/homelab-lid.service"

mkdir -p "$state_dir"

systemctl --user daemon-reload
systemctl --user enable homelab-inhibit.service >/dev/null
systemctl --user enable homelab-lid.service >/dev/null
systemctl --user restart homelab-lid.service >/dev/null 2>&1 || true

# A lingering user manager is what lets the inhibitor start at boot, before
# anyone logs in. It is already enabled on most Omarchy installs.
if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true) != yes ]]; then
  if loginctl enable-linger "$USER" >/dev/null 2>&1; then
    echo "Enabled systemd lingering for $USER (HomeLab mode survives reboot)."
  else
    echo "warning: could not enable lingering for $USER." >&2
    echo "         HomeLab mode will start at boot only after you log in." >&2
  fi
fi

echo
echo "Installed. Laptop mode is the default."
"$bin_dir/homelab" status || true
echo
echo "Switch with: homelab on    (HomeLab mode)"
echo "             homelab off   (Laptop mode)"
echo "             homelab status"
