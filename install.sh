#!/usr/bin/env bash
# =============================================================================
#  pc-leds installer
# -----------------------------------------------------------------------------
#  One command sets up everything needed to control PC RGB LEDs (motherboard
#  ARGB headers + RAM) on a fresh Linux install:
#     * OpenRGB               (native package or AppImage from the official
#                              GitHub release, chosen for your platform)
#     * OpenRGB udev rules     (so devices are accessible without root)
#     * i2c-dev module         (so SMBus / RAM RGB can be reached)
#     * kernel parameter       acpi_enforce_resources=lax  (lets the AMD SMBus
#                              bind when the BIOS reserves it)
#     * the `leds` CLI         -> ~/.local/bin/leds
#     * desktop launchers      "LEDs ON" / "LEDs OFF"
#     * login autostart        turns everything off at login by default
#
#  Idempotent: safe to re-run. Use --help for options.
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="$HOME/.local/bin/leds"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pc-leds"
CONFIG_FILE="$CONFIG_DIR/config"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON="video-display"

ON_COLOR="ffffff"
ARGB_SIZE="128"
DO_UDEV=1
DO_KPARAM=1
DO_AUTOSTART=1
DO_LAUNCHERS=1
SKIP_SYSTEM=0
REBOOT_NEEDED=0

# ------------------------------------------------------------------ output ---
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '%sERROR:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
pc-leds installer

Usage: ./install.sh [options]

Options:
  --on-color RRGGBB     default colour used by 'leds on'   (default: $ON_COLOR)
  --argb-size N         LEDs per addressable header        (default: $ARGB_SIZE)
  --no-udev             skip installing OpenRGB udev rules
  --no-kernel-param     skip acpi_enforce_resources=lax (RAM RGB stays unavailable)
  --no-autostart        don't turn LEDs off automatically at login
  --no-launchers        don't create desktop launchers
  --skip-system         only do user-level steps (no sudo); useful for testing
  -y, --yes             assume yes / non-interactive
  -h, --help            this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --on-color)       ON_COLOR="${2:-}"; shift 2 ;;
    --argb-size)      ARGB_SIZE="${2:-}"; shift 2 ;;
    --no-udev)        DO_UDEV=0; shift ;;
    --no-kernel-param) DO_KPARAM=0; shift ;;
    --no-autostart)   DO_AUTOSTART=0; shift ;;
    --no-launchers)   DO_LAUNCHERS=0; shift ;;
    --skip-system)    SKIP_SYSTEM=1; shift ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# -------------------------------------------------------------------- sudo ---
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

sys() {   # run a system command (best effort)
  if [ "$SKIP_SYSTEM" = 1 ]; then warn "skipped (--skip-system): $*"; return 0; fi
  if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then warn "no sudo; skipped: $*"; return 0; fi
  $SUDO "$@"
}

# --------------------------------------------------------------- OpenRGB -----
pick_asset_url() {  # arch distro version  -> prints a download URL
  python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null
import sys, json, urllib.request
arch, distro, ver = sys.argv[1], sys.argv[2], sys.argv[3]
want = {"x86_64":"x86_64","amd64":"x86_64","aarch64":"arm64",
        "armv7l":"armhf","i686":"i386"}.get(arch, arch)
try:
    req = urllib.request.Request(
        "https://api.github.com/repos/CalcProgrammer1/OpenRGB/releases/latest",
        headers={"User-Agent": "pc-leds-installer"})
    data = json.load(urllib.request.urlopen(req, timeout=30))
except Exception:
    sys.exit(1)
assets = [(a["name"], a["browser_download_url"]) for a in data.get("assets", [])]
def pick(pred):
    for n, u in assets:
        if pred(n):
            return u
    return ""
def deb_ok(n):
    if not n.endswith(".deb"):
        return False
    return want in n or (want == "x86_64" and "amd64" in n) or (want == "arm64" and "arm64" in n)
sel = ""
if distro == "fedora":
    sel = pick(lambda n: n.endswith(".rpm") and want in n and ("_f%s_" % ver) in n)
if not sel and distro in ("debian","ubuntu","linuxmint","pop","elementary","zorin","kali"):
    sel = pick(deb_ok)
if not sel:
    sel = pick(lambda n: n.endswith(".AppImage") and want in n and "MacOS" not in n)
print(sel)
PY
}

