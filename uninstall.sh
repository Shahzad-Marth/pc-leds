#!/usr/bin/env bash
# =============================================================================
#  pc-leds uninstaller
# -----------------------------------------------------------------------------
#  Removes the user-level files installed by install.sh. System changes
#  (udev rules, kernel parameter, OpenRGB) are only removed with explicit
#  --purge-* flags.
# =============================================================================
set -uo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pc-leds"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

PURGE_UDEV=0
PURGE_KPARAM=0
PURGE_CONFIG=0
PURGE_OPENRGB=0

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'; else B=""; G=""; Y=""; N=""; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }

usage() {
  cat <<EOF
pc-leds uninstaller

Usage: ./uninstall.sh [options]

Options:
  --purge-udev          also remove /etc/udev/rules.d/60-openrgb.rules
  --purge-kernel-param  also remove acpi_enforce_resources=lax from the bootloader
  --purge-config        also remove $CONFIG_DIR
  --purge-openrgb       also uninstall OpenRGB (dnf/apt remove openrgb)
  -h, --help            this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --purge-udev)         PURGE_UDEV=1; shift ;;
    --purge-kernel-param) PURGE_KPARAM=1; shift ;;
    --purge-config)       PURGE_CONFIG=1; shift ;;
    --purge-openrgb)      PURGE_OPENRGB=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

step "User files"
rm -f "$HOME/.local/bin/leds" && ok "removed ~/.local/bin/leds"
rm -f "$AUTOSTART_DIR/leds-off.desktop" && ok "removed autostart entry"
rm -f "$APP_DIR/LEDs-OFF.desktop" "$APP_DIR/LEDs-ON.desktop" && ok "removed application entries"
DD="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
rm -f "$DD/LEDs-OFF.desktop" "$DD/LEDs-ON.desktop" && ok "removed desktop launchers"

if [ "$PURGE_CONFIG" = 1 ]; then
  step "Config"
  rm -rf "$CONFIG_DIR" && ok "removed $CONFIG_DIR"
fi

if [ "$PURGE_UDEV" = 1 ]; then
  step "Udev rules"
  [ -n "$SUDO" ] && $SUDO rm -f /etc/udev/rules.d/60-openrgb.rules && { $SUDO udevadm control --reload-rules; $SUDO udevadm trigger; ok "removed"; }
fi

if [ "$PURGE_KPARAM" = 1 ]; then
  step "Kernel parameter"
  if command -v grubby >/dev/null 2>&1; then
    [ -n "$SUDO" ] && $SUDO grubby --update-kernel=ALL --remove-args="acpi_enforce_resources=lax" && ok "removed (reboot to apply)"
  else
    warn "remove acpi_enforce_resources=lax from your bootloader manually"
  fi
fi

if [ "$PURGE_OPENRGB" = 1 ]; then
  step "OpenRGB"
  if command -v dnf >/dev/null 2>&1; then $SUDO dnf remove -y openrgb
  elif command -v apt-get >/dev/null 2>&1; then $SUDO apt-get remove -y openrgb
  else warn "remove OpenRGB with your package manager"; fi
fi

printf '\n%sDone.%s\n' "$B" "$N"
