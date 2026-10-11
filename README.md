# pc-leds

Control (and turn **off**) your PC's RGB LEDs on Linux — motherboard ARGB headers,
onboard LEDs, **and RAM** — from a single command, and have them come up **off by
default at every login**.

Built on [OpenRGB](https://openrgb.org). The installer provisions everything a
fresh OS install needs, so you never have to hand-configure
[udev rules](https://openrgb.org/udev), kernel parameters, or zone sizes again.

```
leds off      # everything dark
leds on       # back on (single configurable colour)
leds toggle   # flip
leds status   # what OpenRGB can see
```

## Why this exists

Getting RAM RGB off on modern AM5 boards is fiddly:

- OpenRGB needs **udev rules** for unprivileged device access.
- RAM RGB sits on the **AMD FCH SMBus**, whose I/O region is often reserved by
  the BIOS's ACPI (`\GSA1.SMBI`), so `i2c_piix4` refuses to bind.
  The fix is the kernel parameter `acpi_enforce_resources=lax`.
- The motherboard's **addressable (ARGB) headers** report **0 LEDs** by default,
  so OpenRGB has nothing to drive until the zones are sized.

`install.sh` handles all three, then drops a `leds` command, desktop launchers,
and a login autostart so the lights simply stay off.

## Requirements

- Linux with OpenRGB support for your hardware (see the OpenRGB device list).
- `sudo` for the one-time setup (udev rules, kernel param, OpenRGB install).
- A source for OpenRGB: the installer uses your distro's package if present,
  otherwise downloads the matching **RPM / DEB / AppImage** from the official
  [OpenRGB releases](https://github.com/CalcProgrammer1/OpenRGB/releases).

## Install

```bash
git clone <this-repo-url> ~/pc-leds
cd ~/pc-leds
./install.sh
```

Or fetch and run in one line (review the script first, as always):

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
| `--no-udev` | skip udev rules |
| `--no-kernel-param` | skip `acpi_enforce_resources=lax` (RAM RGB will be unavailable) |
| `--no-autostart` | don't turn LEDs off at login |
| `--no-launchers` | don't create desktop launchers |
| `--skip-system` | user-level steps only (no sudo; handy for testing) |

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
- **`leds on`** — paints every device `ON_COLOR`.
- Devices are selected by **name/type**, not index, because OpenRGB renumbers
  them between reboots.
- The login autostart (`~/.config/autostart/leds-off.desktop`) runs
  `leds off` quietly, waiting for devices to appear first.

## Troubleshooting

- **RAM not detected / `leds status` shows no DRAM device.** The SMBus isn't
  bound. Confirm `acpi_enforce_resources=lax` is on the kernel cmdline
  (`cat /proc/cmdline`) and `i2c-dev` is loaded. `sudo bash scripts/diagnose-smbus.sh`
  prints the SMBus state.
- **Some ARGB fans/strips stay partly lit.** Raise `ARGB_SIZE` in the config
  (the tail beyond the size isn't updated).
- **Nothing detected at all.** Check `ls /etc/udev/rules.d/60-openrgb.rules`
  exists and re-run `sudo udevadm control --reload-rules && sudo udevadm trigger`.
- **No sudo available.** Run `./install.sh --skip-system` and perform the udev /
  kernel steps manually.

## Uninstall

```bash
cd ~/pc-leds
./uninstall.sh                      # remove user files only
./uninstall.sh --purge-udev --purge-kernel-param   # also system changes
./uninstall.sh --purge-config --purge-openrgb      # also config & OpenRGB
```

## License

MIT (see `LICENSE`). OpenRGB is a separate project (GPL-2.0); this tool merely
drives it. The bundled `scripts/diagnose-smbus.sh` is part of this project.
