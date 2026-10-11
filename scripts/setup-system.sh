#!/usr/bin/env bash
# =============================================================================
#  pc-leds system setup  (run as root)
# -----------------------------------------------------------------------------
#  Distro-aware provisioning of everything that needs root:
#     * OpenRGB            native RPM/DEB if available for this distro+version,
#                          otherwise the official AppImage extracted to /opt
#     * GUI toolkit        GTK4 + PyGObject + libadwaita (for pc-leds-gui)
#     * OpenRGB udev rules
#     * i2c-dev module
#     * kernel parameter   acpi_enforce_resources=lax  (AMD SMBus / RAM RGB)
#
#  Called by install.sh (via sudo) and by the GUI (via pkexec).
#  Idempotent. Exit code 10 means: a reboot is required.
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_UDEV=1
DO_KPARAM=1
DO_DEPS=1

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '%sERROR:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-udev)        DO_UDEV=0; shift ;;
    --no-kernel-param) DO_KPARAM=0; shift ;;
    --no-deps)        DO_DEPS=0; shift ;;
    -h|--help)
      cat <<EOF
pc-leds system setup (root)
  --no-udev          skip OpenRGB udev rules
  --no-kernel-param  skip acpi_enforce_resources=lax
  --no-deps          skip GUI dependency packages
EOF
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "this script must run as root (use sudo or pkexec)"

. /etc/os-release 2>/dev/null || true
DISTRO="${ID:-}"; VER="${VERSION_ID:-}"; ARCH="$(uname -m)"
DISTRO_LIKE=" ${ID:-} ${ID_LIKE:-} "

pkg_install() {   # install one of the given package names with the native manager
  local p
  for p in "$@"; do
    if command -v dnf >/dev/null 2>&1; then dnf install -y "$p" && return 0
    elif command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" && return 0
    elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm --needed "$p" && return 0
    elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install -y "$p" && return 0
    fi
  done
  return 1
}

# ------------------------------------------------------------- GUI toolkit ---
ensure_gui_deps() {
  [ "$DO_DEPS" = 1 ] || return 0
  step "GUI toolkit (GTK4 + PyGObject + libadwaita)"
  local py=""
  for cand in /usr/bin/python3 /usr/local/bin/python3 python3; do
    command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ] || continue
    "$cand" - <<'PY' >/dev/null 2>&1 && { py="$cand"; break; }
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw
PY
  done
  if [ -n "$py" ]; then ok "already available ($py)"; return 0; fi
  warn "installing GTK/PyGObject packages"
  if   [ -n "${ID_LIKE##*fedora*}" ] || [ "$DISTRO" = fedora ] || [ "$DISTRO" = rhel ] || [ "$DISTRO" = centos ]; then
        pkg_install gtk4 libadwaita python3-gobject || warn "could not install GTK packages"
  elif [ -n "${DISTRO_LIKE##*debian*}" ] || [ "$DISTRO" = debian ] || [ "$DISTRO" = ubuntu ] || [ -n "${DISTRO_LIKE##*ubuntu*}" ]; then
        pkg_install gir1.2-gtk-4.0 gir1.2-adw-1 python3-gi || warn "could not install GTK packages"
  elif [ "$DISTRO" = arch ] || [ -n "${DISTRO_LIKE##*arch*}" ]; then
        pkg_install gtk4 libadwaita python-gobject || warn "could not install GTK packages"
  else
        pkg_install gtk4 libadwaita python3-gobject || warn "install GTK4 + PyGObject manually"
  fi
}

# --------------------------------------------------------------- OpenRGB -----
pick_asset_url() {   # arch distro version -> URL on stdout
  python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null
import sys, json, urllib.request
arch, distro, ver = sys.argv[1], sys.argv[2], sys.argv[3]
want = {"x86_64":"x86_64","amd64":"x86_64","aarch64":"arm64",
        "armv7l":"armhf","i686":"i386"}.get(arch, arch)
try:
    req = urllib.request.Request(
        "https://api.github.com/repos/CalcProgrammer1/OpenRGB/releases/latest",
        headers={"User-Agent": "pc-leds-setup"})
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

install_appimage() {  # $1 = AppImage file
  local app="$1" dest=/opt/openrgb
  chmod +x "$app"
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && "$app" --appimage-extract >/dev/null 2>&1 ) || { rm -rf "$tmp"; return 1; }
  rm -rf "$dest"
  mv "$tmp/squashfs-root" "$dest"
  rm -rf "$tmp"
  cat > /usr/local/bin/openrgb <<EOF
#!/bin/sh
exec /opt/openrgb/AppRun "\$@"
EOF
  chmod +x /usr/local/bin/openrgb
  return 0
}

