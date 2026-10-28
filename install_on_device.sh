#!/bin/sh
# Run this ONCE on the jailbroken iPhone (via SSH or a terminal app like NewTerm).
# After this, the daemon starts automatically on every boot — no PC needed.
#
# Prerequisites (install via Sileo before running this):
#   • Python3          — search "python3" in Sileo
#   • Frida            — add https://build.frida.re, then install "Frida"
#   • frida (Python)   — after Frida is installed: pip3 install frida
#
# Usage:
#   ssh root@<iphone-ip>
#   sh install_on_device.sh

set -e

DEST=/var/mobile/airtagcat
PLIST=/Library/LaunchDaemons/com.local.airtagcat.daemon.plist
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[1/4] Installing Python frida module..."
pip3 install --quiet frida

echo "[2/4] Copying files to $DEST ..."
mkdir -p "$DEST"
cp "$SCRIPT_DIR/controller.py"   "$DEST/"
cp "$SCRIPT_DIR/airtag_hook.js"  "$DEST/"
chmod +x "$DEST/controller.py"

echo "[3/4] Installing LaunchDaemon..."
cp "$SCRIPT_DIR/com.local.airtagcat.daemon.plist" "$PLIST"
chmod 644 "$PLIST"
chown root:wheel "$PLIST"

echo "[4/4] Loading daemon (no reboot needed this time)..."
launchctl load -w "$PLIST" 2>/dev/null || true
launchctl start com.local.airtagcat.daemon 2>/dev/null || true

echo ""
echo "Done! Daemon is running on http://127.0.0.1:8765"
echo "Logs: tail -f $DEST/daemon.log"
echo ""
echo "Next: open Find My → your AirTag → Play Sound once."
echo "That primes the hook. After that, the AirTagCat app controls everything."
