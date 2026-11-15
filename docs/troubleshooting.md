# Troubleshooting

Start with the mode summary:

```bash
homelab status
```

It reports the mode flag, lid state, verified inhibitor lock, lid watcher,
internal display, panel blank state, and boot persistence. Add `--json` for a
machine-readable snapshot; add `--strict` to exit nonzero when the state is
inconsistent.

If the summary is not enough, collect the detailed state:

```bash
systemctl --user status homelab-inhibit.service --no-pager
systemctl --user status homelab-lid.service --no-pager
systemd-inhibit --list
loginctl show-user "$USER" -p Linger
journalctl --user -u homelab-inhibit -n 50 --no-pager
journalctl --user -u homelab-lid -n 50 --no-pager
hyprctl monitors all -j
```

Run `hyprctl` from inside the Hyprland session. On a remote shell it may not
find the compositor socket. Add `sudo` to the `systemd-logind` journal command
if your user cannot read the system journal.

## Bar icon missing

The widget files and the plugin registration are separate. Re-scan, enable,
then restart the shell:

```bash
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.wxxb789.homelab --section right
omarchy restart shell
```

The rescan is asynchronous, so the enable can answer "unknown" on the first
attempt. Running the two commands again is safe.

Check what Omarchy sees:

```bash
omarchy plugin list --json |
  jq '.[] | select(.id == "io.github.wxxb789.homelab")'
```

The result should show `"enabled": true`. Check that the files exist:

```bash
ls -l ~/.config/omarchy/plugins/io.github.wxxb789.homelab/manifest.json \
      ~/.config/omarchy/plugins/io.github.wxxb789.homelab/plugin/BarWidget.qml
```

If they are missing, rerun `./install.sh` as your desktop user. The plugin
directory is fixed at `~/.config/omarchy/plugins`, even when
`XDG_CONFIG_HOME` is set elsewhere.

## Widget says the CLI is not installed

The tooltip `HomeLab: CLI not installed — run install.sh` means the widget
could not execute `~/.local/bin/homelab`. That path is fixed in the QML and is
not read from `PATH`.

Install or repair the links:

```bash
cd ~/repos/omarchy-homelab
./install.sh
```

Or check the links directly:

```bash
ls -l ~/.local/bin/homelab ~/.local/bin/homelab-lid-watch
test -x ~/.local/bin/homelab && echo "homelab is executable"
```

The widget probes the CLI once when it loads. After installing while the
shell is running, reload it:

```bash
omarchy restart shell
```

The `omarchy-shell io.github.wxxb789.homelab refresh` IPC reloads the mode flag,
re-probes the CLI, and refreshes the status tooltip. If the terminal finds
`homelab` but the widget does not, the command is coming from another directory
in `PATH`; rerun `./install.sh` as the same user that owns the desktop session.

## Mode says on but the lid still suspends

Confirm both the unit and the actual logind lock:

```bash
homelab status
systemctl --user status homelab-inhibit.service --no-pager
systemd-inhibit --list
loginctl show-user "$USER" -p Linger
journalctl --user -u homelab-inhibit -n 50 --no-pager
journalctl -b -u systemd-logind -n 50 --no-pager
```

Expected state:

- `homelab status` reports `Mode: HomeLab`, `Lid suspend: inhibited (lock
  verified)`, and `State: consistent`.
- `homelab-inhibit.service` is `active (running)`.
- `systemd-inhibit --list` has a row whose WHO is `HomeLab`, whose WHAT
  contains `handle-lid-switch`, and whose MODE is `block`.
- The PID in that row matches `MainPID`:

  ```bash
  systemctl --user show -p MainPID --value homelab-inhibit.service
  ```

If `homelab status` reports `State: INCONSISTENT` and a line such as
`! mode flag is set but the lid inhibitor is not active`, re-assert the mode:

```bash
homelab on
```

That resets a failed unit and starts it again. If it still fails, the command
prints the unit status; read the journal lines above. Do not start
`homelab-inhibit.service` by hand while the flag is absent: the unit has
`ConditionPathExists=%S/homelab/enabled`, so systemd skips it with "condition
failed".

If the lock is only missing after a reboot with the lid closed, the user
manager did not start before logind's holdoff expired. Check lingering and the
boot-enabled units:

```bash
loginctl show-user "$USER" -p Linger
systemctl --user is-enabled homelab-inhibit.service
systemctl --user is-enabled homelab-lid.service
```

