# Omarchy integration

HomeLab is usable from the CLI and the bar. These snippets make it feel native
in Omarchy's menu and keybindings. They are user configuration; the installer
does not edit your menu or binding files.

## Menu

Merge this row into `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
{
  // Appears under Trigger → Toggle. The check mark reflects the mode flag.
  "trigger.toggle.homelab": {
    "icon": "󰒋",
    "label": "HomeLab Mode",
    "aliases": ["homelab", "lid hold", "keep awake"],
    "checked": "[[ -f ${XDG_STATE_HOME:-$HOME/.local/state}/homelab/enabled ]]",
    "action": "homelab toggle"
  }
}
```

The dotted id places it under the existing **Trigger → Toggle** submenu. The
`checked` condition is a shell test; the `action` runs the same CLI as the bar
icon.

## Keybinding

Add an unused chord to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + H", "Toggle HomeLab mode", "homelab toggle")
```

`SUPER + SHIFT + H` is free in the stock bindings as of Omarchy 4.5. The
binding runs the CLI, so the bar and the desktop notification update with it.

## Install and update as a plugin

The repository root is the plugin folder:

```bash
omarchy plugin add https://github.com/wxxb789/omarchy-homelab.git --enable
~/.config/omarchy/plugins/io.github.wxxb789.homelab/install.sh
```

`omarchy plugin add` places the widget; `install.sh` links the CLI and systemd
units and enables the widget. Updating:

```bash
omarchy plugin update io.github.wxxb789.homelab --yes
~/.config/omarchy/plugins/io.github.wxxb789.homelab/install.sh
omarchy restart shell
```

The plugin is a normal third-party `bar-widget`; it does not reserve the
`omarchy.*` namespace. The installer also handles the git-clone workflow:

```bash
git clone https://github.com/wxxb789/omarchy-homelab.git ~/repos/omarchy-homelab
cd ~/repos/omarchy-homelab
./install.sh
```

## Marketplace and upstream

The plugin is a good candidate for the Omarchy plugin marketplace once it has a
preview image and a short listing description. The marketplace is the faster
distribution path; upstream is the durable one.

If proposing this upstream, frame it as a **lid hold**, not a new power
subsystem:

- Omarchy already owns lid-close locking and clamshell display handling.
- The missing piece is a reversible, per-user `handle-lid-switch` inhibitor
  with panel DPMS and a deadline.
- The safe default is to leave `HandleLidSwitch` untouched and require no root.
- A native version would fit best in the power panel or as
  `omarchy toggle lid`, with the same battery/thermal warnings.
- Per Omarchy's contribution guide, start with a GitHub Discussion suggestion;
  keep verified bugs in issues.

The prototype in this repository is intentionally small enough to be a
reference implementation: two ordered units, a watcher, a deadline service, a
CLI with JSON status, and a bar widget.
