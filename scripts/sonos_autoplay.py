#!/usr/bin/env python3
"""
sonos_autoplay.py

Sucht per SoCo (SSDP-Discovery) periodisch nach Sonos-Lautsprechern im
selben LAN und weist neu gefundene Geraete an, den lokalen Icecast-
Audiostream (aus lan-audio-bridge.service, siehe README.md/install.sh)
abzuspielen.

Zweck: aktuell dient das MacBook (per LAN verbunden) nur zum Testen des
Streams (URL im Browser/VLC/mpv oeffnen). Sobald stattdessen ein Sonos-
Lautsprecher an dasselbe Netzwerk angeschlossen wird, soll er automatisch
und ohne manuelle Konfiguration den Stream abspielen ("Sonos einstecken,
fertig") - genau das macht dieses Script.

Laeuft dauerhaft ueber systemd/sonos-autoplay.service (wird von install.sh
generiert). Bereits bekannte/spielende Geraete werden nicht erneut
angestossen, damit z.B. ein manuelles Pausieren durch den Nutzer nicht
sofort wieder ueberschrieben wird - nur neu auftauchende Geraete werden
automatisch gestartet.
"""

import argparse
import logging
import sys
import time

try:
    import soco
except ImportError:
    print("Fehlt: pip install soco --break-system-packages", file=sys.stderr)
    raise

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s sonos_autoplay: %(message)s",
)
log = logging.getLogger(__name__)

DISCOVERY_INTERVAL_SEC = 15  # wie oft nach (neuen) Sonos-Geraeten gesucht wird


def discover_and_play(stream_url: str, known_uids: set, stream_title: str) -> set:
    """Sucht Sonos-Geraete im LAN, spielt auf neuen Geraeten den Stream ab.

    Gibt die aktualisierte Menge bereits bekannter Geraete-UIDs zurueck.
    """
    try:
        devices = soco.discover(timeout=5)
    except Exception as exc:  # SoCo wirft je nach Netzwerkzustand Diverses
        log.warning("Discovery fehlgeschlagen: %s", exc)
        return known_uids

    if not devices:
        return known_uids

    for device in devices:
        if device.uid in known_uids:
            continue  # schon bekannt/gestartet - nicht erneut anstossen

        try:
            device.play_uri(uri=stream_url, title=stream_title)
            log.info(
                "Neuer Sonos-Lautsprecher gefunden: %s (%s) -> spiele %s",
                device.player_name, device.ip_address, stream_url,
            )
        except Exception as exc:
            log.warning(
                "Konnte Stream auf %s (%s) nicht starten: %s",
                device.player_name, device.ip_address, exc,
            )
            continue  # bei Fehler nicht als "bekannt" markieren, naechster Zyklus versucht's erneut

        known_uids.add(device.uid)

    return known_uids


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--stream-url",
        required=True,
        help="URL des Icecast-Streams, z.B. http://<host>.local:8000/stream.mp3",
    )
    parser.add_argument(
        "--stream-title",
        default="ELEMAX",
        help="Titel, der auf dem Sonos-Display/in der App angezeigt wird",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=DISCOVERY_INTERVAL_SEC,
        help="Sekunden zwischen Discovery-Durchlaeufen",
    )
    args = parser.parse_args()

    log.info(
        "Starte Sonos-Autoplay: suche alle %ss nach neuen Sonos-Geraeten, "
        "Ziel-Stream: %s", args.interval, args.stream_url,
    )

    known_uids: set = set()
    while True:
        known_uids = discover_and_play(args.stream_url, known_uids, args.stream_title)
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
