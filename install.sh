#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AirTag Cat Tracker PoC — setup helper
#
# RUN THIS ON YOUR MAC (not on the iPhone).
# The controller.py runs on the Mac over USB; Frida server runs on the iPhone.
#
# OR: to run everything ON the iPhone itself:
#   1. SSH into your iPhone (ssh root@<phone-ip>)
#   2. pip3 install frida  (after installing Python 3 from Sileo/Procursus)
#   3. python3 controller.py --local
# ─────────────────────────────────────────────────────────────────────────────

set -e

echo "=== AirTag PoC — setup ==="

# ── 1. Python deps ────────────────────────────────────────────────────────────
echo "[1/3] Installing Python dependencies…"
pip3 install -r requirements.txt

# ── 2. Check frida-server on iPhone ──────────────────────────────────────────
echo "[2/3] Checking for iPhone over USB…"
if ! python3 -c "import frida; d = frida.get_usb_device(timeout=3); print('  Found:', d.name)" 2>/dev/null; then
  echo "  [!] No iPhone found via USB."
  echo "      • Connect the iPhone with a cable."
  echo "      • Make sure frida-server is installed on the iPhone:"
  echo "          Sileo/Cydia → add repo https://build.frida.re → install Frida"
  echo "      • Start it:  ssh root@<phone-ip> 'frida-server &'"
  exit 1
fi

# ── 3. Done ───────────────────────────────────────────────────────────────────
echo "[3/3] All set."
echo ""
echo "  Run:  python3 controller.py"
echo ""
echo "  First-run checklist:"
echo "    ✓ iPhone connected via USB"
echo "    ✓ frida-server running on iPhone as root"
echo "    ✓ AirTag paired to the iPhone's Apple ID"
echo "    ✓ After script starts, open Find My → your AirTag → Play Sound ONCE"
echo "      to let the hook capture the DurianService."
echo "    ✓ Then press [s] to trigger sound, [x] to stop, [q] to quit."