install_openrgb() {
  . /etc/os-release 2>/dev/null || true
  local arch url fname tmp; arch="$(uname -m)"
  url="$(pick_asset_url "$arch" "${ID:-}" "${VERSION_ID:-}")"
  [ -n "$url" ] || { warn "no matching OpenRGB build for ${arch}/${ID:-unknown}"; return 1; }
  fname="$(basename "$url")"; tmp="$(mktemp -d)"
  info "downloading $fname"
  curl -fsSL "$url" -o "$tmp/$fname" || { warn "download failed"; rm -rf "$tmp"; return 1; }
  case "$fname" in
    *.rpm) sys dnf install -y "$tmp/$fname" ;;
    *.deb) sys apt-get install -y "$tmp/$fname" ;;
    *.AppImage)
      chmod +x "$tmp/$fname"
      ( cd "$tmp" && "./$fname" --appimage-extract >/dev/null 2>&1 ) || { warn "extract failed"; return 1; }
      mkdir -p "$HOME/Applications"
      rm -rf "$HOME/Applications/OpenRGB"
      mv "$tmp/squashfs-root" "$HOME/Applications/OpenRGB"
      mkdir -p "$HOME/.local/bin"
      cat > "$HOME/.local/bin/openrgb" <<WRAP
#!/usr/bin/env bash
exec "$HOME/Applications/OpenRGB/AppRun" "\$@"
WRAP
      chmod +x "$HOME/.local/bin/openrgb"
      ;;
    *) warn "unsupported package: $fname"; rm -rf "$tmp"; return 1 ;;
  esac
  rm -rf "$tmp"
  return 0
}

ensure_openrgb() {
  step "OpenRGB"
  OPENRGB_BIN="$(command -v openrgb || true)"
  [ -z "$OPENRGB_BIN" ] && [ -x "$HOME/.local/bin/openrgb" ] && OPENRGB_BIN="$HOME/.local/bin/openrgb"
  if [ -n "$OPENRGB_BIN" ]; then ok "found $OPENRGB_BIN"; return 0; fi
  warn "not found - installing from the official GitHub release"
  install_openrgb || die "could not install OpenRGB; install it manually and re-run"
  OPENRGB_BIN="$(command -v openrgb || echo "$HOME/.local/bin/openrgb")"
  [ -x "$OPENRGB_BIN" ] || die "OpenRGB install did not succeed"
  ok "installed $OPENRGB_BIN"
}

# ------------------------------------------------------------------ udev -----
install_udev() {
  step "OpenRGB udev rules (device access without root)"
  if [ -f /etc/udev/rules.d/60-openrgb.rules ] || [ -f /usr/lib/udev/rules.d/60-openrgb.rules ]; then
    warn "rules already installed - reloading"
    sys udevadm control --reload-rules
    sys udevadm trigger
    ok "done"
    return 0
  fi
  local tmp rules=""; tmp="$(mktemp)"
  if "$OPENRGB_BIN" --help 2>&1 | grep -q -- '--generate-udev-rules'; then
    "$OPENRGB_BIN" --generate-udev-rules "$tmp" >/dev/null 2>&1 && [ -s "$tmp" ] && rules="$tmp"
  elif "$OPENRGB_BIN" --help 2>&1 | grep -q -- '--print-udev-rules'; then
    "$OPENRGB_BIN" --print-udev-rules > "$tmp" 2>/dev/null && [ -s "$tmp" ] && rules="$tmp"
  fi
  if [ -z "$rules" ]; then
    local cand
    for cand in \
      "$HOME/Applications/OpenRGB/usr/lib/udev/rules.d/60-openrgb.rules" \
      /usr/lib/udev/rules.d/60-openrgb.rules \
      /usr/share/openrgb/60-openrgb.rules \
      /usr/local/share/openrgb/60-openrgb.rules; do
      [ -f "$cand" ] && rules="$cand" && break
    done
  fi
  rm -f "$tmp"
  [ -n "$rules" ] || { warn "could not find/generate udev rules - devices may need root"; return 0; }
  sys install -Dm644 "$rules" /etc/udev/rules.d/60-openrgb.rules || return 0
  sys udevadm control --reload-rules
  sys udevadm trigger
  ok "installed /etc/udev/rules.d/60-openrgb.rules"
}

