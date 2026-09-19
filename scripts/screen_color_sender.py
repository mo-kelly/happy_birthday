#!/usr/bin/env python3
"""Send screen colors to the Pi LED bridge using WLED DRGB packets.

Run this on the computer that displays the movie. The Raspberry Pi only needs
the existing led_udp_bridge.py service; this script sends one RGB color for
each LED based on the corresponding vertical slice of the selected monitor.
"""

import argparse
import socket
import time
from typing import Iterable


def _clamp_channel(value: float) -> int:
    return max(0, min(255, round(value)))


def _blend(previous: tuple[int, int, int], current: tuple[int, int, int], amount: float) -> tuple[int, int, int]:
    return tuple(
        _clamp_channel(old + (new - old) * amount)
        for old, new in zip(previous, current)
    )


def _dominant_color(image) -> tuple[int, int, int]:
    """Choose a vivid, common color while avoiding black movie bars."""
    quantized = image.quantize(colors=8, method=2)
    colors = quantized.getcolors(maxcolors=8)
    if not colors:
        return (0, 0, 0)

    palette = quantized.getpalette()
    candidates = []
    for count, palette_index in colors:
        offset = palette_index * 3
        red, green, blue = palette[offset:offset + 3]
        brightness = max(red, green, blue) / 255
        saturation = (max(red, green, blue) - min(red, green, blue)) / 255
        score = count * (0.35 + saturation) * (0.5 + brightness)
        candidates.append((score, (red, green, blue)))
    return max(candidates, key=lambda item: item[0])[1]


def colors_from_frame(frame, led_count: int, crop_ratio: float = 0.08) -> list[tuple[int, int, int]]:
    """Map monitor columns to LED colors using small, fast image samples."""
    width, height = frame.size
    crop_height = int(height * crop_ratio)
    if crop_height * 2 >= height:
        crop_height = 0
    frame = frame.crop((0, crop_height, width, height - crop_height))

    colors = []
    for led_index in range(led_count):
        left = led_index * width // led_count
        right = (led_index + 1) * width // led_count
        sample = frame.crop((left, 0, max(left + 1, right), frame.height))
        sample.thumbnail((24, 16))
        colors.append(_dominant_color(sample))
    return colors


def drgb_packet(colors: Iterable[tuple[int, int, int]]) -> bytes:
    """Build a WLED DRGB packet: timeout byte followed by RGB triplets."""
    payload = bytearray((0,))
    for red, green, blue in colors:
        payload.extend((_clamp_channel(red), _clamp_channel(green), _clamp_channel(blue)))
    return bytes(payload)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pi", required=True, help="Raspberry Pi hostname or IP address")
    parser.add_argument("--port", type=int, default=21324)
    parser.add_argument("--leds", type=int, default=15)
    parser.add_argument("--monitor", type=int, default=1, help="mss monitor number (1 is the first display)")
    parser.add_argument("--fps", type=float, default=15.0)
    parser.add_argument("--smooth", type=float, default=0.35, help="new-frame weight from 0 to 1")
    parser.add_argument("--crop", type=float, default=0.08, help="top/bottom crop fraction for letterbox bars")
    parser.add_argument("--once", action="store_true", help="send one frame and exit")
    parser.add_argument("--dry-run", action="store_true", help="capture and print one frame without sending")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.leds < 1 or args.fps <= 0 or not 0 <= args.smooth <= 1 or not 0 <= args.crop < 0.5:
        raise SystemExit("leds must be positive, fps must be > 0, smooth must be 0..1, crop must be 0..0.5")

    try:
        from mss import mss
        from PIL import Image
    except ImportError as error:
        raise SystemExit("Install screen sender dependencies with: python -m pip install -r requirements-screen.txt") from error

    with mss() as capture:
        monitors = capture.monitors
        if args.monitor >= len(monitors):
            raise SystemExit(f"monitor {args.monitor} not found; available monitors: 1-{len(monitors) - 1}")

        monitor = monitors[args.monitor]
        target = (args.pi, args.port)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        previous = [(0, 0, 0)] * args.leds
        interval = 1 / args.fps

        try:
            while True:
                shot = capture.grab(monitor)
                frame = Image.frombytes("RGB", shot.size, shot.rgb)
                current = colors_from_frame(frame, args.leds, args.crop)
                smoothed = [_blend(old, new, args.smooth) for old, new in zip(previous, current)]
                packet = drgb_packet(smoothed)

                if args.dry_run:
                    print(smoothed)
                    return
                sock.sendto(packet, target)
                previous = smoothed
                if args.once:
                    return
                time.sleep(interval)
        finally:
            sock.close()


if __name__ == "__main__":
    main()