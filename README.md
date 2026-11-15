# omarchy-homelab

Two power modes for an Omarchy laptop:

| Mode | Lid closed | Lid opened |
| --- | --- | --- |
| **Laptop** (default) | Omarchy locks the session and logind suspends. | Normal use. |
| **HomeLab** | The internal panel blanks and Omarchy's lid handling still runs (a lock on an undocked laptop), but an inhibitor stops logind from suspending. The machine keeps running. | The panel comes back on and the keyboard works as usual. |

HomeLab mode itself does **not** disable the internal output or any input
device. It stops logind from acting on the lid switch, and turns the internal
panel's DPMS off while the lid is shut. Everything keeps running: network,
disks, containers, downloads, SSH, and so on.

## Install

```bash
git clone https://github.com/wxxb789/omarchy-homelab.git ~/repos/omarchy-homelab
cd ~/repos/omarchy-homelab
./install.sh
```

`install.sh` symlinks the commands and units from the checkout into
`~/.local/bin` and `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`, then
enables the user units. It also copies an Omarchy bar widget under
`~/.config/omarchy/plugins` and enables it on the right side of the bar. The
checkout stays the source of truth for the commands and units, so editing those
changes what the machine runs; the widget and manifest are copied, so rerun
`./install.sh` after editing them. Laptop mode remains the default.

Requirements: Omarchy (Hyprland), `jq`, and systemd. No root is needed.

## Usage

```bash
homelab on        # HomeLab mode: keep running when the lid closes
homelab on --for 2h              # ...and turn off after two hours
homelab on --until 23:00         # ...and turn off at 23:00 (tomorrow if past)
homelab off       # Laptop mode: suspend on lid close
homelab toggle    # Switch modes
homelab status    # Show mode, lid, inhibitor, display, power, deadline, boot
homelab status --json --strict  # machine-readable, fail on inconsistency
homelab doctor    # Diagnose dependencies, units, lock, panel, power, state
```

`homelab on` also accepts `homelab` and `server` as the mode name; `homelab off`
also accepts `laptop`.

`homelab status --json` prints a machine-readable snapshot (`schemaVersion: 1`)
with the mode, lid, verified inhibitor lock, watcher, boot state, panel state,
power/battery/temperature, deadline, problems, and warnings. Add `--strict` to
exit 1 when the mode is inconsistent; plain `status` stays useful to humans and
exits 0.

The deadline is stored in the state directory and enforced by a user service,
so a timed hold keeps counting across a reboot when systemd lingering is
enabled. A new `homelab on` without `--for`/`--until` clears any old deadline.

`homelab on` warns when it is running on battery, when the battery is at or
below 20%, and when the CPU is at or above 90°C. `homelab status` shows AC or
battery, charge, charge state, and the hottest thermal zone; `status --json`
exposes the same data under `power`.

## Bar icon

The installer adds a **HomeLab** widget to the Omarchy bar. It shows a dim
laptop in Laptop mode and a lit server rack in HomeLab mode. Left-click
toggles the mode; hover shows what a click will do. While HomeLab is on, it
polls `homelab status --json` and adds the verified lock, deadline, battery,
temperature, and any inconsistency to the tooltip. The widget watches the same
mode flag as the CLI, so `homelab on/off` from a terminal, SSH, or a keybinding
updates the bar immediately.

The widget is also scriptable through Omarchy's shell IPC:

```bash
omarchy-shell io.github.wxxb789.homelab toggle
omarchy-shell io.github.wxxb789.homelab refresh
```

