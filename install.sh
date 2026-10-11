#!/usr/bin/env bash
# =============================================================================
#  pc-leds installer
# -----------------------------------------------------------------------------
#  One command sets up everything needed to control PC RGB LEDs (motherboard
#  ARGB headers + RAM) on a fresh Linux install:
#     * system side (root): OpenRGB, udev rules, i2c-dev, kernel parameter
#                           -> scripts/setup-system.sh  (distro-aware)
#     * user side:          the `leds` CLI, the PC LEDs GUI, desktop launchers,
#                           and off-at-login (XDG autostart or a systemd user
#                           service).
#
#  Idempotent: safe to re-run.  --help for options.
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="$HOME/.local/bin/leds"
GUI_DST="$HOME/.local/bin/pc-leds-gui"
SUPPORT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pc-leds"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pc-leds"
CONFIG_FILE="$CONFIG_DIR/config"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON="video-display"

ON_COLOR="ffffff"
ARGB_SIZE="128"
ON_COLOR_SET=0
ARGB_SIZE_SET=0
AUTOSTART_METHOD="xdg"        # xdg | systemd | none
DO_UDEV=1
DO_KPARAM=1
DO_LAUNCHERS=1
DO_GUI=1
SKIP_SYSTEM=0
REBOOT_NEEDED=0

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else B=""; G=""; Y=""; N=""; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
pc-leds installer

Usage: ./install.sh [options]

Options:
  --on-color RRGGBB            colour used by 'leds on'        (default: $ON_COLOR)
  --argb-size N                LEDs per addressable header      (default: $ARGB_SIZE)
  --autostart-method METHOD    xdg | systemd | none            (default: xdg)
  --no-udev                    skip OpenRGB udev rules
  --no-kernel-param            skip acpi_enforce_resources=lax (RAM RGB stays off)
  --no-launchers               don't create desktop launchers
  --no-gui                     don't install the GTK GUI
  --skip-system                user-level steps only (no sudo); useful for testing
  -y, --yes                    assume yes / non-interactive
  -h, --help                   this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --on-color)         ON_COLOR="${2:-}"; ON_COLOR_SET=1; shift 2 ;;
    --argb-size)        ARGB_SIZE="${2:-}"; ARGB_SIZE_SET=1; shift 2 ;;
    --autostart-method) AUTOSTART_METHOD="${2:-xdg}"; shift 2 ;;
    --no-udev)          DO_UDEV=0; shift ;;
    --no-kernel-param)  DO_KPARAM=0; shift ;;
    --no-launchers)     DO_LAUNCHERS=0; shift ;;
    --no-gui)           DO_GUI=0; shift ;;
    --skip-system)      SKIP_SYSTEM=1; shift ;;
    -y|--yes)           shift ;;
    -h|--help)          usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

case "$AUTOSTART_METHOD" in xdg|systemd|none) ;; *) die "--autostart-method must be xdg, systemd or none" ;; esac

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

# --------------------------------------------------------------- system ------
system_setup() {
  if [ "$SKIP_SYSTEM" = 1 ]; then
    step "System setup"; warn "skipped (--skip-system)"; return 0
  fi
  step "System setup (OpenRGB, udev, i2c-dev, kernel parameter)"
  local flags=()
  [ "$DO_UDEV" = 0 ]   && flags+=(--no-udev)
  [ "$DO_KPARAM" = 0 ] && flags+=(--no-kernel-param)
  local rc=0
  $SUDO bash "$SELF_DIR/scripts/setup-system.sh" "${flags[@]}" || rc=$?
  [ "$rc" = 10 ] && REBOOT_NEEDED=1
  return 0
}

# ------------------------------------------------------------------- CLI -----
install_cli() {
  step "Installing the 'leds' command"
  mkdir -p "$HOME/.local/bin"
  rm -f "$BIN_DST"   # never write through a symlink into the source file
  install -m755 "$SELF_DIR/bin/leds" "$BIN_DST"
  ok "$BIN_DST"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) warn "~/.local/bin is not in PATH - add it to run 'leds' directly" ;;
  esac
}

