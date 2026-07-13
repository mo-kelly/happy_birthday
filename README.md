# happy_birthday – Raspberry Pi 5 als Spotify-Connect-Lautsprecher mit LedFx-Steuerung

Repo zum Einrichten eines Raspberry Pi 5 als **Spotify-Connect-Lautsprecher** (via **Raspotify**/librespot), der gleichzeitig einen **WS281x-LED-Streifen** über **LedFx** audioreaktiv ansteuert.

Dieses Setup ist speziell für den **Raspberry Pi 5** angepasst - ältere Anleitungen für Pi 3/4 funktionieren wegen der geänderten Hardware (RP1-I/O-Chip statt klassischer PWM/DMA-GPIO-Register) nicht direkt.

## Architektur

```
Spotify-App  ---(Spotify Connect)--->  Raspotify (librespot)  --->  ALSA "default"
                                                                          |
                                                              ALSA-Loopback-Device
                                                                  (snd-aloop)
                                                                          |
                                                                       LedFx
                                                                 (Audio-Analyse)
                                                                          |
                                                             UDP-Bridge (DRGB, lokal)
                                                                          |
                                                         WS281x-LED-Streifen (SPI, GPIO10)
```

- **Raspotify** (bündelt `librespot`) meldet den Pi als Spotify-Connect-Gerät an. `librespot` ist kein fertiges Debian-Paket, deshalb dieser Weg statt `apt install librespot`.
- Ohne angeschlossenen Lautsprecher/USB-DAC schreibt `librespot` direkt auf das **ALSA-Loopback-Device** (`plughw:Loopback,0,0`) - es ist aktuell kein Ton hörbar, nur die Audiodaten für die LED-Analyse verfügbar. Sobald ein echter Ausgang (USB-DAC) vorhanden ist, siehe [Echten Ton hinzufügen](#echten-ton-hinzufügen).
- **LedFx** liest die Gegenseite des Loopback-Devices (`hw:Loopback,1,0`) als Audioquelle und berechnet daraus Lichteffekte.
- LedFx sendet die Effekte per lokalem UDP (WLED-kompatibles DRGB-Protokoll) an eine kleine Python-Bridge (`scripts/led_udp_bridge.py`), die den LED-Streifen über **SPI** (nicht GPIO/PWM!) mit `Pi5Neo` ansteuert.

### Warum SPI statt PWM/GPIO18?

`rpi_ws281x`, die "klassische" WS281x-Bibliothek, unterstützt den Pi 5 nicht (`RuntimeError: ws2811_init failed with code -3 (Hardware revision is not supported)`) - der neue RP1-I/O-Chip hat die dafür nötigen PWM/DMA-Register nicht mehr. Dieses Repo nutzt stattdessen [`Pi5Neo`](https://github.com/vanshksingh/Pi5Neo), das den Streifen über die Hardware-SPI-Schnittstelle ansteuert. Das ändert auch die Pinbelegung: **GPIO10 (Pin 19)** statt GPIO18 (Pin 12).

## Hardware

- Raspberry Pi 5
- WS281x/WS2812B/NeoPixel-LED-Streifen
- Eigenes 5V-Netzteil für den LED-Streifen (**nicht dauerhaft über den Pi versorgen** - siehe Hinweis unten)
- Optional: USB-DAC/USB-Soundkarte für echten Ton (Pi 5 hat keinen Klinkenausgang mehr)
- Optional: Logic-Level-Shifter 3,3V → 5V für die Datenleitung

### Verkabelung LED-Streifen

| LED-Streifen | Pi 5 |
|---------------|-------------|
| 5V | externes Netzteil (5V) |
| GND | externes Netzteil GND **und** Pi GND, z. B. Pin 6 (gemeinsame Masse!) |
| DIN (Data) | **Pin 19 (GPIO10 / SPI0 MOSI)** |

**Wichtiger Hinweis zur Stromversorgung:** Für Dauerbetrieb oder mehr als ca. 10-15 LEDs immer ein externes 5V-Netzteil verwenden (Faustregel: Leistung des Streifens in W/m ÷ 5V = A pro Meter). Der Pi-eigene 5V-Pin ist nur für ganz kurze Tests mit wenigen LEDs bei reduzierter Helligkeit geeignet - Lastspitzen (v. a. beim gleichzeitigen Booten vieler Dienste) können sonst den Pi destabilisieren.

## Verzeichnisstruktur

```
happy_birthday/
├── README.md
├── install.sh                     # Setup-Script, auf dem Pi ausführen
└── scripts/
    └── led_udp_bridge.py          # UDP(DRGB) -> SPI (Pi5Neo) Bridge
```

`install.sh` generiert alle benötigten Konfigurationsdateien (ALSA, Raspotify, systemd-Units) direkt beim Ausführen - dafür gibt es keine separaten Template-Dateien mehr im Repo (frühere Versionen dieses Repos hatten `config/`- und `systemd/`-Ordner mit statischen Vorlagen; das hat sich als fehleranfällig erwiesen, siehe [Troubleshooting](#troubleshooting)).

## Installation auf dem Pi

1. Raspberry Pi Imager: SSH aktivieren (Passwort-Auth), Hostname/Benutzername setzen, WLAN-Zugangsdaten eintragen (SSID **genau** prüfen!).
2. Repo auf den Pi kopieren:
   ```bash
   scp -r happy_birthday/ <user>@<host>.local:~/
   ```
3. Auf dem Pi einloggen und ausführen:
   ```bash
   ssh <user>@<host>.local
   cd ~/happy_birthday
   chmod +x install.sh
   sudo ./install.sh
   ```
   Dauert ca. 5-10 Minuten. Das Script installiert Raspotify, `Pi5Neo`, LedFx, aktiviert SPI und das `snd-aloop`-Kernelmodul, richtet die ALSA-Konfiguration ein, erstellt die systemd-Units **und** konfiguriert LedFx (Gerät, Effekt, Audioquelle) automatisch per REST-API.
4. LED-Streifen wie oben beschrieben verkabeln.
5. Fertig - der Pi sollte in Spotify unter dem konfigurierten Benutzernamen als Connect-Gerät erscheinen, und die LEDs sollten direkt auf die Musik reagieren.

Kein Neustart nötig, aber empfehlenswert, um den kompletten Ablauf einmal zu verifizieren:
```bash
sudo reboot
```

## Konfiguration ändern

- **Spotify-Gerätename:** `/etc/raspotify/conf`, Zeile `LIBRESPOT_NAME`, danach `sudo systemctl restart raspotify`.
- **LED-Anzahl/Helligkeit:** `scripts/led_udp_bridge.py`, `LED_COUNT`/`LED_BRIGHTNESS`, danach Datei auf den Pi kopieren und `sudo systemctl restart led-udp-bridge`. Zusätzlich `pixel_count` im LedFx-Gerät anpassen (siehe unten, per curl).
- **Lichteffekt/Farbe:** siehe [LedFx per API steuern](#ledfx-per-api-steuern) - die Web-UI hat einen bekannten Bug.

## LedFx per API steuern

Die Web-Oberfläche (`http://<host>.local:8888`) zeigt bei bestimmten Aktionen (Gerät/Virtual aktivieren, Audioquelle wechseln, Effekt speichern) einen **"Network Error"**, obwohl das LedFx-Backend selbst funktioniert - ein bekannter Bug der aktuell über pip installierbaren Version. Workaround: die gleichen Änderungen direkt per `curl` auf dem Pi vornehmen.

Aktivieren:
```bash
curl -X PUT http://localhost:8888/api/virtuals/elemax -H "Content-Type: application/json" -d '{"active": true}'
```

Effekt/Farbe setzen (Beispiel: Blade Power+ mit blauem Grundton):
```bash
curl -X POST http://localhost:8888/api/virtuals/elemax/effects -H "Content-Type: application/json" -d '{"type": "blade_power_plus", "config": {"gradient": "#0000ff"}}'
```

Audioquelle wechseln (Index mit `curl http://localhost:8888/api/audio/devices` herausfinden - das Loopback-Capture-Device, nicht "default"):
```bash
curl -X PUT http://localhost:8888/api/audio/devices -H "Content-Type: application/json" -d '{"audio_device": 1}'
```
Wichtig: der JSON-Schlüssel heißt `audio_device`, nicht `index` (auch wenn die Fehlermeldung der API bei falscher Eingabe "index" nennt).

## Echten Ton hinzufügen

Aktuell schreibt Raspotify direkt auf das Loopback-Device, es ist also kein Ton hörbar. Sobald ein USB-DAC angeschlossen ist:

1. Kartenindex ermitteln: `aplay -l`
2. `/etc/asound.conf` um einen "Tee" erweitern, der gleichzeitig auf den USB-DAC **und** das Loopback-Device schreibt (ALSA `multi`-Plugin). Achtung: die `bindings`-Syntax muss Punktnotation nutzen (`bindings.0.slave a` / `bindings.0.channel 0`), die geschweifte Blockform (`bindings.0 { slave a; channel 0 }`) wird von manchen ALSA-Versionen nicht korrekt geparst.
3. `LIBRESPOT_DEVICE` in `/etc/raspotify/conf` auf den neuen Tee-PCM-Namen setzen statt direkt auf `plughw:Loopback,0,0`.

## Dienste

| Dienst | Zweck |
|---|---|
| `raspotify.service` | Spotify-Connect-Empfang, Audio-Ausgabe über ALSA |
| `led-udp-bridge.service` | Empfängt DRGB-UDP von LedFx, steuert LED-Streifen via SPI |
| `ledfx.service` | Audioanalyse (Loopback) + Effektberechnung, sendet an die Bridge |

Status prüfen: `sudo systemctl status raspotify ledfx led-udp-bridge`
Logs: `journalctl -u ledfx -f`

## Troubleshooting

- **`ws2811_init failed with code -3 (Hardware revision is not supported)`**: du nutzt noch `rpi_ws281x` statt `Pi5Neo` - betrifft nur ältere Repo-Versionen, dieses Script installiert bereits `Pi5Neo`.
- **`E: Unable to locate package librespot`**: `librespot` gibt es nicht als apt-Paket für Raspberry Pi OS. `install.sh` nutzt bereits Raspotify statt apt.
- **Audio Sink Error / `ALSA lib pcm_multi.c: Unknown field slave`**: Syntaxfehler in `/etc/asound.conf`, meist die `bindings`-Notation im `multi`-Plugin. Punktnotation verwenden (siehe [Echten Ton hinzufügen](#echten-ton-hinzufügen)).
- **`default` zeigt trotz eigener `/etc/asound.conf` auf ein anderes Gerät**: `/etc/alsa/conf.d/50-pulseaudio.conf` bzw. `/usr/share/alsa/alsa.conf.d/50-pulseaudio.conf` können `default` überschreiben, auch ohne laufenden PulseAudio-Daemon. `install.sh` deaktiviert diese Dateien automatisch. Alternativ: das gewünschte Gerät explizit über `LIBRESPOT_DEVICE` in `/etc/raspotify/conf` setzen statt sich auf `default` zu verlassen.
- **`Unsupported Format S16LE` bzw. `snd_pcm_open failed` beim Verbindungsversuch in Spotify**: `LIBRESPOT_DEVICE` darf nicht das rohe `hw:Loopback,0,0`-Gerät direkt ansprechen (führt zu Formatkonflikten, u. a. wenn LedFx die Gegenseite schon mit anderen Parametern geöffnet hat). Immer `plughw:Loopback,0,0` verwenden (mit dem `plug`-Präfix als **einem Wort**, nicht `plug:hw:...` - das erzeugt einen ALSA-Parse-Fehler "Unknown parameter"). `install.sh` setzt das bereits korrekt.
- **LEDs reagieren nicht, obwohl alle Dienste laufen**: prüfen, ob LedFx überhaupt ein Gerät/Virtual/Effekt/Audioquelle konfiguriert hat (`curl http://localhost:8888/api/virtuals/elemax`, `curl http://localhost:8888/api/audio/devices`) - `install.sh` richtet das automatisch ein, aber die Web-UI-Vorlage (`config.yaml`) wird von der pip-Version von LedFx **nicht** automatisch eingelesen.
- **Web-UI zeigt "Network Error"**: siehe [LedFx per API steuern](#ledfx-per-api-steuern).
- **Pi friert ein / bootet nicht mehr**: kann an unzureichender Stromversorgung liegen (offizielles 27W-USB-C-PD-Netzteil für den Pi 5 verwenden, LEDs nicht dauerhaft vom Pi selbst versorgen) oder an einer durch harte Stromabbrüche beschädigten SD-Karte. Bei wiederholten Freezes: SD-Karte neu flashen statt wiederholt hart vom Strom zu trennen.
