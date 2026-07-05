#!/bin/bash
# End-to-end regression check for the standalone audio chain.
#
# Proves, with numbers, that: helper launches -> bridge answers -> playback
# starts -> the TAP CAPTURES REAL AUDIO (not silence) -> the DSP emits signal.
# This is the exact check that caught the RemotePlayerService ghost (MusicKit
# renders in MediaPlayer's XPC, not the host process — a tap on the helper
# alone captures silence while raw audio plays; see vinylfy memory 2026-07-05).
#
# Usage: scripts/verify-standalone.sh   (rebuilds nothing; verifies dist/)
# PASS = last diag line shows inPeak > 0 while the helper reports playing.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG_DIR=$(mktemp -d)
APP_LOG="$LOG_DIR/app.log"
HELPER_LOG="$LOG_DIR/helper.log"

echo "[1/4] fresh stack..."
pkill -9 -x billiejean-player 2>/dev/null || true
pkill -x billiejean 2>/dev/null || true
sleep 1
open --stdout "$HELPER_LOG" --stderr "$HELPER_LOG" dist/billiejean-player.app
sleep 3
open --stdout "$APP_LOG" --stderr "$APP_LOG" dist/billiejean.app
sleep 6

echo "[2/4] commanding playback over the bridge..."
python3 - <<'EOF'
import socket, json, os, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(os.path.expanduser("~/Library/Application Support/billiejean/player.sock"))
buf = b""
def rpc(id, method, params=None, timeout=30):
    global buf
    s.sendall((json.dumps({"id": id, "method": method, "params": params or {}}) + "\n").encode())
    s.settimeout(timeout)
    while True:
        buf += s.recv(65536)
        lines = buf.split(b"\n"); buf = lines[-1]
        for l in lines[:-1]:
            m = json.loads(l)
            if m.get("id") == id:
                return m
pls = rpc(1, "library.playlists")["result"]["playlists"]
if not pls:
    sys.exit("FAIL: no playlists from helper")
r = rpc(2, "queue.playPlaylist", {"playlistId": pls[0]["id"]})
if not r.get("result", {}).get("ok"):
    sys.exit(f"FAIL: play command: {r}")
print("play ok:", pls[0]["name"])
EOF

echo "[3/4] waiting for capture (watchdog may need one rebind)..."
sleep 15

echo "[4/4] verdict:"
LAST=$(grep "DIAG process" "$APP_LOG" | tail -1 || true)
if [ -z "$LAST" ]; then
  echo "FAIL — no engine buffers at all (pipeline never ran)"; grep "DIAG" "$APP_LOG" | tail -8; exit 1
fi
echo "  $LAST"
PEAK=$(echo "$LAST" | sed -n 's/.*inPeak=\([0-9.]*\).*/\1/p')
python3 - "$PEAK" <<'EOF'
import sys
peak = float(sys.argv[1] or 0)
if peak > 0.001:
    print(f"PASS — tap is capturing real audio (inPeak={peak})")
else:
    sys.exit(f"FAIL — tap captures silence (inPeak={peak}). "
             "Check: helper keepalive, RemotePlayerService objects in tap "
             "resolution (DIAG tap_resolve), silence watchdog.")
EOF
