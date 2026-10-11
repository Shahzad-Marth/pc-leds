#!/usr/bin/env bash
# =============================================================================
#  diagnose-smbus.sh - show whether the AMD FCH SMBus is bound (RAM RGB path)
# -----------------------------------------------------------------------------
#  Run as root:  sudo bash scripts/diagnose-smbus.sh
# =============================================================================
set -uo pipefail

echo "== kernel cmdline =="
grep -o 'acpi_enforce_resources=[^ ]*' /proc/cmdline || echo "  acpi_enforce_resources NOT set"

echo
echo "== i2c adapters =="
for a in /sys/bus/i2c/devices/i2c-*; do
  [ -e "$a/name" ] || continue
  printf '  %s: %s\n' "$(basename "$a")" "$(cat "$a/name")"
done

echo
echo "== AMD SMBus PCI device 00:14.0 =="
d=/sys/bus/pci/devices/0000:00:14.0
if [ -e "$d" ]; then
  printf '  class: %s\n' "$(cat "$d/class")"
  printf '  bound to: %s\n' "$(readlink -f "$d/driver" 2>/dev/null || echo "(unbound)")"
else
  echo "  not present"
fi

echo
echo "== recent SMBus / ACPI resource warnings =="
dmesg 2>/dev/null | grep -iE 'piix4|smbus|OpRegion|Resource conflict' | tail -15 || echo "  (dmesg not readable)"

echo
echo "If 00:14.0 is unbound and you see a 'Resource conflict' with OpRegion"
echo "\\GSA1.SMBI, add the kernel parameter:  acpi_enforce_resources=lax"
echo "  sudo grubby --update-kernel=ALL --args=\"acpi_enforce_resources=lax\""
echo "  sudo systemctl reboot"
