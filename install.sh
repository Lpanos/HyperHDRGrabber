#!/usr/bin/env bash
# HyperHDRGrabber installer.
# Targets Debian/Ubuntu. Idempotent: safe to re-run.

set -euo pipefail

SCRCPY_VERSION="v3.3.4"
CONFIG_FILE="/etc/default/hyperhdr-grabber"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- helpers --------------------------------------------------------------

c() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
info() { echo "$(c "1;34" "==>") $*"; }
ok()   { echo "$(c "1;32" " ok") $*"; }
warn() { echo "$(c "1;33" "warn") $*" >&2; }
err()  { echo "$(c "1;31" "err ") $*" >&2; exit 1; }

# ---- preflight ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

command -v apt-get >/dev/null || err "This installer requires apt (Debian/Ubuntu)."

# ---- config: SHIELD_IP ----------------------------------------------------

SHIELD_IP="${SHIELD_IP:-}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

if [[ -z "${SHIELD_IP:-}" ]]; then
    echo
    echo "Enter the IP address of your ADB-enabled device (e.g. Nvidia Shield)."
    echo "If you don't include a port, :5555 will be appended."
    read -rp "Device IP: " SHIELD_IP < /dev/tty
    [[ -z "$SHIELD_IP" ]] && err "Device IP is required."
fi

# ---- apt dependencies -----------------------------------------------------

info "Installing apt dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    android-tools-adb ffmpeg python3-opencv python3-numpy \
    gcc git pkg-config meson ninja-build \
    libsdl2-dev libavcodec-dev libavdevice-dev libavformat-dev \
    libavutil-dev libswresample-dev libusb-1.0-0-dev \
    "linux-headers-$(uname -r)" \
    wget unzip ca-certificates

# ---- ADB (latest from Google's platform-tools) ----------------------------

current_adb_major=0
if command -v /usr/local/bin/adb >/dev/null; then
    current_adb_major="$(/usr/local/bin/adb version 2>/dev/null | awk '/Version/{print $5}' | cut -d. -f1)"
fi
if [[ "${current_adb_major:-0}" -ge 35 ]]; then
    ok "Modern ADB already installed ($(/usr/local/bin/adb version | head -1))"
else
    info "Installing latest ADB (platform-tools)..."
    tmp="$(mktemp -d)"
    wget -qO "$tmp/platform-tools.zip" \
        https://dl.google.com/android/repository/platform-tools-latest-linux.zip
    unzip -q "$tmp/platform-tools.zip" -d "$tmp"
    install -m755 "$tmp/platform-tools/adb" /usr/local/bin/adb
    install -m755 "$tmp/platform-tools/fastboot" /usr/local/bin/fastboot
    rm -rf "$tmp"
    ok "ADB installed: $(/usr/local/bin/adb version | head -1)"
fi

# ---- scrcpy ---------------------------------------------------------------

current_scrcpy="$(scrcpy --version 2>/dev/null | head -1 | awk '{print $2}' || true)"
want_scrcpy="${SCRCPY_VERSION#v}"
if [[ "$current_scrcpy" == "$want_scrcpy" ]]; then
    ok "scrcpy $want_scrcpy already installed"
else
    info "Building scrcpy $SCRCPY_VERSION from source..."
    tmp="$(mktemp -d)"
    git clone --depth 1 --branch "$SCRCPY_VERSION" \
        https://github.com/Genymobile/scrcpy "$tmp/scrcpy"
    (cd "$tmp/scrcpy" && ./install_release.sh)
    rm -rf "$tmp"
    ok "scrcpy $(scrcpy --version | head -1)"
fi

# ---- v4l2loopback ---------------------------------------------------------

v4l2_version="$(modinfo v4l2loopback 2>/dev/null | awk '/^version:/{print $2}' || true)"
need_v4l2_build=true
if [[ -n "$v4l2_version" && ! "$v4l2_version" =~ ^0\.12\. ]]; then
    need_v4l2_build=false
fi