# --------------------------------------------------------------- support -----
install_support() {
  step "Support files"
  mkdir -p "$SUPPORT_DIR/bin" "$SUPPORT_DIR/scripts"
  install -m755 "$SELF_DIR/bin/leds" "$SUPPORT_DIR/bin/leds"
  [ -f "$SELF_DIR/bin/pc-leds-gui" ] && install -m755 "$SELF_DIR/bin/pc-leds-gui" "$SUPPORT_DIR/bin/pc-leds-gui"
  install -m755 "$SELF_DIR/scripts/setup-system.sh" "$SUPPORT_DIR/scripts/setup-system.sh"
  [ -f "$SELF_DIR/scripts/diagnose-smbus.sh" ] && install -m755 "$SELF_DIR/scripts/diagnose-smbus.sh" "$SUPPORT_DIR/scripts/diagnose-smbus.sh"
  install -m644 "$SELF_DIR/install.sh" "$SUPPORT_DIR/install.sh"
  [ -f "$SELF_DIR/uninstall.sh" ] && install -m755 "$SELF_DIR/uninstall.sh" "$SUPPORT_DIR/uninstall.sh"
  ok "$SUPPORT_DIR"
}

# ------------------------------------------------------------------- GUI -----
detect_pygtk() {
  local cand
  for cand in /usr/bin/python3 /usr/local/bin/python3 python3; do
    { command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; } || continue
    "$cand" - <<'PY' >/dev/null 2>&1 && { printf '%s' "$cand"; return 0; }
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw
PY
  done
  return 1
}

install_gui() {
  [ "$DO_GUI" = 1 ] || return 0
  step "GUI (PC LEDs)"
  [ -f "$SELF_DIR/bin/pc-leds-gui" ] || { warn "GUI source missing"; return 0; }
  local py; py="$(detect_pygtk || true)"
  if [ -z "$py" ]; then
    warn "GTK4 + PyGObject not found - skipping GUI"
    warn "install it (gtk4 libadwaita python3-gobject) and re-run"
    return 0
  fi
  mkdir -p "$HOME/.local/bin"
  install -m755 "$SELF_DIR/bin/pc-leds-gui" "$GUI_DST"
  sed -i "1s|^#!.*|#!$py|" "$GUI_DST"
  ok "$GUI_DST (via $py)"
  write_gui_launcher
}

write_gui_launcher() {
  local dd; dd="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  [ -n "$dd" ] && [ -d "$dd" ] || dd="$HOME/Desktop"
  mkdir -p "$dd" "$APP_DIR"
  cat > "$dd/PC-LEDs.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PC LEDs
Comment=Control PC RGB LEDs
Exec=$GUI_DST
Terminal=false
Icon=$ICON
Categories=Utility;Settings;
EOF
  chmod +x "$dd/PC-LEDs.desktop"
  cp -f "$dd/PC-LEDs.desktop" "$APP_DIR/PC-LEDs.desktop"
  command -v gio >/dev/null 2>&1 && gio set "$dd/PC-LEDs.desktop" metadata::trusted true 2>/dev/null || true
}

# ----------------------------------------------------------------- config ----
set_kv() {   # key value  (set or add a key in the config file)
  if grep -q "^$1=" "$CONFIG_FILE"; then sed -i "s|^$1=.*|$1=\"$2\"|" "$CONFIG_FILE"
  else echo "$1=\"$2\"" >> "$CONFIG_FILE"; fi
}

write_config() {
  step "Configuration"
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<EOF
# pc-leds configuration

# colour used by 'leds on' (RRGGBB)
ON_COLOR="$ON_COLOR"

# LEDs per addressable header (raise for long strips)
ARGB_SIZE="$ARGB_SIZE"

# optional explicit zone indexes, e.g. "0 1 2"; empty = auto-detect
ARGB_ZONES=""
EOF
  else
    # only override values the user explicitly passed on the command line
    [ "$ON_COLOR_SET" = 1 ]  && set_kv ON_COLOR "$ON_COLOR"
    [ "$ARGB_SIZE_SET" = 1 ] && set_kv ARGB_SIZE "$ARGB_SIZE"
    # repair an ARGB_ZONES line that swallowed a trailing comment
    grep -Eq '^ARGB_ZONES=.*#' "$CONFIG_FILE" && set_kv ARGB_ZONES ""
    grep -q '^ON_COLOR='  "$CONFIG_FILE" || set_kv ON_COLOR "$ON_COLOR"
    grep -q '^ARGB_SIZE=' "$CONFIG_FILE" || set_kv ARGB_SIZE "$ARGB_SIZE"
    grep -q '^ARGB_ZONES=' "$CONFIG_FILE" || set_kv ARGB_ZONES ""
  fi
  ok "$CONFIG_FILE"
}

