# omarchy-homelab

Two power modes for an Omarchy laptop:

| Mode | Lid closed | Lid opened |
| --- | --- | --- |
| **Laptop** (default) | Omarchy locks the session and logind suspends. | Normal use. |
| **HomeLab** | The internal panel blanks and Omarchy's lid handling still runs (a lock on an undocked laptop), but an inhibitor stops logind from suspending. The machine keeps running. | The panel comes back on and the keyboard works as usual. |

HomeLab mode does **not** disable the internal output or any input device. It
stops logind from acting on the lid switch, and turns the internal panel's DPMS
off while the lid is shut. Everything keeps running: network, disks,
containers, downloads, SSH, and so on.

## Install

```bash
git clone https://github.com/wxxb789/omarchy-homelab.git ~/repos/omarchy-homelab
cd ~/repos/omarchy-homelab
./install.sh
```

`install.sh` symlinks the commands and units from the checkout into
`~/.local/bin` and `~/.config/systemd/user`, then enables the user units. It
also installs an Omarchy bar widget under `~/.config/omarchy/plugins` and
enables it on the right side of the bar. The checkout stays the source of
truth for the commands and units, so editing a file here changes what the
machine runs. Laptop mode remains the default.

Requirements: Omarchy (Hyprland), `jq`, and systemd. No root is needed.

## Usage

```bash
homelab on        # HomeLab mode: keep running when the lid closes
homelab off       # Laptop mode: suspend on lid close
homelab toggle    # Switch modes
homelab status    # Show mode, lid state, inhibitor, display, boot persistence
```

`homelab on` also accepts `homelab` and `server` as the mode name; `homelab off`
also accepts `laptop`.

## Bar icon

The installer adds a **HomeLab** widget to the Omarchy bar. It shows a dim
laptop in Laptop mode and a lit server rack in HomeLab mode. Left-click
toggles the mode; hover shows what a click will do. The widget watches the same
mode flag as the CLI, so `homelab on/off` from a terminal, SSH, or a keybinding
updates the bar immediately.

The widget is also scriptable through Omarchy's shell IPC:

```bash
omarchy-shell io.github.wxxb789.homelab toggle
omarchy-shell io.github.wxxb789.homelab refresh
```

If the icon is missing after an install, run `omarchy restart shell` once.

## How it works

- **`homelab-inhibit.service`** (user unit, enabled at `default.target`) runs
  `systemd-inhibit --what=handle-lid-switch ... sleep infinity`. While that
  inhibitor is held, logind ignores the lid switch. The unit starts when
  `~/.local/state/homelab/enabled` exists. With systemd lingering enabled, it
  starts at boot before login, so a reboot with the lid shut does not suspend
  the machine.
- **`homelab-lid.service`** (user unit, part of `graphical-session.target`) is
  started only while HomeLab mode is on. It polls the lid and sends Hyprland a
  DPMS-off for the internal output (`eDP-1`, `LVDS-1`, etc.). When the lid
  opens, it sends DPMS-on and removes its state flag. Stopping the service
  restores DPMS through `ExecStopPost`, so `homelab off` does not leave the
  panel blanked. Input devices are never touched.
- **Omarchy's stock lid handling is left in place.** The compositor's lid-close
  binding still locks the session and applies clamshell handling when an
  external monitor is attached. That is why opening the lid shows the lock
  screen; unlock as usual and everything is there.
- **Manual suspend still works.** HomeLab mode only inhibits the lid switch, not
  `sleep`, so choosing Suspend from the power menu still suspends the machine.

## Notes

- A lid close in HomeLab mode still locks the screen (Omarchy's default). If you
  prefer no lock, rebind `switch:on:Lid Switch` in `~/.config/hypr/bindings.lua`
  to a wrapper that skips `omarchy-system-lid-close` when the mode flag exists.
- External monitors keep working as before. When an external display is active
  and the lid is closed, Omarchy's clamshell logic disables the internal output;
  the lid watcher leaves that alone.
- `homelab off` while the lid is already closed releases the inhibitor, and
  logind rechecks a closed lid immediately: the machine may suspend right away.
  The command warns before it does this. If the machine stays awake, run
  `systemctl suspend` to suspend now.
- Boot persistence needs `Linger=yes` for the user (the installer tries to
  enable it). Without lingering, the inhibitor starts after login instead of at
  boot. logind holds lid events for up to 30 seconds after startup
  (`HoldoffTimeoutSec`), which gives the lingering user manager time to take the
  inhibitor.
- The lid watcher needs a live Hyprland session to blank the panel. With the lid
  shut and no login, the inhibitor keeps the machine running but the panel may
  stay lit; the watcher starts when the graphical session starts.
- A closed laptop has little airflow. Use HomeLab mode on a hard surface with
  ventilation, preferably on AC, and do not leave it running in a bag.
- Paths are fixed under `~/.local` and `~/.config`, matching Omarchy's own
  state and unit locations.
- Tested on Omarchy 4.5 with a ThinkPad (internal output `eDP-1`). Some
  ThinkPads lose the internal keyboard after a lid-open without suspend; a
  suspend/resume cycle resets the controller.

## Uninstall

```bash
./install.sh --uninstall
```

This stops and disables the units, removes the symlinks and the bar widget,
clears the mode flag, and returns the machine to Laptop mode. The checkout is
not touched.

## Layout

```
bin/homelab               mode switch and status
bin/homelab-lid-watch     lid watcher / DPMS handling
manifest.json             Omarchy bar-widget manifest
plugin/BarWidget.qml      bar toggle and mode indicator
systemd/user/             user units
install.sh                symlink + enable helper
```
