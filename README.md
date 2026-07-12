# happy_birthday – Raspberry Pi als Spotify-Connect-Lautsprecher mit LedFx-Steuerung

Sample-Repo zum manuellen Kopieren auf einen Raspberry Pi. Der Pi erscheint im Netzwerk als **Spotify-Connect-Lautsprecher** (via `librespot`) und steuert gleichzeitig einen **WS281x-LED-Streifen** über **LedFx** audioreaktiv. Die physische Audioausgabe (USB-DAC oder Netzwerk/LAN-Ziel) lässt sich manuell umschalten.

## Architektur

```
Spotify-App  ---(Spotify Connect)--->  librespot  --->  ALSA "default"
                                                            |
                                                    (Tee-Split via
                                                     ALSA multi-Plugin)
                                                    /               \
                                       physische Ausgabe        Loopback-Device
                                    (USB-DAC  oder  LAN/Pulse)   (snd-aloop)
                                                                       |
                                                                    LedFx
                                                              (Audio-Analyse)
                                                                       |
                                                          UDP-Bridge (DRGB, lokal)
                                                                       |
                                                            WS281x-LED-Streifen (GPIO18)
```

- **librespot** meldet den Pi als Spotify-Connect-Gerät an und gibt Audio über ALSA aus.
- Ein **ALSA "multi"-Tee** dupliziert das Audiosignal gleichzeitig auf die echte Ausgabe und ein `snd-aloop`-Loopback-Device.
- **LedFx** liest das Loopback-Device als Audioquelle aus und berechnet daraus Lichteffekte.
- LedFx sendet die Effekte per lokalem UDP (WLED-kompatibles DRGB-Protokoll) an eine kleine Python-Bridge (`scripts/led_udp_bridge.py`), die den LED-Streifen direkt über GPIO18 mit `rpi_ws281x` ansteuert. Das umgeht Versionsunterschiede von LedFx bzgl. nativer GPIO-Unterstützung und ist die stabilste Variante.
- Die physische Audio-Ausgabe (USB-DAC lokal, oder Streaming an ein Netzwerkziel per PulseAudio/LAN) wird manuell per Script umgeschaltet, siehe unten.

## Hardware

- Raspberry Pi (empfohlen: Pi 3B+/4, funktioniert aber auch auf älteren Modellen)
- WS281x/WS2812B/NeoPixel-LED-Streifen
- Eigenes 5V-Netzteil für den LED-Streifen (nicht über den Pi versorgen)
- Logic-Level-Shifter 3.3V → 5V für die Datenleitung (empfohlen, nicht zwingend bei kurzen Kabeln)
- Optional: USB-DAC/USB-Soundkarte für bessere Audioqualität als der interne Klinkenausgang

### Verkabelung LED-Streifen

| LED-Streifen | Pi          |
|---------------|-------------|
| 5V            | externes Netzteil (5V) |
| GND           | externes Netzteil GND **und** Pi GND (gemeinsame Masse!) |
| DIN (Data)    | GPIO18 (Pin 12), idealerweise über Level-Shifter |

## Verzeichnisstruktur

```
happy_birthday/
├── README.md
├── install.sh                     # Setup-Script, auf dem Pi ausführen
├── config/
│   ├── asound.conf.template       # ALSA-Basis-Config mit Platzhalter für physische Ausgabe
│   ├── physical-usb.conf.snippet  # physische Ausgabe: USB-DAC
│   ├── physical-lan.conf.snippet  # physische Ausgabe: Netzwerk/LAN (PulseAudio-Ziel)
│   ├── librespot.env              # Konfiguration für librespot (Gerätename etc.)
│   └── ledfx_config.yaml          # LedFx-Grundkonfiguration (Loopback als Audioquelle)
├── systemd/
│   ├── librespot.service
│   ├── ledfx.service
│   └── led-udp-bridge.service
├── scripts/
│   ├── switch-audio-output.sh     # manuelles Umschalten USB <-> LAN
│   └── led_udp_bridge.py          # UDP(DRGB) -> GPIO WS281x Bridge
└── .gitignore
```

## Installation auf dem Pi