`Linger=yes` is required for the inhibitor to start before login. Enable it if
your system allows it:

```bash
loginctl enable-linger "$USER"
```

Without lingering, logind may suspend about 30 seconds after boot
(`HoldoffTimeoutSec` default) when the lid is already shut.

If the inhibitor really is listed and the machine still suspends, look at
`systemd-logind` for the lid event and check for a separate hibernate or
power-off action. A held `handle-lid-switch` blocker should prevent logind from
acting on the switch, but it cannot stop a manual suspend or a firmware power
event.

## Panel stays lit or blanked

Check the watcher and the actual monitor state:

```bash
homelab status
systemctl --user status homelab-lid.service --no-pager
journalctl --user -u homelab-lid -n 50 --no-pager
hyprctl monitors all -j
```

With the lid closed and HomeLab mode on, the internal output should still be
present and enabled, with `"dpmsStatus": false`. For example:

```bash
hyprctl monitors all -j |
  jq '.[] | {name, disabled, dpmsStatus}'
```

The internal output is usually `eDP-1`; find the exact name with:

```bash
omarchy-hyprland-monitor-laptop
```

If `disabled` is `true`, Omarchy's clamshell handling disabled the output.
The watcher deliberately leaves a disabled output alone. See
[External monitor or clamshell](#external-monitor-or-clamshell).

If the watcher is inactive while the mode is on:

```bash
systemctl --user start homelab-lid.service
systemctl --user enable homelab-lid.service
```

`enable` is needed for the watcher to start with the next graphical session;
`start` handles the current one. Also confirm the hard-coded helper exists and
is executable:

```bash
ls -l ~/.local/bin/homelab-lid-watch
```

Common journal messages:

- `Hyprland did not answer` — the watcher cannot reach the compositor. Restart
  the unit from inside the session, or after a Hyprland restart.
- `no safe internal output` — `omarchy-hyprland-monitor-laptop` returned
  nothing usable. Check that command in the same session.
- `blank did not take effect` — Hyprland rejected the DPMS dispatch. Check the
  monitor name and the Hyprland log.
- `restore failed` or `restore did not take effect` — DPMS-on did not stick.

If the panel stays blank after the lid opens or after `homelab off`, restore it
directly:

```bash
~/.local/bin/homelab-lid-watch --restore
systemctl --user stop homelab-lid.service
```

Stopping the unit runs its `ExecStopPost` restore as well. As a last resort,
turn DPMS back on for the internal output (replace `eDP-1` with the name from
`omarchy-hyprland-monitor-laptop`):

```bash
hyprctl dispatch 'hl.dsp.dpms({ action = "on", monitor = "eDP-1" })'
```

Omitting the monitor from that dispatch affects every output.

If the lid is physically open but the watcher still thinks it is closed, the
sensor is stuck. Check it:

```bash
cat /proc/acpi/button/lid/*/state
omarchy-hw-laptop-closed; echo "exit: $?"
```

An exit status of `0` means "closed"; nonzero means "open". A sensor stuck
closed keeps the panel blanked until the next suspend/resume or reboot.

## `homelab off` disconnects SSH

This is expected when the lid is closed. `homelab off` removes the mode flag,
stops the watcher, and releases the lid inhibitor. logind immediately rechecks
the already-closed lid and suspends, which drops the SSH connection before the
command's output reaches you.

Run it with the lid open:

```bash
homelab off
```

Then close the lid if you want the machine to suspend. If you are remote and
want to suspend deliberately, skip the mode switch:

```bash
systemctl suspend
```

If the machine happens to stay awake after the release, suspend it explicitly
with `systemctl suspend`.

There is no supported way to stay in Laptop mode with a closed lid and keep
running; Laptop mode means logind is free to suspend. Use `homelab on` to stay
connected.

## Closed-lid boot before login

With `Linger=yes`, the unit enabled, and the mode flag present,
`homelab-inhibit.service` starts at boot and takes the lid inhibitor before
anyone logs in. The machine keeps running, but panel blanking needs a graphical
session: `homelab-lid.service` is part of `graphical-session.target` and
Hyprland is not running yet. The panel may stay lit at the login screen;
firmware or the display manager may blank it independently.

Verify the boot setup:

```bash
loginctl show-user "$USER" -p Linger
systemctl --user is-enabled homelab-inhibit.service
systemctl --user is-enabled homelab-lid.service
```

If lingering is off, the inhibitor starts only after login. With a closed lid,
logind may suspend after its holdoff (default 30 seconds) before you can log
in. Enable lingering, or log in before the holdoff expires.

After login, the watcher starts from the graphical session if the flag still
exists. If it does not, start it once:

```bash
systemctl --user start homelab-lid.service
```

## External monitor or clamshell

When an external monitor is active and the lid closes, Omarchy may treat the
machine as clamshell: it can disable the internal output and may skip the lock
screen. The watcher sees the disabled output and leaves it alone. The external
monitor keeps working, and this is not a failure.

Inspect the setup:

```bash
homelab status
hyprctl monitors all -j |
  jq '.[] | {name, disabled, dpmsStatus}'
```

`Internal display: eDP-1 (disabled)` with an external monitor attached is the
clamshell path, not a blanking failure. The watcher does not force an output
back on. Open the lid to return to the normal layout; if the internal output
stays disabled after the lid is open, use Omarchy's monitor handling to
re-enable it.

## ThinkPad keyboard dead after lid open

Some ThinkPads lose the internal keyboard after a lid-open without a suspend.
This is a firmware/EC and `i8042` controller quirk, not something HomeLab
touches: the watcher never disables or resets input devices.

A suspend/resume cycle resets the controller:

```bash
systemctl suspend
```

Resume and the keyboard normally works again. A reboot also clears it. If the
keyboard is already dead, use an external USB keyboard or the power button. If
the same thing happens in Laptop mode with HomeLab disabled, it is not caused
by this project.

## XDG paths

State follows `XDG_STATE_HOME`:

```bash
echo "${XDG_STATE_HOME:-$HOME/.local/state}/homelab"
```

The mode flag, blanked-panel marker, and lock live there. The user units use
systemd's `%S` state root, which is the same directory when the user manager
sees the same `XDG_STATE_HOME`.

The systemd user units follow `XDG_CONFIG_HOME` at install time:

```bash
echo "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
```

The command symlinks and the plugin do **not** follow XDG overrides:

```text
~/.local/bin/homelab
~/.local/bin/homelab-lid-watch
~/.config/omarchy/plugins/io.github.wxxb789.homelab
```

`XDG_BIN_HOME` is not used. The unit files hard-code
`%h/.local/bin/homelab-lid-watch`, and the widget hard-codes
`$HOME/.local/bin/homelab`.

If you set `XDG_STATE_HOME` only in an interactive shell, the CLI and the
units can disagree. Check what the user manager has:

```bash
systemctl --user show-environment | grep '^XDG_STATE_HOME='
```

Set it for the user manager as well, or unset it so both sides use
`~/.local/state`. If you change `XDG_CONFIG_HOME` after installing, rerun
`./install.sh` so the units land in the new directory, and remove the old unit
symlinks; otherwise the old copies can linger. Run `./install.sh --uninstall`
with the same `XDG_CONFIG_HOME` and `XDG_STATE_HOME` values you installed with.

## Uninstall and verify

Open the lid first. Releasing the inhibitor with a closed lid can suspend the
machine immediately.

From the checkout:

```bash
./install.sh --uninstall
```

The uninstaller stops and disables both units, restores the panel if it was
blanked, removes the command symlinks and the widget, clears the mode flags,
and reloads systemd. Verify:

```bash
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/homelab"

test ! -e ~/.local/bin/homelab && echo "CLI removed"
test ! -e ~/.local/bin/homelab-lid-watch && echo "watcher removed"
test ! -e "$unit_dir/homelab-inhibit.service" && echo "inhibit unit removed"
test ! -e "$unit_dir/homelab-lid.service" && echo "lid unit removed"
test ! -d ~/.config/omarchy/plugins/io.github.wxxb789.homelab && echo "widget removed"
systemctl --user list-unit-files 'homelab-*'
systemd-inhibit --list | grep -F HomeLab
```

The last two commands should show no HomeLab units or inhibitors. The state
directory remains but should be empty:

```bash
ls -A "$state_dir"
```

The installer enables systemd lingering, and the uninstaller does not turn it
back off. Check and disable it if you do not need it:

```bash
loginctl show-user "$USER" -p Linger
loginctl disable-linger "$USER"
```

If the bar icon remains, restart the shell:

```bash
omarchy restart shell
```

If `homelab` still resolves after uninstall, another copy is earlier in
`PATH`:

```bash
type -a homelab
```
