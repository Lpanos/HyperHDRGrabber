#!/bin/bash
# Connects to an ADB device, runs scrcpy with v4l2 sink, and keeps the
# frame sustainer alive so HyperHDR sees a steady frame stream.
#
# Reads SHIELD_IP from /etc/default/hyperhdr-grabber (written by install.sh).

set -u

CONFIG_FILE="/etc/default/hyperhdr-grabber"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

if [[ -z "${SHIELD_IP:-}" ]]; then
    echo "SHIELD_IP not set. Edit $CONFIG_FILE." >&2
    exit 1
fi

# Append :5555 if user didn't include a port
if [[ "$SHIELD_IP" != *:* ]]; then
    SHIELD="${SHIELD_IP}:5555"
else
    SHIELD="$SHIELD_IP"
fi

ADB="${ADB:-/usr/local/bin/adb}"
SCRCPY="${SCRCPY:-/usr/local/bin/scrcpy}"
SUSTAINER="${SUSTAINER:-/usr/local/bin/frame-sustainer.py}"

pkill -f "frame-sustainer" 2>/dev/null
sleep 1

python3 "$SUSTAINER" &
SUSTAINER_PID=$!
trap 'kill "$SUSTAINER_PID" 2>/dev/null' EXIT

while true; do
    "$ADB" connect "$SHIELD" > /dev/null 2>&1
    sleep 2

    "$SCRCPY" -s "$SHIELD" \
        --no-audio --no-control --no-window \
        --v4l2-sink=/dev/video10 \
        --max-size=256 --max-fps=30 \
        --video-bit-rate=500K

    echo "$(date): scrcpy exited, reconnecting in 3s..."
    "$ADB" disconnect "$SHIELD" > /dev/null 2>&1
    sleep 3
done