1. Repo-Inhalt manuell auf den Pi kopieren, z.B. per `scp -r happy_birthday/ pi@<IP>:~/` oder USB-Stick.
2. Auf dem Pi einloggen und ausführen:

   ```bash
   cd ~/happy_birthday
   chmod +x install.sh scripts/*.sh scripts/*.py
   sudo ./install.sh
   ```

   Das Script installiert `librespot`, Python/`ledfx`, `rpi_ws281x`, aktiviert das `snd-aloop`-Kernelmodul, kopiert die systemd-Units und aktiviert die Dienste.

3. Audioausgabe wählen (siehe nächster Abschnitt).
4. Pi neu starten: `sudo reboot`

Nach dem Neustart erscheint der Pi in Spotify unter dem in `config/librespot.env` konfigurierten Gerätenamen, und der LED-Streifen reagiert auf die Musik.

## Audioausgabe manuell umschalten (USB oder LAN)

Standardmäßig ist **USB** aktiv. Wechseln mit:

```bash
sudo ./scripts/switch-audio-output.sh usb --card 1          # USB-DAC, Kartenindex mit `aplay -l` ermitteln
sudo ./scripts/switch-audio-output.sh lan --server 192.168.1.50  # Ziel-PulseAudio-Server im LAN
```

Das Script schreibt `/etc/asound.conf` neu (Basis-Tee bleibt erhalten, nur die physische Ausgabe wird getauscht) und startet `librespot` sowie `ledfx` neu, damit die Änderung greift.

- **usb**: Ausgabe über eine angeschlossene USB-Soundkarte/DAC. Kartenindex mit `aplay -l` prüfen.
- **lan**: Ausgabe wird per PulseAudio-Netzwerkprotokoll an einen anderen Rechner/Empfänger im LAN gestreamt (dieser muss PulseAudio mit aktiviertem Netzwerk-Modul laufen haben, `paprefs` → "Netzwerkzugriff erlauben"). Erfordert `libasound2-plugins` (wird von `install.sh` mitinstalliert).

## LedFx-Setup

1. Weboberfläche öffnen: `http://<pi-ip>:8888`
2. Unter **Audio-Einstellungen** das Loopback-Capture-Device auswählen (z.B. `hw:Loopback,1,0`, wird in `config/ledfx_config.yaml` bereits vorbelegt).
3. Neues Gerät hinzufügen: Typ **WLED**, IP `127.0.0.1`, Port `21324` (Standard-DRGB-Port der Bridge), Anzahl LEDs entsprechend Streifen anpassen.
4. Effekt zuweisen (z.B. "Blade Power" oder "Scroll") und testen.

Die Pixelanzahl und der GPIO-Pin der Bridge lassen sich in `scripts/led_udp_bridge.py` (`LED_COUNT`, `LED_PIN`) anpassen.

## Dienste

| Dienst | Zweck |
|---|---|
| `librespot.service` | Spotify-Connect-Empfang, Audio-Ausgabe über ALSA |
| `led-udp-bridge.service` | Empfängt DRGB-UDP von LedFx, steuert LED-Streifen via GPIO |
| `ledfx.service` | Audioanalyse (Loopback) + Effektberechnung, sendet an die Bridge |

Status prüfen: `sudo systemctl status librespot ledfx led-udp-bridge`
Logs: `journalctl -u ledfx -f`

## Troubleshooting

- **Kein Ton**: `/etc/asound.conf` prüfen, `aplay -l` für Kartenindex, `speaker-test -D physical -c 2` zum Testen der physischen Ausgabe direkt.
- **LEDs reagieren nicht**: `led-udp-bridge.service` muss als root laufen (GPIO-Zugriff via PWM). Prüfen mit `sudo systemctl status led-udp-bridge`.
- **Loopback nicht gefunden**: `sudo modprobe snd-aloop` manuell laden und in `/etc/modules` eintragen (macht `install.sh` bereits automatisch).
- **LAN-Ausgabe bleibt stumm**: Ziel-PulseAudio-Server muss laufen und Netzwerk-Zugriff (`module-native-protocol-tcp`) erlauben; Firewall auf Port 4713 prüfen.
