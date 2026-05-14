#!/usr/bin/env bash
# Removes everything install.sh put in place. Does NOT uninstall apt packages
# (they may be used by other things), and does NOT touch your HyperHDR
# container.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

echo "==> Stopping and disabling services..."
systemctl disable --now shield-grabber.service 2>/dev/null || true
systemctl disable --now hyperhdr-restart.service 2>/dev/null || true

echo "==> Removing files..."
rm -f /etc/systemd/system/shield-grabber.service
rm -f /etc/systemd/system/hyperhdr-restart.service
rm -f /usr/local/bin/frame-sustainer.py
rm -f /usr/local/bin/shield-grabber.sh
rm -f /etc/modules-load.d/v4l2loopback.conf
rm -f /etc/modprobe.d/v4l2loopback.conf
rm -f /etc/default/hyperhdr-grabber

systemctl daemon-reload

echo "==> Unloading v4l2loopback (will reload empty on next boot)..."
modprobe -r v4l2loopback 2>/dev/null || true

echo "Done. apt packages (scrcpy, v4l2loopback, adb, ffmpeg, python3-opencv)"
echo "were left installed. Remove manually if you no longer need them."
