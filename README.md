# pc-leds

Control (and turn **off**) your PC's RGB LEDs on Linux — motherboard ARGB headers,
onboard LEDs, **and RAM** — from a single command *or a small GUI*, and have them
come up **off by default at every login**.

Built on [OpenRGB](https://openrgb.org). The installer provisions everything a
fresh OS install needs, so you never have to hand-configure udev rules, kernel
parameters, or zone sizes again.

```bash
leds off      # everything dark
leds on       # back on (single configurable colour)
leds toggle   # flip
leds status   # what OpenRGB can see
leds setup    # install OpenRGB + configure this machine (distro-aware)
leds gui      # open the graphical app
```

There's also a GTK4 app (`PC LEDs`), styled dark like OpenRGB, with **ON/OFF**
buttons, a colour picker, per-device switches, and an **Install / Configure**
button that installs OpenRGB and sets up the system for you.

## Why this exists

Getting RAM RGB off on modern AM5 boards is fiddly:

- OpenRGB needs **udev rules** for unprivileged device access.
- RAM RGB sits on the **AMD FCH SMBus**, whose I/O region is often reserved by
  the BIOS's ACPI (`\GSA1.SMBI`), so `i2c_piix4` refuses to bind. The fix is the
  kernel parameter `acpi_enforce_resources=lax`.
- The motherboard's **addressable (ARGB) headers** report **0 LEDs** by default,
  so OpenRGB has nothing to drive until the zones are sized.

`install.sh` handles all three, then drops a `leds` command, a GUI, desktop
launchers, and off-at-login.

## Requirements

- Linux with OpenRGB support for your hardware.
- `sudo` for the one-time setup (udev rules, kernel parameter, OpenRGB).
- For the GUI: GTK4 + PyGObject + libadwaita (installed automatically by the
  system setup step when missing).

## Install

```bash
git clone <this-repo-url> ~/pc-leds
cd ~/pc-leds
./install.sh
```

Or fetch and run in one line (review first, as always):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Shahzad-Marth/pc-leds/main/install.sh)
```

If a reboot is requested at the end (for the kernel parameter), reboot once.
Then run `leds status` to confirm your boards/RAM are detected.

### Installer options

| Option | Effect |
|---|---|
| `--on-color RRGGBB` | colour used by `leds on` (default `ffffff`) |
| `--argb-size N` | LEDs per addressable header (default `128`) |
| `--autostart-method M` | `xdg` (default), `systemd`, or `none` |
| `--no-udev` | skip udev rules |
| `--no-kernel-param` | skip `acpi_enforce_resources=lax` (RAM RGB will be unavailable) |
| `--no-launchers` | don't create desktop launchers |
| `--no-gui` | don't install the GTK GUI |
| `--skip-system` | user-level steps only (no sudo) |

## The GUI

Launch **PC LEDs** from your applications/desktop, or run `pc-leds-gui`
(`leds gui`). It shows every device OpenRGB can see with its supported modes,
gives you **ON** / **OFF** for everything and a switch per device, and a colour
picker for the ON colour.

The **Install / Configure** button runs the same distro-aware setup — it
installs OpenRGB (native RPM/DEB, else the official AppImage), writes the udev
rules, loads `i2c-dev`, and adds the kernel parameter — using PolicyKit
(`pkexec`), so no terminal is needed. Enter your password when prompted.

## Off at login

Two interchangeable mechanisms; pick with `--autostart-method`:

- **`xdg`** (default) — `~/.config/autostart/leds-off.desktop`.
- **`systemd`** — a user service at `~/.config/systemd/user/pc-leds-off.service`,
  enabled at `graphical-session.target`. It waits 5 s for devices, and retries on
  failure (the `leds off` command exits non-zero when no devices are ready yet).
  Manage it with:

  ```bash
  systemctl --user status pc-leds-off.service
  systemctl --user restart pc-leds-off.service
  ```

Both just run `leds off` quietly after login.

## Configuration

`~/.config/pc-leds/config`:

```sh
ON_COLOR="ffffff"   # colour used by 'leds on'
ARGB_SIZE="128"     # LEDs per addressable header (raise for long strips)
ARGB_ZONES=""       # optional explicit zone indexes, e.g. "0 1 2"
```

`ARGB_SIZE` matters: most ARGB headers are user-sized and default to 0, so a
colour never reaches them until the zone is sized. If you add longer strips and
the last few LEDs stay lit, raise `ARGB_SIZE`.

## How it works

- **`leds off`** — sizes any `ARGB`/addressable zones on the motherboard, paints
  every detected device black, then switches devices that expose a native
  `Off` mode (e.g. ENE DRAM) to it.
- **`leds on`** — sizes the zones, then paints every device `ON_COLOR`.
- Devices are selected by **name/type**, not index, because OpenRGB renumbers
  them between reboots.
- System changes live in `scripts/setup-system.sh` (run as root), so both the
  installer and the GUI can reuse them.

## Layout

```
install.sh            user-level install (calls setup-system.sh via sudo)
uninstall.sh          remove everything installed here
bin/leds              the CLI
bin/pc-leds-gui       the GTK4/libadwaita GUI
scripts/setup-system.sh   root system setup (OpenRGB, udev, i2c, kernel param)
scripts/diagnose-smbus.sh SMBus / RAM-RGB diagnostics
```

`install.sh` also copies these into `~/.local/share/pc-leds/` so `leds setup`
and the GUI work even if you delete the git clone.

## Troubleshooting

- **RAM not detected / `leds status` shows no DRAM device.** The SMBus isn't
  bound. Check `acpi_enforce_resources=lax` is on the kernel cmdline
  (`cat /proc/cmdline`) and `i2c-dev` is loaded. `sudo bash scripts/diagnose-smbus.sh`
  prints the SMBus state.
- **Some ARGB fans/strips stay partly lit.** Raise `ARGB_SIZE` in the config.
- **Nothing detected at all.** Confirm `/etc/udev/rules.d/60-openrgb.rules`
  exists, then `sudo udevadm control --reload-rules && sudo udevadm trigger`.
- **GUI won't start.** The GUI needs `python3-gobject`, `gtk4`, `libadwaita`;
  re-run `./install.sh` (or the GUI's Install / Configure) to pull them in.

## Uninstall

```bash
cd ~/pc-leds
./uninstall.sh                                     # user files only
./uninstall.sh --purge-udev --purge-kernel-param   # also system changes
./uninstall.sh --purge-config --purge-openrgb      # also config & OpenRGB
```

## License

MIT (see `LICENSE`). OpenRGB is a separate project (GPL-2.0); this tool merely
drives it.
