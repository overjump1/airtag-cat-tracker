#!/usr/bin/env python3
"""
AirTag Cat-Tracker PoC
──────────────────────
Triggers AirTag sound and shows approximate proximity via Bluetooth RSSI.
Runs on (or connected via USB to) a jailbroken iPhone 8.

Usage:
  python3 controller.py            # terminal UI, iPhone over USB
  python3 controller.py --local    # terminal UI, run directly on iPhone
  python3 controller.py --server   # HTTP server on localhost:8765 (for iOS app)
  python3 controller.py --server --local

Prerequisites on the iPhone:
  • frida-server running as root (install via Sileo/Cydia from the Frida repo)
  • AirTag paired to the iPhone's Apple ID
"""

import frida
import sys
import time
import math
import threading
import os
import select
import tty
import termios

SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "airtag_hook.js")

# ── Distance model ────────────────────────────────────────────────────────────
# iPhone 8 has no UWB — we use a log-distance path loss model with BLE RSSI.
# RSSI_1M: measured RSSI at exactly 1 m (calibrate once with your phone+tag).
# PATH_N:  path loss exponent — 2.0 = open air, 2.7 = typical indoor.
RSSI_1M = -59
PATH_N  = 2.7

def rssi_to_meters(rssi: int) -> float:
    return 10 ** ((RSSI_1M - rssi) / (10.0 * PATH_N))

def proximity_bar(dist: float | None) -> tuple[str, str]:
    if dist is None:
        return "unknown   ", "·····"
    if dist < 1.0:
        return "immediate ", "█████"
    if dist < 3.0:
        return "near      ", "████░"
    if dist < 7.0:
        return "same room ", "███░░"
    if dist < 15.0:
        return "far room  ", "██░░░"
    return "far away  ", "█░░░░"


# ── Frida bridge ──────────────────────────────────────────────────────────────
class AirTagBridge:
    def __init__(self, use_usb: bool = True):
        self._api   = None
        self._use_usb = use_usb
        self._rssi  = None
        self._rssi_age_ms = None

    def connect(self) -> dict:
        try:
            device = (frida.get_usb_device(timeout=5)
                      if self._use_usb
                      else frida.get_local_device())
        except frida.InvalidArgumentError:
            raise RuntimeError(
                "No USB device found.\n"
                "  • Check the cable, or run with --local on the iPhone itself."
            )

        print(f"[+] Device: {device.name}")

        # locationd manages all CoreLocation + Find My / AirTag activity
        session = device.attach("locationd")

        with open(SCRIPT_PATH) as f:
            source = f.read()

        script = session.create_script(source)
        script.on("message", self._on_message)
        script.load()
        self._api = script.exports_sync

        result = self._api.setup()
        print(f"[+] Hooks: {result}")
        return result

    def _on_message(self, message, _data):
        if message.get("type") == "error":
            # Print but don't crash — hook errors are non-fatal for the PoC
            print(f"\n[frida] {message.get('description', message)}")

    # ── Controls ──────────────────────────────────────────────────────────────
    def is_ready(self) -> bool:
        return bool(self._api and self._api.is_ready())

    def play_sound(self):
        if not self._api:
            raise RuntimeError("Not connected")
        return self._api.play_sound()

    def stop_sound(self):
        if not self._api:
            raise RuntimeError("Not connected")
        return self._api.stop_sound()

    # ── RSSI polling ──────────────────────────────────────────────────────────
    def poll_rssi(self):
        """
        Trigger a new readRSSI on the iPhone and return the latest cached value.
        readRSSI() is async — the JS hook captures the callback and stores the
        value; we retrieve it 150 ms later (enough for one BLE round-trip).
        """
        if not self._api:
            return None, None
        self._api.request_rssi()
        time.sleep(0.15)
        result = self._api.get_rssi()
        self._rssi = result.get("rssi")
        self._rssi_age_ms = result.get("age_ms")
        return self._rssi, self._rssi_age_ms


# ── Terminal helpers ──────────────────────────────────────────────────────────
def getch_noblock() -> str | None:
    """Return a single keypress if one is waiting, else None."""
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        rlist, _, _ = select.select([sys.stdin], [], [], 0)
        if rlist:
            return sys.stdin.read(1)
        return None
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


# ── Main loop ─────────────────────────────────────────────────────────────────
HELP = (
    "  [s] play sound    [x] stop sound    [q] quit\n"
    "  (press a key; display refreshes every second)\n"
)

BANNER = r"""
   _   _      _____              ____       ____
  / \ (_) _ _|_   _|_ _  __ _  |  _ \ ___ / ___|
 / _ \| || '_|| || _` |/ _` | | |_) / _ \ |
/ ___ \ || |  | || (_| | (_| | |  __/ (_) | |___
/_/   \_\|_|  |_| \__,_|\__, | |_|   \___/ \____|
                         |___/   Cat Tracker PoC
"""