if $need_v4l2_build; then
    info "Building v4l2loopback from source..."
    apt-get remove -y -qq v4l2loopback-dkms 2>/dev/null || true
    tmp="$(mktemp -d)"
    git clone --depth 1 https://github.com/umlaeute/v4l2loopback.git "$tmp/v4l2loopback"
    (cd "$tmp/v4l2loopback" && make && make install)
    depmod -a
    rm -rf "$tmp"
    ok "v4l2loopback built and installed"
else
    ok "v4l2loopback already current (version $v4l2_version)"
fi

# ---- v4l2loopback config + load ------------------------------------------

info "Configuring v4l2loopback persistence..."
echo "v4l2loopback" > /etc/modules-load.d/v4l2loopback.conf
cat > /etc/modprobe.d/v4l2loopback.conf <<'EOF'
options v4l2loopback devices=2 video_nr=10,11 card_label="scrcpy_raw","ShieldCap" exclusive_caps=1,1
EOF

info "Reloading v4l2loopback module..."
modprobe -r v4l2loopback 2>/dev/null || true
modprobe v4l2loopback
[[ -e /dev/video10 && -e /dev/video11 ]] || err "v4l2loopback did not create /dev/video10 and /dev/video11"
ok "/dev/video10 (scrcpy_raw) and /dev/video11 (ShieldCap) ready"

# ---- install scripts ------------------------------------------------------

info "Installing scripts to /usr/local/bin..."
install -m755 "$REPO_DIR/frame-sustainer.py" /usr/local/bin/frame-sustainer.py
install -m755 "$REPO_DIR/shield-grabber.sh"  /usr/local/bin/shield-grabber.sh

# ---- write config ---------------------------------------------------------

info "Writing $CONFIG_FILE..."
umask 022
cat > "$CONFIG_FILE" <<EOF
# HyperHDRGrabber configuration. Edit and restart shield-grabber to apply.
# Format: hostname or IP, with optional :port (default :5555).
SHIELD_IP="$SHIELD_IP"
EOF

# ---- ADB key for root -----------------------------------------------------

USER_HOME=""
if [[ -n "${SUDO_USER:-}" ]]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi
if [[ -n "$USER_HOME" && -f "$USER_HOME/.android/adbkey" ]]; then
    info "Copying ADB key from $USER_HOME/.android/ to /root/.android/..."
    mkdir -p /root/.android
    cp "$USER_HOME/.android/adbkey" /root/.android/adbkey
    cp "$USER_HOME/.android/adbkey.pub" /root/.android/adbkey.pub 2>/dev/null || true
    chmod 600 /root/.android/adbkey
fi

# ---- systemd units --------------------------------------------------------

info "Installing systemd units..."
install -m644 "$REPO_DIR/systemd/shield-grabber.service"   /etc/systemd/system/shield-grabber.service
install -m644 "$REPO_DIR/systemd/hyperhdr-restart.service" /etc/systemd/system/hyperhdr-restart.service
systemctl daemon-reload
systemctl enable shield-grabber.service >/dev/null
systemctl enable hyperhdr-restart.service >/dev/null

# ---- done -----------------------------------------------------------------

cat <<EOF

$(c "1;32" "Installation complete.")

Next steps:

  1. On your device, enable ADB network debugging:
       Settings > Device Preferences > Developer Options > Network debugging

  2. Pair ADB (first time only):
       On device: Developer Options > Wireless debugging > Pair
       Then on this box:
         adb pair $SHIELD_IP:<PAIRING_PORT>
         adb connect $SHIELD_IP:5555
         sudo cp ~/.android/adbkey /root/.android/adbkey

  3. Start the grabber:
       sudo systemctl start shield-grabber
       sudo systemctl status shield-grabber

  4. Configure HyperHDR (web UI, default port 8090):
       USB Capture device: ShieldCap (video11)  [NOT video10]
       Resolution: 256x144, FPS: 30, format: i420
       Auto resume: ON, Signal detection: OFF
       Smoothing > Continuous output: ON

See README.md for the HyperHDR Docker run command and troubleshooting.
EOF
