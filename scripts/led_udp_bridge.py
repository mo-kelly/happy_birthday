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

NEU - Sync-Delay: Bluetooth-Audio (SBC + Funk + Speaker-DSP) hat typischerweise
150-250ms Latenz. Die LED-Bridge selbst reagiert dagegen fast latenzfrei auf
denselben Loopback-Ton. Ohne Ausgleich blitzen die LEDs also hoerbar VOR dem
Ton auf. Deshalb werden ankommende Pakete hier erst nach DELAY_MS auf den
Strip geschrieben (Producer/Consumer ueber eine Queue mit Zeitstempel).

Kalibrierung von DELAY_MS:
  1. Handy-Kamera im Slow-Motion-Modus auf Lautsprecher UND LED-Strip richten.
  2. Einen kurzen, klar abgegrenzten Beat/Klick abspielen (z.B. Metronom-Sample).
  3. Im Slow-Mo-Video den Frame-Abstand zwischen LED-Aufblitzen und Ton am
     Lautsprecher messen (Frameanzahl / fps der Kamera = Millisekunden).
  4. DELAY_MS auf diesen gemessenen Wert setzen, Dienst neu starten, erneut
     testen und bei Bedarf nachjustieren (+/- 20-30ms Feintuning nach Gehoer).

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

import queue
import signal
import socket
import subprocess
import sys
import threading
import time

from pi5neo import Pi5Neo, EPixelType

# --- Konfiguration: an eigene Hardware anpassen ---
LED_COUNT = 15                  # Anzahl LEDs im Streifen
SPI_DEVICE = "/dev/spidev0.0"   # SPI0, CE0 - Standard fuer GPIO10/MOSI
SPI_SPEED_KHZ = 800             # 800 kHz, Standardtiming fuer WS2812B
PIXEL_TYPE = EPixelType.RGB     # keine automatische Umsortierung durch Pi5Neo -
                                 # wir tauschen R/B unten selbst (siehe scale/main),
                                 # da dieser Streifen "BGR"-Kanalreihenfolge nutzt,
                                 # was Pi5Neo nicht direkt als Option anbietet
LED_BRIGHTNESS = 50             # 0-255, wird hier per Skalierung angewendet

UDP_IP = "0.0.0.0"
UDP_PORT = 21324                # Standard-DRGB-Port, in LedFx als "Port" eintragen

# Verzoegerung, um LEDs an die Bluetooth-Audio-Latenz anzugleichen. Siehe
# Kalibrierungs-Hinweis oben im Modul-Docstring. 0 = altes Verhalten
# (keine Verzoegerung, z.B. bei kabelgebundenem USB-DAC ohne BT-Latenz).
DELAY_MS = 180

# Maximale Queue-Groesse als Sicherheitsnetz, falls DELAY_MS sehr hoch
# gesetzt wird oder die Consumer-Seite mal ins Stocken geraet - verhindert
# unbegrenztes Speicherwachstum, verwirft im Zweifel die aeltesten Frames.
MAX_QUEUE_SIZE = 500

# --- Bose-Box: Verbindungsversuch beim Start ---
# Setzt voraus, dass die Box bereits einmalig manuell gekoppelt/getrustet
# wurde (siehe README.md, Abschnitt "Bluetooth-Kopfhoerer als Ausgabe" -
# gleiches Vorgehen, nur mit dieser MAC-Adresse statt der Kopfhoerer).
BOSE_MAC = "04:52:C7:D3:C4:D2"     # Bose Mini II SE SoundLink
BOSE_CONNECT_RETRIES = 10
BOSE_CONNECT_RETRY_DELAY_S = 3


def scale(value: int) -> int:
    """Skaliert einen 0-255 Farbwert auf die konfigurierte Helligkeit."""
    return (value * LED_BRIGHTNESS) // 255


class ShutdownSignal(Exception):
    """Wird ausgeloest, wenn systemd das Script per SIGTERM stoppt (z.B. beim
    Herunterfahren des Pi). Ohne diesen Handler faengt Python nur SIGINT
    (Strg+C) automatisch als KeyboardInterrupt ab - SIGTERM wuerde den
    Prozess sonst sofort und ohne den finally-Block (LEDs ausschalten) beenden."""


def _handle_sigterm(signum, frame):
    raise ShutdownSignal()


def startup_animation(neo: Pi5Neo) -> None:
    """
    Signalisiert Einsatzbereitschaft: LEDs leuchten einmal nacheinander auf
    (Lauflicht, bleiben dabei an), halten kurz alle zusammen, dann aus.
    Nutzt Gruen, da das unabhaengig von der R/B-Vertauschung (siehe
    PIXEL_TYPE oben) immer korrekt angezeigt wird.
    """
    ready_color = (0, scale(255), 0)  # (r, g, b) - hier bereits fertig fuer set_led_color

    for i in range(LED_COUNT):
        neo.set_led_color(i, *ready_color)
        neo.update_strip(sleep_duration=None)
        time.sleep(0.06)

    time.sleep(0.4)  # kurz alle zusammen halten

    neo.clear_strip()
    neo.update_strip()


def shutdown_animation(neo: Pi5Neo) -> None:
    """
    Genaue Umkehrung von startup_animation(): erst alle LEDs zusammen an,
    kurz halten, dann nacheinander in umgekehrter Reihenfolge (letzte zuerst)
    wieder aus - egal, welche Farbe der Streifen vorher gerade zeigte.
    """
    ready_color = (0, scale(255), 0)

    for i in range(LED_COUNT):
        neo.set_led_color(i, *ready_color)
    neo.update_strip(sleep_duration=None)

    time.sleep(0.4)  # kurz alle zusammen halten

    for i in range(LED_COUNT - 1, -1, -1):
        neo.set_led_color(i, 0, 0, 0)
        neo.update_strip(sleep_duration=None)
        time.sleep(0.06)

    neo.clear_strip()
    neo.update_strip()