def main():
    use_usb = "--local" not in sys.argv
    bridge  = AirTagBridge(use_usb=use_usb)

    print(BANNER)
    print("Connecting to Frida on the iPhone…")
    try:
        bridge.connect()
    except Exception as e:
        print(f"[!] {e}")
        sys.exit(1)

    if not bridge.is_ready():
        print(
            "\n[!] DurianService not captured yet.\n"
            "    ─ Open Find My → your AirTag → 'Play Sound'\n"
            "    ─ Once it beeps, this script takes over.\n"
            "    Waiting up to 60 s…",
            end="", flush=True,
        )
        for _ in range(60):
            time.sleep(1)
            print(".", end="", flush=True)
            if bridge.is_ready():
                print(" ✓")
                break
        else:
            print("\n[!] Timed out. Ensure Find My is open and you tapped Play Sound.")
            sys.exit(1)

    print(f"\n{HELP}")

    sound_playing = False

    while True:
        key = getch_noblock()
        if key == "s":
            bridge.play_sound()
            sound_playing = True
            print("\r[→] Sound ON                                        ")
        elif key == "x":
            bridge.stop_sound()
            sound_playing = False
            print("\r[→] Sound OFF                                       ")
        elif key == "q":
            bridge.stop_sound()
            print("\r[→] Bye.                                            ")
            sys.exit(0)

        rssi, age_ms = bridge.poll_rssi()
        dist  = rssi_to_meters(rssi) if rssi is not None else None
        label, bar = proximity_bar(dist)

        rssi_str = f"{rssi:+d} dBm" if rssi is not None else "   --- dBm"
        dist_str = f"{dist:5.1f} m"  if dist is not None else "   ---  "
        age_str  = f"({age_ms/1000:.0f}s ago)" if age_ms is not None else "        "
        snd_str  = "♪ SOUND ON " if sound_playing else "           "

        sys.stdout.write(
            f"\r  {bar}  {label}  RSSI {rssi_str}  ~{dist_str}  {age_str}  {snd_str}"
        )
        sys.stdout.flush()


# ── HTTP server mode (for the iOS app) ───────────────────────────────────────
class DaemonServer:
    """
    Thin HTTP wrapper around AirTagBridge.  The iOS app calls:
      GET  /status  → {"ready": bool}
      GET  /rssi    → {"rssi": int|null, "age_ms": int|null}
      POST /play    → {"ok": true}
      POST /stop    → {"ok": true}
    """

    def __init__(self, bridge: AirTagBridge, port: int = 8765):
        self._bridge = bridge
        self._port   = port
        self._lock   = threading.Lock()
        self._rssi: int | None = None
        self._age:  int | None = None

    def _poll_loop(self):
        while True:
            try:
                rssi, age = self._bridge.poll_rssi()
                with self._lock:
                    self._rssi = rssi
                    self._age  = age
            except Exception:
                pass
            time.sleep(1.0)

    def run(self):
        import json
        from http.server import HTTPServer, BaseHTTPRequestHandler

        parent = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass   # suppress access log

            def _send_json(self, data: dict):
                body = json.dumps(data).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path == "/status":
                    self._send_json({"ready": parent._bridge.is_ready()})
                elif self.path == "/rssi":
                    with parent._lock:
                        self._send_json({"rssi": parent._rssi, "age_ms": parent._age})
                else:
                    self.send_response(404); self.end_headers()

            def do_POST(self):
                if self.path == "/play":
                    parent._bridge.play_sound()
                    self._send_json({"ok": True})
                elif self.path == "/stop":
                    parent._bridge.stop_sound()
                    self._send_json({"ok": True})
                else:
                    self.send_response(404); self.end_headers()

        threading.Thread(target=self._poll_loop, daemon=True).start()
        httpd = HTTPServer(("127.0.0.1", self._port), Handler)
        print(f"[+] HTTP server listening on http://127.0.0.1:{self._port}")
        print("    Open AirTagCat on the iPhone — it will connect automatically.")
        httpd.serve_forever()


def run_server(bridge: AirTagBridge):
    """Wait for DurianService, then start the HTTP daemon."""
    if not bridge.is_ready():
        print(
            "\n[!] DurianService not captured yet.\n"
            "    → Open Find My → your AirTag → 'Play Sound' once.\n"
            "    Waiting up to 60 s…",
            end="", flush=True,
        )
        for _ in range(60):
            time.sleep(1)
            print(".", end="", flush=True)
            if bridge.is_ready():
                print(" ✓")
                break
        else:
            print("\n[!] Timed out waiting for DurianService.")
            sys.exit(1)

    DaemonServer(bridge).run()


if __name__ == "__main__":
    server_mode = "--server" in sys.argv
    if server_mode:
        use_usb = "--local" not in sys.argv
        bridge  = AirTagBridge(use_usb=use_usb)
        print("=== AirTag daemon (server mode) ===")
        print("Connecting to Frida…")
        try:
            bridge.connect()
        except Exception as e:
            print(f"[!] {e}")
            sys.exit(1)
        run_server(bridge)
    else:
        main()
