#!/bin/bash
# Connects to an ADB device, runs scrcpy with v4l2 sink, and keeps the
# frame sustainer alive so HyperHDR sees a steady frame stream.
#
# Reads SHIELD_IP from /etc/default/hyperhdr-grabber (written by install.sh).
#
# Recovery: if the sustainer's watchdog fires (no frames for 90s — device
# went to sleep), it exits, which causes this script to kill the stale scrcpy
# process and reconnect rather than hanging indefinitely.

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

SCRCPY_PID=""
SUSTAINER_PID=""

cleanup() {
    [[ -n "$SCRCPY_PID" ]] && kill "$SCRCPY_PID" 2>/dev/null
    [[ -n "$SUSTAINER_PID" ]] && kill "$SUSTAINER_PID" 2>/dev/null
}
trap cleanup EXIT

start_sustainer() {
    pkill -f "frame-sustainer" 2>/dev/null
    sleep 1
    python3 "$SUSTAINER" &
    SUSTAINER_PID=$!
    echo "$(date): frame-sustainer started (PID $SUSTAINER_PID)"
}

start_sustainer

while true; do
    "$ADB" connect "$SHIELD" > /dev/null 2>&1
    sleep 2

    "$SCRCPY" -s "$SHIELD" \
        --no-audio --no-control --no-window \
        --v4l2-sink=/dev/video10 \
        --max-size=256 --max-fps=30 \
        --video-bit-rate=500K &
    SCRCPY_PID=$!

    # Wait until scrcpy dies (normal) or the sustainer watchdog exits (device slept)
    while kill -0 "$SCRCPY_PID" 2>/dev/null && kill -0 "$SUSTAINER_PID" 2>/dev/null; do
        sleep 5
    done

    kill "$SCRCPY_PID" 2>/dev/null
    wait "$SCRCPY_PID" 2>/dev/null
    "$ADB" disconnect "$SHIELD" > /dev/null 2>&1

    # If the sustainer exited (watchdog fired), restart it before reconnecting
    if ! kill -0 "$SUSTAINER_PID" 2>/dev/null; then
        echo "$(date): sustainer watchdog triggered — device probably slept; restarting..."
        wait "$SUSTAINER_PID" 2>/dev/null
        start_sustainer
    fi

    echo "$(date): reconnecting in 3s..."
    sleep 3
done