ensure_openrgb() {
  step "OpenRGB"
  if command -v openrgb >/dev/null 2>&1; then ok "already installed: $(command -v openrgb)"; return 0; fi
  local url fname tmp ext; url="$(pick_asset_url "$ARCH" "$DISTRO" "$VER")"
  [ -n "$url" ] || { warn "no OpenRGB build found for ${ARCH}/${DISTRO:-unknown}"; return 1; }
  fname="$(basename "$url")"; tmp="$(mktemp -d)"; ext="${fname##*.}"
  info "downloading $fname"
  if ! curl -fsSL "$url" -o "$tmp/$fname"; then warn "download failed"; rm -rf "$tmp"; return 1; fi
  case "$ext" in
    rpm) if dnf install -y "$tmp/$fname"; then ok "installed (rpm)"; rm -rf "$tmp"; return 0; fi
         warn "rpm install failed - falling back to AppImage" ;;
    deb) if DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/$fname"; then ok "installed (deb)"; rm -rf "$tmp"; return 0; fi
         warn "deb install failed - falling back to AppImage" ;;
  esac
  # AppImage fallback (also the generic path)
  if [ "$ext" != "AppImage" ]; then
    local ai; ai="$(basename "$(pick_asset_url "$ARCH" generic "$VER")")"
    if [ -n "$ai" ]; then curl -fsSL "$(pick_asset_url "$ARCH" generic "$VER")" -o "$tmp/$ai" || true; fi
    [ -f "$tmp/$ai" ] && { install_appimage "$tmp/$ai" && { ok "installed (AppImage -> /opt/openrgb)"; rm -rf "$tmp"; return 0; }; }
  else
    install_appimage "$tmp/$fname" && { ok "installed (AppImage -> /opt/openrgb)"; rm -rf "$tmp"; return 0; }
  fi
  rm -rf "$tmp"
  warn "could not install OpenRGB automatically"
  return 1
}

# ------------------------------------------------------------------ udev -----
install_udev() {
  step "OpenRGB udev rules"
  if [ -f /etc/udev/rules.d/60-openrgb.rules ] || [ -f /usr/lib/udev/rules.d/60-openrgb.rules ]; then
    ok "already present"; udevadm control --reload-rules 2>/dev/null; udevadm trigger 2>/dev/null; return 0
  fi
  local rules="" tmp; tmp="$(mktemp)"
  if command -v openrgb >/dev/null 2>&1; then
    if openrgb --help 2>&1 | grep -q -- '--generate-udev-rules'; then
      openrgb --generate-udev-rules "$tmp" >/dev/null 2>&1 && [ -s "$tmp" ] && rules="$tmp"
    elif openrgb --help 2>&1 | grep -q -- '--print-udev-rules'; then
      openrgb --print-udev-rules > "$tmp" 2>/dev/null && [ -s "$tmp" ] && rules="$tmp"
    fi
  fi
  if [ -z "$rules" ]; then
    local cand
    for cand in /opt/openrgb/usr/lib/udev/rules.d/60-openrgb.rules \
                /usr/lib/udev/rules.d/60-openrgb.rules \
                /usr/share/openrgb/60-openrgb.rules \
                "$HOME/Applications/OpenRGB/usr/lib/udev/rules.d/60-openrgb.rules"; do
      [ -f "$cand" ] && rules="$cand" && break
    done
  fi
  if [ -z "$rules" ]; then
    # last resort: fetch from the OpenRGB source tree
    curl -fsSL "https://gitlab.com/CalcProgrammer1/OpenRGB/-/raw/master/60-openrgb.rules" -o "$tmp" 2>/dev/null && [ -s "$tmp" ] && rules="$tmp"
  fi
  rm -f "$tmp"
  [ -n "$rules" ] || { warn "could not obtain udev rules - devices may need root"; return 0; }
  install -Dm644 "$rules" /etc/udev/rules.d/60-openrgb.rules
  udevadm control --reload-rules 2>/dev/null
  udevadm trigger 2>/dev/null
  ok "installed /etc/udev/rules.d/60-openrgb.rules"
}

# --------------------------------------------------------------- i2c-dev -----
ensure_i2c_dev() {
  step "i2c-dev module"
  modprobe i2c-dev 2>/dev/null || true
  local t; t="$(mktemp)"; echo i2c-dev > "$t"
  install -Dm644 "$t" /etc/modules-load.d/pc-leds.conf
  rm -f "$t"
  ok "enabled"
}

# --------------------------------------------------------- kernel parameter --
add_kernel_param() {
  step "Kernel parameter: acpi_enforce_resources=lax"
  if grep -q 'acpi_enforce_resources=lax' /proc/cmdline; then ok "already active"; return 0; fi
  if command -v grubby >/dev/null 2>&1; then
    if grubby --info=ALL 2>/dev/null | grep -q 'acpi_enforce_resources=lax'; then
      ok "already configured in bootloader"; REBOOT=1
    elif grubby --update-kernel=ALL --args="acpi_enforce_resources=lax"; then
      ok "added (via grubby)"; REBOOT=1
    fi
  elif [ -f /etc/default/grub ]; then
    if grep -q 'acpi_enforce_resources=lax' /etc/default/grub; then
      ok "already configured"; REBOOT=1
    else
      cp /etc/default/grub /etc/default/grub.pc-leds.bak
      sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 acpi_enforce_resources=lax"/' /etc/default/grub
      if command -v update-grub >/dev/null 2>&1; then update-grub; elif command -v grub-mkconfig >/dev/null 2>&1; then grub-mkconfig -o /boot/grub/grub.cfg; fi
      ok "added to GRUB"; REBOOT=1
    fi
  else
    warn "could not configure the bootloader; add 'acpi_enforce_resources=lax' manually"
  fi
}

# ------------------------------------------------------------------- run -----
REBOOT=0
ensure_gui_deps
ensure_openrgb || warn "OpenRGB not installed - run this again once you have it"
[ "$DO_UDEV" = 1 ] && install_udev
ensure_i2c_dev
[ "$DO_KPARAM" = 1 ] && add_kernel_param

if [ "$REBOOT" = 1 ]; then
  printf '\n%sSystem setup done - reboot required.%s\n' "$B" "$N"
  exit 10
fi
printf '\n%sSystem setup done.%s\n' "$B" "$N"
exit 0
