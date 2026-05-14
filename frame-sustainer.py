#!/usr/bin/env python3
"""
Reads frames from /dev/video10 (scrcpy output) and writes them at a steady 30fps
to /dev/video11 (HyperHDR input). When scrcpy stops sending frames (paused
content on Tegra X1+ etc.), we keep pushing the last frame so HyperHDR never
declares "signal lost".
"""
import cv2
import time
import subprocess
import sys
import threading
import numpy as np

INPUT = "/dev/video10"
OUTPUT = "/dev/video11"
WIDTH = 256
HEIGHT = 144
FPS = 30
INTERVAL = 1.0 / FPS

last_frame = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
lock = threading.Lock()


def reader_thread():
    global last_frame
    while True:
        try:
            cap = cv2.VideoCapture(INPUT, cv2.CAP_V4L2)
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, WIDTH)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, HEIGHT)

            if not cap.isOpened():
                time.sleep(2)
                continue

            print("Reader connected to", INPUT, flush=True)
            while True:
                ret, frame = cap.read()
                if ret and frame is not None:
                    with lock:
                        last_frame = frame
                else:
                    break

            cap.release()
            print("Reader lost", INPUT, "retrying...", flush=True)
            time.sleep(1)
        except Exception as e:
            print(f"Reader error: {e}", flush=True)
            time.sleep(2)


reader = threading.Thread(target=reader_thread, daemon=True)
reader.start()

print("Starting ffmpeg writer with black frames", flush=True)

ffmpeg = subprocess.Popen([
    'ffmpeg', '-y', '-loglevel', 'quiet',
    '-f', 'rawvideo', '-pix_fmt', 'bgr24',
    '-s', f'{WIDTH}x{HEIGHT}', '-r', str(FPS),
    '-i', 'pipe:0',
    '-pix_fmt', 'yuv420p',
    '-f', 'v4l2', OUTPUT
], stdin=subprocess.PIPE)

print(f"Frame sustainer running at {FPS}fps", flush=True)

while True:
    start = time.monotonic()

    with lock:
        frame = last_frame

    try:
        ffmpeg.stdin.write(frame.tobytes())
    except BrokenPipeError:
        print("ffmpeg pipe broken, exiting", flush=True)
        sys.exit(1)

    elapsed = time.monotonic() - start
    sleep_time = INTERVAL - elapsed
    if sleep_time > 0:
        time.sleep(sleep_time)