# --------------------------------------------------------------- i2c-dev -----
ensure_i2c_dev() {
  step "i2c-dev module (SMBus / RAM RGB access)"
  if [ "$SKIP_SYSTEM" = 1 ] || { [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; }; then warn "skipped"; return 0; fi
  $SUDO modprobe i2c-dev 2>/dev/null || true
  local t; t="$(mktemp)"; echo i2c-dev > "$t"
  $SUDO install -Dm644 "$t" /etc/modules-load.d/pc-leds.conf
  rm -f "$t"
  ok "i2c-dev enabled"
}

# --------------------------------------------------------- kernel parameter --
add_kernel_param() {
  step "Kernel parameter: acpi_enforce_resources=lax"
  if grep -q 'acpi_enforce_resources=lax' /proc/cmdline; then ok "already active"; return 0; fi
  if [ "$SKIP_SYSTEM" = 1 ] || { [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; }; then
    warn "skipped; add 'acpi_enforce_resources=lax' to the kernel cmdline for RAM RGB"; return 0
  fi
  if command -v grubby >/dev/null 2>&1; then
    if $SUDO grubby --info=ALL 2>/dev/null | grep -q 'acpi_enforce_resources=lax'; then
      ok "already configured in bootloader"
    else
      $SUDO grubby --update-kernel=ALL --args="acpi_enforce_resources=lax" && { ok "added (via grubby)"; REBOOT_NEEDED=1; }
    fi
  elif [ -f /etc/default/grub ]; then
    if grep -q 'acpi_enforce_resources=lax' /etc/default/grub; then
      ok "already configured"
    else
      $SUDO cp /etc/default/grub /etc/default/grub.pc-leds.bak
      $SUDO sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 acpi_enforce_resources=lax"/' /etc/default/grub
      if command -v update-grub >/dev/null 2>&1; then $SUDO update-grub; elif command -v grub-mkconfig >/dev/null 2>&1; then $SUDO grub-mkconfig -o /boot/grub/grub.cfg; fi
      ok "added to GRUB"; REBOOT_NEEDED=1
    fi
  else
    warn "could not configure the bootloader; add 'acpi_enforce_resources=lax' manually"
  fi
}

# ------------------------------------------------------------------- CLI -----
install_cli() {
  step "Installing the 'leds' command"
  mkdir -p "$HOME/.local/bin"
  rm -f "$BIN_DST"   # don't write through a symlink into the source file
  install -m755 "$SELF_DIR/bin/leds" "$BIN_DST"
  ok "$BIN_DST"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) warn "~/.local/bin is not in PATH - add it to use the 'leds' command directly" ;;
  esac
}

write_config() {
  step "Configuration"
  mkdir -p "$CONFIG_DIR"
  if [ -f "$CONFIG_FILE" ]; then
    grep -q '^ON_COLOR='  "$CONFIG_FILE" && sed -i "s|^ON_COLOR=.*|ON_COLOR=\"$ON_COLOR\"|"   "$CONFIG_FILE" || echo "ON_COLOR=\"$ON_COLOR\"" >> "$CONFIG_FILE"
    grep -q '^ARGB_SIZE=' "$CONFIG_FILE" && sed -i "s|^ARGB_SIZE=.*|ARGB_SIZE=\"$ARGB_SIZE\"|" "$CONFIG_FILE" || echo "ARGB_SIZE=\"$ARGB_SIZE\"" >> "$CONFIG_FILE"
  else
    cat > "$CONFIG_FILE" <<EOF
# pc-leds configuration
ON_COLOR="$ON_COLOR"     # colour used by 'leds on' (RRGGBB)
ARGB_SIZE="$ARGB_SIZE"   # LEDs per addressable header (raise for long strips)
ARGB_ZONES=""            # optional explicit zone indexes, e.g. "0 1 2"
EOF
  fi
  ok "$CONFIG_FILE"
}

install_launchers() {
  [ "$DO_LAUNCHERS" = 1 ] || return 0
  step "Desktop launchers"
  local dd; dd="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  [ -n "$dd" ] && [ -d "$dd" ] || dd="$HOME/Desktop"
  mkdir -p "$dd" "$APP_DIR"
  local name action src
  for pair in "LEDs-OFF:off" "LEDs-ON:on"; do
    name="${pair%%:*}"; action="${pair##*:}"
    src="$SELF_DIR/data/${name}.desktop.in"
    sed -e "s|@LEDS@|$BIN_DST|g" -e "s|@ICON@|$ICON|g" "$src" > "$dd/${name}.desktop"
    chmod +x "$dd/${name}.desktop"
    cp -f "$dd/${name}.desktop" "$APP_DIR/${name}.desktop"
    command -v gio >/dev/null 2>&1 && gio set "$dd/${name}.desktop" metadata::trusted true 2>/dev/null || true
  done
  ok "launchers in $dd"
}

install_autostart() {
  [ "$DO_AUTOSTART" = 1 ] || return 0
  step "Login autostart (LEDs off by default)"
  mkdir -p "$AUTOSTART_DIR"
  sed -e "s|@LEDS@|$BIN_DST|g" "$SELF_DIR/data/leds-autostart.desktop.in" > "$AUTOSTART_DIR/leds-off.desktop"
  ok "$AUTOSTART_DIR/leds-off.desktop"
}

# ------------------------------------------------------------------- main ----
printf '%spc-leds installer%s\n' "$B" "$N"
ensure_openrgb
[ "$DO_UDEV" = 1 ] && install_udev
ensure_i2c_dev
[ "$DO_KPARAM" = 1 ] && add_kernel_param
install_cli
write_config
install_launchers
install_autostart

step "Applying (LEDs off)"
[ -x "$BIN_DST" ] && "$BIN_DST" off || warn "could not run leds off"

printf '\n%sDone.%s\n' "$B" "$N"
if [ "$REBOOT_NEEDED" = 1 ]; then
  printf '  %sReboot required%s for the SMBus change (RAM RGB) to take effect.\n' "$Y" "$N"
fi
printf '  Try:  leds off  |  leds on  |  leds status\n'
[ "$DO_AUTOSTART" = 1 ] && printf '  LEDs will now turn off automatically at each login.\n'
