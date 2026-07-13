#!/usr/bin/env python3
"""
led_udp_bridge.py (Raspberry Pi 5 / Pi5Neo-Variante)

Nimmt WLED-kompatible "DRGB"-Realtime-UDP-Pakete entgegen (Standardprotokoll,
das auch LedFx fuer WLED-Geraete verwendet) und steuert damit direkt einen
WS281x/NeoPixel-LED-Streifen ueber SPI am Raspberry Pi 5 (Pi5Neo).

Hintergrund: rpi_ws281x unterstuetzt den Pi 5 (BCM2712 / RP1-I/O-Chip) nicht,
da die Bibliothek auf PWM/DMA-Register zugreift, die es beim Pi 5 so nicht
mehr gibt. Pi5Neo nutzt stattdessen die Hardware-SPI-Schnittstelle.

DRGB-Paketformat: [Timeout-Byte] [R G B] [R G B] ... (ein Byte-Triplet pro LED)

Verkabelung (anders als bei der alten GPIO18/PWM-Variante fuer Pi <5):
  LED-Streifen DIN  -> GPIO10 / MOSI (Pin 19)
  LED-Streifen GND  -> Pi GND (z.B. Pin 6) UND gemeinsame Masse mit
                        externem Netzteil, falls verwendet
  LED-Streifen 5V   -> externes 5V-Netzteil (oder fuer ganz kurze Tests mit
                        wenigen LEDs bei reduzierter Helligkeit: Pi-5V-Pin -
                        siehe README.md fuer Details/Grenzen)

Voraussetzung: SPI muss aktiviert sein (macht install.sh automatisch):
  sudo raspi-config -> 3 Interface Options -> I4 SPI -> Yes

Laeuft als root (fuer SPI-Device-Zugriff), gestartet ueber
systemd/led-udp-bridge.service (wird von install.sh generiert).
"""

import socket
import sys

from pi5neo import Pi5Neo, EPixelType

# --- Konfiguration: an eigene Hardware anpassen ---
LED_COUNT = 15                  # Anzahl LEDs im Streifen
SPI_DEVICE = "/dev/spidev0.0"   # SPI0, CE0 - Standard fuer GPIO10/MOSI
SPI_SPEED_KHZ = 800             # 800 kHz, Standardtiming fuer WS2812B
PIXEL_TYPE = EPixelType.GRB     # WS2812B nutzt GRB-Kanalreihenfolge
LED_BRIGHTNESS = 50             # 0-255, wird hier per Skalierung angewendet

UDP_IP = "0.0.0.0"
UDP_PORT = 21324                # Standard-DRGB-Port, in LedFx als "Port" eintragen


def scale(value: int) -> int:
    """Skaliert einen 0-255 Farbwert auf die konfigurierte Helligkeit."""
    return (value * LED_BRIGHTNESS) // 255


def main():
    neo = Pi5Neo(SPI_DEVICE, num_leds=LED_COUNT, spi_speed_khz=SPI_SPEED_KHZ,
                 pixel_type=PIXEL_TYPE, quiet_mode=True)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((UDP_IP, UDP_PORT))
    print(f"led_udp_bridge: lausche auf {UDP_IP}:{UDP_PORT}, "
          f"{LED_COUNT} LEDs an {SPI_DEVICE} (Pi5Neo)")

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
                neo.set_led_color(i, scale(r), scale(g), scale(b))

            # sleep_duration=None: keine kuenstliche 100ms-Latch-Pause pro
            # Frame - sonst ist die reale Update-Rate auf ~10 fps begrenzt,
            # egal wie schnell LedFx Pakete schickt.
            neo.update_strip(sleep_duration=None)
    except KeyboardInterrupt:
        pass
    finally:
        neo.clear_strip()
        neo.update_strip()
        neo.close()
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
