#!/usr/bin/env python3
"""
led_udp_bridge.py

Nimmt WLED-kompatible "DRGB"-Realtime-UDP-Pakete entgegen (Standardprotokoll,
das auch LedFx fuer WLED-Geraete verwendet) und steuert damit direkt einen
WS281x/NeoPixel-LED-Streifen ueber GPIO am Raspberry Pi (rpi_ws281x).

DRGB-Paketformat: [Timeout-Byte] [R G B] [R G B] ... (ein Byte-Triplet pro LED)

Muss als root laufen (PWM/GPIO-Zugriff). Wird ueber
systemd/led-udp-bridge.service gestartet.
"""

import socket
import sys

from rpi_ws281x import Color, PixelStrip

# --- Konfiguration: an eigene Hardware anpassen ---
LED_COUNT = 150        # Anzahl LEDs im Streifen
LED_PIN = 18            # GPIO18 (PWM0)
LED_FREQ_HZ = 800000
LED_DMA = 10
LED_BRIGHTNESS = 200     # 0-255
LED_INVERT = False
LED_CHANNEL = 0

UDP_IP = "0.0.0.0"
UDP_PORT = 21324         # Standard-DRGB-Port, in LedFx als "Port" eintragen


def main():
    strip = PixelStrip(
        LED_COUNT, LED_PIN, LED_FREQ_HZ, LED_DMA, LED_INVERT, LED_BRIGHTNESS, LED_CHANNEL
    )
    strip.begin()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((UDP_IP, UDP_PORT))
    print(f"led_udp_bridge: lausche auf {UDP_IP}:{UDP_PORT}, {LED_COUNT} LEDs an GPIO{LED_PIN}")

    try:
        while True:
            data, _addr = sock.recvfrom(65535)
            if len(data) < 2:
                continue

            # erstes Byte = Timeout-Sekunden (DRGB-Protokoll), Rest = RGB-Triplets
            payload = data[1:]
            pixel_count = min(LED_COUNT, len(payload) // 3)

            for i in range(pixel_count):
                r, g, b = payload[i * 3 : i * 3 + 3]
                strip.setPixelColor(i, Color(r, g, b))

            strip.show()
    except KeyboardInterrupt:
        pass
    finally:
        for i in range(LED_COUNT):
            strip.setPixelColor(i, Color(0, 0, 0))
        strip.show()
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