# -------------------------------------------------------------- launchers ----
write_launcher() {   # path name comment action
  cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Comment=$3
Exec=$BIN_DST $4
Terminal=false
Icon=$ICON
Categories=Utility;Settings;
EOF
}

install_launchers() {
  [ "$DO_LAUNCHERS" = 1 ] || return 0
  step "Desktop launchers"
  local dd; dd="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  [ -n "$dd" ] && [ -d "$dd" ] || dd="$HOME/Desktop"
  mkdir -p "$dd" "$APP_DIR"
  write_launcher "$dd/LEDs-OFF.desktop" "LEDs OFF" "Turn off all PC RGB LEDs" "off"
  write_launcher "$dd/LEDs-ON.desktop"  "LEDs ON"  "Turn the PC RGB LEDs back on" "on"
  chmod +x "$dd"/LEDs-OFF.desktop "$dd"/LEDs-ON.desktop
  cp -f "$dd/LEDs-OFF.desktop" "$dd/LEDs-ON.desktop" "$APP_DIR/"
  if command -v gio >/dev/null 2>&1; then
    gio set "$dd/LEDs-OFF.desktop" metadata::trusted true 2>/dev/null || true
    gio set "$dd/LEDs-ON.desktop"  metadata::trusted true 2>/dev/null || true
  fi
  ok "launchers in $dd"
}

# -------------------------------------------------------------- autostart ----
write_systemd_unit() {
  mkdir -p "$SYSTEMD_DIR"
  cat > "$SYSTEMD_DIR/pc-leds-off.service" <<EOF
[Unit]
Description=Turn off PC RGB LEDs (pc-leds)
Documentation=https://github.com/Shahzad-Marth/pc-leds
After=graphical-session.target
PartOf=graphical-session.target
StartLimitIntervalSec=60
StartLimitBurst=20

[Service]
Type=oneshot
Environment=LEDS_QUIET=1
ExecStartPre=/bin/sleep 5
ExecStart=%h/.local/bin/leds off
RemainAfterExit=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
}

install_autostart() {
  step "Autostart (LEDs off by default)"
  mkdir -p "$AUTOSTART_DIR"
  case "$AUTOSTART_METHOD" in
    none)
      rm -f "$AUTOSTART_DIR/leds-off.desktop" "$SYSTEMD_DIR/pc-leds-off.service"
      warn "autostart disabled (--autostart-method none)"
      ;;
    xdg)
      rm -f "$SYSTEMD_DIR/pc-leds-off.service"
      cat > "$AUTOSTART_DIR/leds-off.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PC LEDs Off (autostart)
Comment=Turn off all PC RGB LEDs at login
Exec=env LEDS_QUIET=1 $BIN_DST off
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
      ok "XDG autostart: $AUTOSTART_DIR/leds-off.desktop"
      ;;
    systemd)
      rm -f "$AUTOSTART_DIR/leds-off.desktop"
      write_systemd_unit
      if systemctl --user daemon-reload 2>/dev/null && systemctl --user enable pc-leds-off.service 2>/dev/null; then
        ok "systemd user service enabled: pc-leds-off.service"
      else
        warn "installed unit, but could not enable it now"
        warn "run:  systemctl --user enable --now pc-leds-off.service"
      fi
      ;;
  esac
}

# ------------------------------------------------------------------- main ----
printf '%spc-leds installer%s\n' "$B" "$N"
system_setup
install_cli
install_support
install_gui
write_config
install_launchers
install_autostart

step "Applying (LEDs off)"
[ -x "$BIN_DST" ] && "$BIN_DST" off || warn "could not run leds off"

printf '\n%sDone.%s\n' "$B" "$N"
[ "$REBOOT_NEEDED" = 1 ] && printf '  %sReboot required%s for the SMBus change (RAM RGB) to take effect.\n' "$Y" "$N"
printf '  CLI :  leds off | leds on | leds status | leds setup | leds gui\n'
[ "$DO_GUI" = 1 ] && printf '  GUI :  PC LEDs  (or: pc-leds-gui)\n'
[ "$AUTOSTART_METHOD" != none ] && printf '  LEDs will turn off automatically at each login (%s).\n' "$AUTOSTART_METHOD"
