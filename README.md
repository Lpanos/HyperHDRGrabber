# HyperHDRGrabber

Wireless ambilight for any ADB-enabled Android device (Nvidia Shield, Fire TV, Android TV box, phone) feeding [HyperHDR](https://github.com/awawa-dev/HyperHDR) — without an HDMI capture card.

It captures the device's screen over ADB using `scrcpy`, pipes it through a small frame-sustainer so HyperHDR never sees "signal lost" during paused content, and hands a steady 30 fps video stream to HyperHDR for LED color sampling.

## Why this exists

Most ambilight setups need either an HDMI splitter + USB capture card, an HDR sync box (Hue Sync, etc.), or a TV with a vendor capture API. None of those work cleanly if:

- Your TV is a Samsung Tizen or other locked-down platform with no screen capture API.
- You want to ambilight content from native apps on a streamer (Stremio, Plex, Kodi on Shield/Fire TV) where HDMI splitters can't see the source.
- Android screen-grabber apps die the moment you switch apps — `MediaProjection` does not survive app switching on Android 11+.

This project solves it at the ADB layer: `scrcpy` injects via `app_process` as the `shell` user, completely outside the Android app lifecycle. Switching apps does **not** kill the capture.

## Architecture

```
ADB device (Shield TV / Fire TV / any ADB-enabled Android)
    │
    │  ADB over Ethernet (scrcpy, 256x144 @ 30fps, 500 kbps H.264)
    ▼
Linux host (ZimaBoard, mini-PC, anything with apt + Docker)
    │
    │  scrcpy ─────────────► /dev/video10 (v4l2loopback "scrcpy_raw")
    │                                │
    │                                ▼
    │  frame-sustainer.py reads video10, writes a steady 30 fps
    │                                │
    │                                ▼
    │  HyperHDR (Docker) reads ◄── /dev/video11 (v4l2loopback "ShieldCap")
    │
    │  WiFi/Ethernet (HyperHDR LED protocol)
    ▼
ESP32 / Raspberry Pi Pico W / any HyperHDR-compatible LED controller
    │
    ▼
Addressable LED strip (WS2812B, SK6812 RGBW, APA102, etc.)
```

Two v4l2loopback devices are required because v4l2loopback blocks readers when no writer is active. `/dev/video10` (scrcpy's output) blocks during pause. `/dev/video11` (sustainer's output) never blocks, because the sustainer always writes.

## Hardware

- Any ADB-enabled Android device (tested on Nvidia Shield TV Pro 2019, but Fire TV and Android TV boxes should work)
- A Linux host with a couple of GB free (ZimaBoard, mini-PC, NUC, Raspberry Pi 4/5 also fine — anything that runs Debian/Ubuntu)
- ESP32 or other HyperHDR-supported LED controller (Pi Pico W, Arduino with WLED+HyperSerial, etc.)
- An addressable LED strip + power supply sized for your LED count

Ethernet from the source device to your router is **strongly recommended**. WiFi ADB drops connections under continuous video streaming, even at 500 kbps.

## Quickstart

On your Linux host (Debian/Ubuntu):

```bash
git clone https://github.com/<your-user>/HyperHDRGrabber.git
cd HyperHDRGrabber
sudo ./install.sh
```

The installer will:

1. Install dependencies (`scrcpy` 3.3.4 built from source, latest `adb`, `v4l2loopback` from source, ffmpeg, python-opencv).
2. Configure `v4l2loopback` to create `/dev/video10` and `/dev/video11` at boot.
3. Drop `frame-sustainer.py` and `shield-grabber.sh` into `/usr/local/bin`.
4. Install and enable two systemd services.
5. Prompt you for your device's IP and write it to `/etc/default/hyperhdr-grabber`.

After install, pair ADB once (see [Pairing ADB](#pairing-adb)) and start the service:

```bash
sudo systemctl start shield-grabber
sudo systemctl status shield-grabber
```

Then point HyperHDR at `/dev/video11` — see [HyperHDR configuration](#hyperhdr-configuration) below.

## Pairing ADB

1. On your device: **Settings > Device Preferences > About > tap "Build" 7 times** to enable Developer Options.
2. **Settings > Device Preferences > Developer Options > Network debugging: ON**
3. **Developer Options > Wireless debugging > Pair device with pairing code** — note the IP, port, and 6-digit code on screen.
4. On the Linux host:
   ```bash
   adb pair <DEVICE_IP>:<PAIRING_PORT>   # enter the 6-digit code
   adb connect <DEVICE_IP>:5555
   adb devices                            # should show your device as "device"
   ```
5. Copy the ADB keys to root (so the systemd service can connect):
   ```bash
   sudo mkdir -p /root/.android
   sudo cp ~/.android/adbkey /root/.android/adbkey
   ```

## HyperHDR configuration

If you don't have HyperHDR running yet, here's a Docker command that works:

```bash
sudo docker run -d \
  --name hyperhdr \
  --privileged \
  --network host \
  --restart unless-stopped \
  --device /dev/video10:/dev/video10 \
  --device /dev/video11:/dev/video11 \
  -v /opt/hyperhdr:/root/.hyperhdr:rw \
  --security-opt label=disable \
  debian:bookworm-slim \
  bash -c "apt-get update && apt-get install -y curl wget ca-certificates procps && \
    URL=\$(curl -s https://api.github.com/repos/awawa-dev/HyperHDR/releases/tags/v22.0.0.0beta2 | \
    grep browser_download_url | grep bookworm | grep x86_64 | grep deb | head -n 1 | \
    cut -d '\"' -f 4) && wget -qO hyperhdr.deb \"\$URL\" && \
    apt-get install -y ./hyperhdr.deb && rm hyperhdr.deb && exec hyperhdr"
```

Then open the web UI at `http://<host-ip>:8090` and set:

**USB capture**
- Device: **ShieldCap (video11)** — *not* video10
- Resolution: `256 × 144`
- FPS: `30`
- Video format: `i420`
- Auto resume: `ON`
- Automatic signal detection: `OFF`
- Manual signal detection: `OFF`

**LED hardware**: pick whatever you're using (HyperK, WLED, etc.) and point it at your controller's IP.

**Smoothing**: `Continuous output: ON`.

**Background color**: black (minimises any flash during the rare dropout).

> If the HyperHDR UI loads as a blank gray page, clear cookies for the host's IP or use an incognito window — CasaOS and similar dashboards drop analytics cookies that corrupt HyperHDR's API responses.

## Changing the device IP later

```bash
sudo nano /etc/default/hyperhdr-grabber
sudo systemctl restart shield-grabber
```

## Uninstall

```bash
sudo ./uninstall.sh
```

Leaves the apt packages installed (they may be in use elsewhere) and does not touch your HyperHDR container.

## Troubleshooting

**HyperHDR doesn't see the ShieldCap device.** The frame sustainer must be actively writing to `/dev/video11` before HyperHDR will detect it. Check with `ps aux | grep frame-sustainer` and `journalctl -u shield-grabber -f`.

**LEDs flash on/off during paused content.** HyperHDR is pointed at video10 instead of video11. Switch the capture device in the HyperHDR settings to `ShieldCap (video11)`.

**LEDs go black after the device sleeps overnight and don't recover.** The system now auto-recovers: `frame-sustainer.py` has a 90-second watchdog — if no frame arrives from video10, it exits, which causes `shield-grabber.sh` to kill the stale scrcpy process and reconnect. Recovery takes up to ~100 seconds after the device wakes and accepts ADB again. If you want no gap at all, prevent the device from sleeping: on Shield TV, set **Settings > Device Preferences > Screen saver > Put device to sleep: Never** and **Energy saving > Turn off display: Never**.

**ADB shows "unauthorized" or won't connect after reboot.** The pairing was lost. Re-run `adb pair <IP>:<PORT>` (using a fresh code from the device) and `adb connect <IP>:5555`. Then re-copy `~/.android/adbkey` to `/root/.android/`.

**scrcpy disconnects every ~30s.** You're on WiFi. Move the source device to Ethernet — even 500 kbps over WiFi ADB drops under continuous streaming.

**`v4l2loopback` module fails to load after a kernel update.**
```bash
sudo apt install "linux-headers-$(uname -r)"
cd /tmp && git clone https://github.com/umlaeute/v4l2loopback.git && \
  cd v4l2loopback && make && sudo make install && sudo depmod -a
sudo modprobe v4l2loopback
```
Or just re-run `sudo ./install.sh` — it's idempotent.

**HyperHDR web UI is blank gray.** Clear cookies for the host IP, or use incognito. CasaOS / similar reverse-proxied dashboards can poison HyperHDR's HTTP responses.

## Key lessons learned (from the original troubleshooting)

1. **Samsung Tizen has no screen capture solution** except Philips' Hue Sync TV app (~$130). No sideloading, no community apps, no workarounds on Tizen 9.
2. **Android screen-grabber apps don't survive app switching.** `MediaProjection` dies on app switch; accessibility services can't see video surfaces. Only ADB-level capture (`scrcpy` via `app_process`) survives.
3. **The Tegra X1+ H.264 encoder stops sending frames on static content.** scrcpy's `repeat-previous-frame-after` option is silently ignored on this hardware. A frame-repeating intermediary (the sustainer) is the only fix.
4. **v4l2loopback blocks readers when no writer is active.** This is why two loopback devices are needed — scrcpy writes to one (may block during pause); the sustainer always writes to the other.
5. **scrcpy on Shield caps at 1080p** even with 4K output enabled. Irrelevant for ambilight — 256×144 is plenty for edge color sampling.
6. **WiFi ADB is fundamentally unreliable** for continuous video streaming. Even at 500 kbps the connection drops within ~35 seconds. Ethernet is required for a daily-driver setup.

## Project layout

```
HyperHDRGrabber/
├── README.md                          this file
├── LICENSE                            MIT
├── install.sh                         one-command installer (idempotent)
├── uninstall.sh                       removes everything install.sh adds
├── frame-sustainer.py                 30 fps frame repeater for v4l2
├── shield-grabber.sh                  scrcpy + sustainer launcher
└── systemd/
    ├── shield-grabber.service         main capture service
    └── hyperhdr-restart.service       restarts HyperHDR container after boot
```

## Contributing

This started as a personal setup and got cleaned up for publishing. PRs welcome — especially for:

- Testing on other ADB devices (Fire TV, Onn 4K Pro, Chromecast with Google TV, etc.)
- Non-Debian distros (Arch, Fedora) — the installer would need a different package layer
- Different LED controller setups (WLED, ESPHome, Diyhue)

## License

MIT — see [LICENSE](LICENSE).

## Credits

Built on top of:

- [scrcpy](https://github.com/Genymobile/scrcpy) by Genymobile
- [v4l2loopback](https://github.com/umlaeute/v4l2loopback) by umlaeute
- [HyperHDR](https://github.com/awawa-dev/HyperHDR) by awawa-dev

The novel piece here is the combination — and the frame sustainer that keeps the pipeline alive during paused content.