def connect_bose() -> bool:
    """
    Versucht, sich mit der bereits getrusteten Bose-Box zu verbinden
    (bluetoothctl connect). Retried mit fester Verzoegerung, z.B. weil die
    Box beim Boot des Pi noch nicht eingeschaltet oder nicht in Reichweite
    ist. Gibt True zurueck, sobald "Connection successful" o.ae. kommt,
    sonst False nach Ausschoepfen der Versuche.

    Laeuft bewusst NICHT beim allerersten Pairing (dafuer braucht es einen
    physischen Knopfdruck an der Box) - das einmalige pair/trust erledigt
    man manuell, siehe README.md.
    """
    for attempt in range(1, BOSE_CONNECT_RETRIES + 1):
        result = subprocess.run(
            ["bluetoothctl", "connect", BOSE_MAC],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode == 0 and "Connection successful" in result.stdout:
            print(f"connect_bose: verbunden ({BOSE_MAC}), Versuch {attempt}")
            return True

        print(f"connect_bose: Versuch {attempt}/{BOSE_CONNECT_RETRIES} "
              f"fehlgeschlagen, warte {BOSE_CONNECT_RETRY_DELAY_S}s...")
        time.sleep(BOSE_CONNECT_RETRY_DELAY_S)

    print("connect_bose: Bose-Box nicht erreichbar, gebe auf.")
    return False


def confirmation_flash(neo: Pi5Neo, times: int = 2) -> None:
    """
    Kurzes Aufblitzen ALLER LEDs zusammen (kein Lauflicht wie bei
    startup_animation), als Bestaetigung fuer "Bose-Box erfolgreich
    verbunden". Laeuft direkt im Anschluss an startup_animation().
    """
    flash_color = (0, scale(255), 0)

    for _ in range(times):
        for i in range(LED_COUNT):
            neo.set_led_color(i, *flash_color)
        neo.update_strip(sleep_duration=None)
        time.sleep(0.15)

        neo.clear_strip()
        neo.update_strip(sleep_duration=None)
        time.sleep(0.15)


def _consumer(neo: Pi5Neo, frame_queue: "queue.Queue[tuple[float, bytes]]",
              stop_event: threading.Event) -> None:
    """
    Liest (Ankunftszeit, Rohdaten)-Paare aus der Queue und wartet jeweils,
    bis DELAY_MS seit der Ankunft vergangen sind, bevor der Frame auf den
    Strip geschrieben wird. So laeuft die LED-Ausgabe synchron mit dem
    zeitversetzten Bluetooth-Ton statt dem Ton vorauszueilen.
    """
    delay = DELAY_MS / 1000.0

    while not stop_event.is_set():
        try:
            arrival_time, payload = frame_queue.get(timeout=0.5)
        except queue.Empty:
            continue

        target_time = arrival_time + delay
        remaining = target_time - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)

        pixel_count = min(LED_COUNT, len(payload) // 3)
        for i in range(pixel_count):
            r, g, b = payload[i * 3: i * 3 + 3]
            # R und B vertauscht senden (BGR-Streifen, siehe PIXEL_TYPE oben)
            neo.set_led_color(i, scale(b), scale(g), scale(r))

        # sleep_duration=None: keine kuenstliche 100ms-Latch-Pause pro
        # Frame - sonst ist die reale Update-Rate auf ~10 fps begrenzt,
        # egal wie schnell LedFx Pakete schickt.
        neo.update_strip(sleep_duration=None)


def main():
    signal.signal(signal.SIGTERM, _handle_sigterm)

    neo = Pi5Neo(SPI_DEVICE, num_leds=LED_COUNT, spi_speed_khz=SPI_SPEED_KHZ,
                 pixel_type=PIXEL_TYPE, quiet_mode=True)

    startup_animation(neo)

    if connect_bose():
        confirmation_flash(neo)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((UDP_IP, UDP_PORT))
    print(f"led_udp_bridge: lausche auf {UDP_IP}:{UDP_PORT}, "
          f"{LED_COUNT} LEDs an {SPI_DEVICE} (Pi5Neo), Sync-Delay={DELAY_MS}ms")

    frame_queue: "queue.Queue[tuple[float, bytes]]" = queue.Queue(maxsize=MAX_QUEUE_SIZE)
    stop_event = threading.Event()
    consumer_thread = threading.Thread(
        target=_consumer, args=(neo, frame_queue, stop_event), daemon=True
    )
    consumer_thread.start()

    try:
        while True:
            data, _addr = sock.recvfrom(65535)
            if len(data) < 2:
                continue

            # erstes Byte = Timeout-Sekunden (DRGB-Protokoll), Rest = RGB-Triplets
            payload = data[1:]
            arrival_time = time.monotonic()

            try:
                frame_queue.put_nowait((arrival_time, payload))
            except queue.Full:
                # Sicherheitsnetz: bei Ueberlastung aeltesten Frame verwerfen
                # statt unbegrenzt zu wachsen oder zu blockieren.
                try:
                    frame_queue.get_nowait()
                except queue.Empty:
                    pass
                frame_queue.put_nowait((arrival_time, payload))
    except (KeyboardInterrupt, ShutdownSignal):
        pass
    finally:
        stop_event.set()
        consumer_thread.join(timeout=2)
        shutdown_animation(neo)
        neo.close()
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