If the icon is missing after an install, see
[Bar icon missing](docs/troubleshooting.md#bar-icon-missing).

## How it works

- **`homelab-inhibit.service`** (user unit, enabled at `default.target`) runs
  `systemd-inhibit --what=handle-lid-switch ... sleep infinity`. While that
  inhibitor is held, logind ignores the lid switch. The unit starts when
  `$XDG_STATE_HOME/homelab/enabled` exists (default
  `~/.local/state/homelab/enabled`). With systemd lingering enabled, it
  starts at boot before login, so a reboot with the lid shut does not suspend
  the machine.
- **`homelab-lid.service`** (user unit, part of `graphical-session.target`) is
  started only while HomeLab mode is on. It polls the lid and sends Hyprland a
  DPMS-off for the internal output (`eDP-1`, `LVDS-1`, etc.). When the lid
  opens, it sends DPMS-on and removes its state flag. Stopping the service
  restores DPMS through `ExecStopPost`, so `homelab off` does not leave the
  panel blanked. Input devices are never touched.
- **`homelab-deadline.service`** (user unit, enabled at `default.target`) sleeps
  until the epoch in `$XDG_STATE_HOME/homelab/deadline`, then calls
  `homelab off`. It is enabled only while a deadline exists; a normal
  `homelab off` stops it and removes the deadline.
- **Omarchy's stock lid handling is left in place.** The compositor's lid-close
  binding still locks the session and applies clamshell handling when an
  external monitor is attached. That is why opening the lid shows the lock
  screen; unlock as usual and everything is there.
- **Both user units run sandboxed:** no new privileges, a read-only home
  except the state directory, no Internet sockets, and a reduced system-call
  surface. The watcher only needs the Hyprland socket and the local system bus.
- **Manual suspend still works.** HomeLab mode only inhibits the lid switch, not
  `sleep`, so choosing Suspend from the power menu still suspends the machine.

## Why not just logind.conf?

`HandleLidSwitch=ignore` in `/etc/systemd/logind.conf` is system-wide, needs
root, and has no toggle, no panel blanking, and no status. HomeLab mode is a
per-user switch: turn it on when the machine must keep running, and
`homelab off` returns the lid to Omarchy's normal suspend behavior without
editing root-owned configuration.

## Safety

HomeLab mode keeps a closed laptop running, with the lid blocking most of its
airflow.

- Put it on a hard, ventilated surface. Do not use it on a bed, cushion, or
  other soft surface.
- Prefer AC power. A closed laptop on battery will drain, and the battery can
  reach critical while you are not looking.
- Use it for timed jobs, not as a permanent server. Prefer
  `homelab on --for 2h` over an open-ended hold, and check the temperature.
- Do not rely on HomeLab mode to keep the machine alive at critical battery;
  logind, UPower, or firmware may suspend, hibernate, or power off.
- Never run it closed in a bag, backpack, or other enclosed space.

## Notes

- A lid close in HomeLab mode still locks the screen on an undocked laptop.
  With an external monitor attached, Omarchy's clamshell path may skip the
  lock. To skip it in every case, rebind `switch:on:Lid Switch` in
  `~/.config/hypr/bindings.lua` to a wrapper that skips
  `omarchy-system-lid-close` when the mode flag exists.
- External monitors keep working. When one is active and the lid is closed,
  Omarchy may disable the internal output; the lid watcher leaves that alone.
  See [External monitor or clamshell](docs/troubleshooting.md#external-monitor-or-clamshell).
- `homelab off` with the lid already closed releases the inhibitor, and logind
  may suspend immediately. Run it with the lid open, or expect an SSH session
  to drop. See [`homelab off` disconnects SSH](docs/troubleshooting.md#homelab-off-disconnects-ssh).
- Boot persistence needs `Linger=yes` for the user (the installer tries to
  enable it). Without lingering, the inhibitor starts after login instead of at
  boot. logind's default `HoldoffTimeoutSec=30s` delays lid handling after
  startup, which gives the lingering user manager time to take the inhibitor.
  See [Closed-lid boot before login](docs/troubleshooting.md#closed-lid-boot-before-login).
- The lid watcher needs a live Hyprland session. With the lid shut and no
  login, the inhibitor keeps the machine running but the panel may stay lit;
  the watcher starts when the graphical session starts. See
  [Panel stays lit or blanked](docs/troubleshooting.md#panel-stays-lit-or-blanked).
- State follows `XDG_STATE_HOME` (default `~/.local/state`). Commands are fixed
  at `~/.local/bin`; the user units follow `XDG_CONFIG_HOME` (default
  `~/.config/systemd/user`); the bar widget is fixed under
  `~/.config/omarchy/plugins`. See [XDG paths](docs/troubleshooting.md#xdg-paths).
- Tested on Omarchy 4.5 with a ThinkPad (internal output `eDP-1`). Some
  ThinkPads lose the internal keyboard after a lid-open without suspend; a
  suspend/resume cycle resets the controller. See
  [ThinkPad keyboard dead after lid open](docs/troubleshooting.md#thinkpad-keyboard-dead-after-lid-open).

## Troubleshooting

Start with `homelab doctor`; it checks dependencies, units, the verified
inhibitor lock, watcher, linger, panel, power, and the state contract. For
missing bar icons, inhibitor failures, panel or DPMS problems, SSH drops on
`homelab off`, closed-lid boots, clamshell setups, and uninstall checks, see
[docs/troubleshooting.md](docs/troubleshooting.md).

## Development

Run the test suite and static checks with:

```bash
make check
```

It covers bash syntax, shellcheck (when installed), systemd unit verification,
the CLI, the lid watcher, and the unit contracts. The harness uses fake
systemd, Hyprland, and Omarchy commands; it does not touch the live session.

## Uninstall

```bash
./install.sh --uninstall
```

Open the lid first: releasing the inhibitor with a closed lid can suspend the
machine immediately. The uninstaller stops and disables the units, removes the
symlinks and the bar widget, clears the mode flag, and returns the machine to
Laptop mode. The checkout is not touched. See
[Uninstall and verify](docs/troubleshooting.md#uninstall-and-verify) for the
verification commands.

## Layout

```
bin/homelab               mode switch and status
bin/homelab-lid-watch     lid watcher / DPMS handling
bin/homelab-deadline      deadline sleep and turn-off helper
manifest.json             Omarchy bar-widget manifest
plugin/BarWidget.qml      bar toggle and mode indicator
systemd/user/             user units
docs/troubleshooting.md   failure modes and fixes
LICENSE                   MIT license
install.sh                symlink + enable helper
```

## License

MIT. See [LICENSE](LICENSE).
