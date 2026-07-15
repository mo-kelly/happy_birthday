# happy_birthday – Raspberry Pi 5 als Spotify-Connect-Lautsprecher mit LedFx-Steuerung

Repo zum Einrichten eines Raspberry Pi 5 als **Spotify-Connect-Lautsprecher** (via **Raspotify**/librespot), der gleichzeitig einen **WS281x-LED-Streifen** über **LedFx** audioreaktiv ansteuert.

Dieses Setup ist speziell für den **Raspberry Pi 5** angepasst - ältere Anleitungen für Pi 3/4 funktionieren wegen der geänderten Hardware (RP1-I/O-Chip statt klassischer PWM/DMA-GPIO-Register) nicht direkt.

## Architektur

```
Spotify-App  ---(Spotify Connect)--->  Raspotify (librespot)  --->  hw:Loopback,0,0
                                                                          |
                                                            hw:Loopback,1,0 (Aufnahme)
                                                                          |
                                                   pcm.loopback_capture (dsnoop, geteilt)
                                                              /                       \
                                                          LedFx                   lan-audio-bridge.service
                                                   (Audio-Analyse)          (arecord | ffmpeg -> Icecast)
                                                          |                             |
                                             UDP-Bridge (DRGB, lokal)          http://<host>.local:8000/stream.mp3
                                                          |                     /                          \
                                             WS281x-LED-Streifen (SPI, GPIO10)  MacBook (LAN, zum Testen)   Sonos (LAN, spaeter)
                                                                                                       ^
                                                                                        sonos-autoplay.service (SoCo)
                                                                                        stoesst play_uri() automatisch an
```

- **Raspotify** (bündelt `librespot`) meldet den Pi als Spotify-Connect-Gerät an. `librespot` ist kein fertiges Debian-Paket, deshalb dieser Weg statt `apt install librespot`.
- `librespot` schreibt direkt auf das **ALSA-Loopback-Device** (`plughw:Loopback,0,0`).
- Die Aufnahmeseite (`hw:Loopback,1,0`) wird über ein `dsnoop`-Gerät (`pcm.loopback_capture`) geteilt, damit **mehrere Prozesse gleichzeitig** davon lesen können: LedFx für die Lichtanalyse, `lan-audio-bridge.service` für die Ausgabe als LAN-Audiostream (siehe [LAN-Streaming als Ausgabe](#lan-streaming-als-ausgabe)). Ohne dieses Setup ist kein Ton hörbar, nur die Audiodaten für die LED-Analyse verfügbar. Für einen kabelgebundenen USB-DAC siehe [Echten Ton hinzufügen](#echten-ton-hinzufügen).
- Die Audioausgabe läuft **nicht mehr über Bluetooth**, sondern über das lokale Netzwerk (LAN): Icecast2 stellt einen HTTP-MP3-Stream bereit, den jedes Gerät im selben Netz abspielen kann. Aktuell dient dafür das per LAN verbundene MacBook zum Testen; später soll ein **Sonos-Lautsprecher** dieselbe Rolle übernehmen - dafür ist bereits `sonos-autoplay.service` vorbereitet, das neu im LAN auftauchende Sonos-Geräte automatisch per SoCo (`play_uri`) auf den Stream setzt, ohne dass man den Lautsprecher manuell koppeln oder in einer App konfigurieren muss.
- **LedFx** liest `loopback_capture` als Audioquelle und berechnet daraus Lichteffekte.
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
    ├── led_udp_bridge.py          # UDP(DRGB) -> SPI (Pi5Neo) Bridge
    └── sonos_autoplay.py          # SoCo-Discovery -> spielt LAN-Stream automatisch auf Sonos
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

Audioquelle wechseln (Index mit `curl http://localhost:8888/api/audio/devices` herausfinden - das Gerät heißt `loopback_capture`, der Index ist **nicht fest** und hängt davon ab, welche anderen Audiogeräte gerade erkannt werden):
```bash
curl http://localhost:8888/api/audio/devices
curl -X PUT http://localhost:8888/api/audio/devices -H "Content-Type: application/json" -d '{"audio_device": <INDEX>}'
```
Wichtig: der JSON-Schlüssel heißt `audio_device`, nicht `index` (auch wenn die Fehlermeldung der API bei falscher Eingabe "index" nennt).

## LAN-Streaming als Ausgabe

Zusätzlich zur LED-Analyse wird der Ton als **HTTP-MP3-Stream im lokalen Netzwerk (LAN)** bereitgestellt - nicht mehr über Bluetooth. `install.sh` richtet dafür automatisch **Icecast2** (Streaming-Server) und **ffmpeg** ein: eine kleine Bridge (`lan-audio-bridge.service`) liest aus der geteilten Loopback-Aufnahme (`loopback_capture`, dieselbe Quelle wie LedFx) und schickt sie per ffmpeg als MP3 an Icecast. Jeder Player im selben Netzwerk kann den Stream öffnen unter:

```
http://<host>.local:8000/stream.mp3
```

**Aktueller Stand (dieser Branch):** Zum Testen ist ein MacBook per LAN verbunden - dort reicht es, die URL oben in VLC, mpv oder einem Browser zu öffnen, um den Ton zu hören. **Ziel:** Später soll ein **Sonos-Lautsprecher** dieselbe Rolle übernehmen. Damit dafür nur noch das Gerät ins LAN eingesteckt werden muss (kein Koppeln, keine App-Konfiguration), läuft zusätzlich `sonos-autoplay.service`: es sucht per [SoCo](https://github.com/SoCo/SoCo) (SSDP-Discovery, alle 15s) nach Sonos-Geräten im Netz und ruft bei jedem neu gefundenen Gerät automatisch `play_uri()` mit der Stream-URL auf. Sobald der Sonos im selben LAN hängt, sollte er also von selbst zu spielen anfangen.

**Warum nicht einfach direkt auf zwei ALSA-Geräte gleichzeitig schreiben (`multi`-Plugin)?** Das war der erste Ansatz (aus der Bluetooth-Variante dieses Repos), hat sich aber als unzuverlässig erwiesen: das `multi`-Plugin hat in Tests reproduzierbar nur die erste von zwei konfigurierten Abzweigungen tatsächlich mit Audiodaten beliefert, die zweite blieb immer stumm - auch mit korrekter `ttable`/`bindings`-Syntax und einem waschechten Testsignal auf allen 4 Kanälen. Der jetzige Ansatz dupliziert stattdessen auf der Aufnahmeseite über `dsnoop` (extra für "mehrere Leser einer Aufnahme" gedacht) - deutlich robuster.

**Warum Icecast/HTTP-Stream statt AirPlay?** Sonos-Lautsprecher unterstützen zwar teils AirPlay 2, aber nur als *Empfänger* - es gibt keine zuverlässige Linux-Implementierung, die den Pi als AirPlay-*Sender* betreiben könnte. Ein HTTP-MP3-Stream via Icecast dagegen lässt sich von praktisch jedem Gerät (MacBook jetzt, Sonos später, aber auch Handy/Tablet/Browser) ohne Zusatzsoftware abspielen und Sonos kann per `play_uri()` direkt auf eine beliebige Stream-URL gesetzt werden, ganz ohne Registrierung als Radiosender.

### Manuell testen (z. B. vom MacBook aus)

```bash
# im Browser oder mit einem Player oeffnen:
open http://<host>.local:8000/stream.mp3   # macOS
# oder:
ffplay http://<host>.local:8000/stream.mp3
vlc http://<host>.local:8000/stream.mp3
```

Icecast-Statusseite (Clients, Bitrate, etc.): `http://<host>.local:8000/`

### Sonos manuell ansteuern (falls `sonos-autoplay.service` mal nicht greift)

Mit [SoCo](https://github.com/SoCo/SoCo) auf einem beliebigen Rechner im selben LAN (z. B. dem MacBook):

```bash
pip install soco
python3 -c "
import soco
for d in soco.discover():
    print(d.player_name, d.ip_address)
    d.play_uri('http://<host>.local:8000/stream.mp3', title='ELEMAX')
"
```

### Passwörter ändern

`install.sh` setzt Standardpasswörter (`hackme` / `hackme_admin`) für den Icecast-Source- bzw. Admin-Zugang in `/etc/icecast2/icecast.xml` und in der `lan-audio-bridge.service`-Unit. Für ein nicht rein privates/vertrauenswürdiges LAN sollten diese vor dem produktiven Einsatz geändert werden (in beiden Dateien synchron halten, danach `systemctl restart icecast2 lan-audio-bridge`). Für Hörer selbst gibt es bewusst keine Authentifizierung - jeder im LAN kann den Stream öffnen.

## Echten Ton hinzufügen (kabelgebunden, USB-DAC)

Alternative zum LAN-Stream: sobald ein USB-DAC angeschlossen ist, kann Raspotify direkt darauf schreiben, ganz ohne Tee/Loopback für die Ausgabe - die LED-Analyse läuft unabhängig weiter über `loopback_capture`.

1. Kartenindex ermitteln: `aplay -l`
2. `LIBRESPOT_DEVICE` in `/etc/raspotify/conf` auf den USB-DAC setzen (z. B. `plughw:CARD=Device,DEV=0`) statt auf `plughw:Loopback,0,0`. Achtung: dann bekommt die LED-Analyse keine Daten mehr, da sie separat weiterhin auf dem Loopback-Device beruht - für **gleichzeitig** echten Ton UND LEDs stattdessen den LAN-Streaming-Ansatz als Vorlage nehmen (Tee auf der Aufnahmeseite per `dsnoop`, nicht auf der Wiedergabeseite per `multi`).

## Dienste

| Dienst | Zweck |
|---|---|
| `raspotify.service` | Spotify-Connect-Empfang, Audio-Ausgabe über ALSA |
| `led-udp-bridge.service` | Empfängt DRGB-UDP von LedFx, steuert LED-Streifen via SPI |
| `ledfx.service` | Audioanalyse (Loopback) + Effektberechnung, sendet an die Bridge |
| `icecast2.service` | Streaming-Server, stellt den HTTP-MP3-Stream im LAN bereit |
| `lan-audio-bridge.service` | Liest `loopback_capture`, schickt Ton per ffmpeg an Icecast |
| `sonos-autoplay.service` | Sucht Sonos-Geräte im LAN, startet dort automatisch den Stream (SoCo) |

Status prüfen: `sudo systemctl status raspotify ledfx led-udp-bridge icecast2 lan-audio-bridge sonos-autoplay`
Logs: `journalctl -u ledfx -f` (bzw. `-u lan-audio-bridge`, `-u sonos-autoplay`, `-u icecast2`)

## Troubleshooting

- **`ws2811_init failed with code -3 (Hardware revision is not supported)`**: du nutzt noch `rpi_ws281x` statt `Pi5Neo` - betrifft nur ältere Repo-Versionen, dieses Script installiert bereits `Pi5Neo`.
- **`E: Unable to locate package librespot`**: `librespot` gibt es nicht als apt-Paket für Raspberry Pi OS. `install.sh` nutzt bereits Raspotify statt apt.
- **Audio Sink Error / `ALSA lib pcm_multi.c: Unknown field slave`**: Syntaxfehler in `/etc/asound.conf`, meist die `bindings`-Notation im `multi`-Plugin. Punktnotation verwenden (siehe [Echten Ton hinzufügen](#echten-ton-hinzufügen)).
- **`default` zeigt trotz eigener `/etc/asound.conf` auf ein anderes Gerät**: `/etc/alsa/conf.d/50-pulseaudio.conf` bzw. `/usr/share/alsa/alsa.conf.d/50-pulseaudio.conf` können `default` überschreiben, auch ohne laufenden PulseAudio-Daemon. `install.sh` deaktiviert diese Dateien automatisch. Alternativ: das gewünschte Gerät explizit über `LIBRESPOT_DEVICE` in `/etc/raspotify/conf` setzen statt sich auf `default` zu verlassen.
- **`Unsupported Format S16LE` bzw. `snd_pcm_open failed` beim Verbindungsversuch in Spotify**: `LIBRESPOT_DEVICE` darf nicht das rohe `hw:Loopback,0,0`-Gerät direkt ansprechen (führt zu Formatkonflikten, u. a. wenn LedFx die Gegenseite schon mit anderen Parametern geöffnet hat). Immer `plughw:Loopback,0,0` verwenden (mit dem `plug`-Präfix als **einem Wort**, nicht `plug:hw:...` - das erzeugt einen ALSA-Parse-Fehler "Unknown parameter"). `install.sh` setzt das bereits korrekt.
- **LEDs reagieren nicht, obwohl alle Dienste laufen**: prüfen, ob LedFx überhaupt ein Gerät/Virtual/Effekt/Audioquelle konfiguriert hat (`curl http://localhost:8888/api/virtuals/elemax`, `curl http://localhost:8888/api/audio/devices`) - `install.sh` richtet das automatisch ein, aber die Web-UI-Vorlage (`config.yaml`) wird von der pip-Version von LedFx **nicht** automatisch eingelesen.
- **Web-UI zeigt "Network Error"**: siehe [LedFx per API steuern](#ledfx-per-api-steuern).
- **Pi friert ein / bootet nicht mehr**: kann an unzureichender Stromversorgung liegen (offizielles 27W-USB-C-PD-Netzteil für den Pi 5 verwenden, LEDs nicht dauerhaft vom Pi selbst versorgen) oder an einer durch harte Stromabbrüche beschädigten SD-Karte. Bei wiederholten Freezes: SD-Karte neu flashen statt wiederholt hart vom Strom zu trennen.
- **Kein Ton über den LAN-Stream, obwohl `lan-audio-bridge.service` läuft**: meistens ein `asound.conf`-Problem oder ein zweiter Prozess, der dasselbe Gerät schon offen hält. Test: Dienste, die `loopback_capture`/`hw:Loopback,...` nutzen könnten (`raspotify`, `ledfx`, `lan-audio-bridge`), kurz stoppen und mit `speaker-test -D loopback_capture ...` bzw. `arecord -D loopback_capture ...` isoliert prüfen, ob überhaupt Audiodaten ankommen (nicht nur Nullen im Hex-Dump, z. B. via `od -An -tx1 datei.raw`). Zusätzlich prüfen, ob Icecast den Stream überhaupt als aktive Quelle sieht: `http://<host>.local:8000/` sollte den Mountpoint `/stream.mp3` mit Clients/Bitrate anzeigen.
- **`arecord`/`speaker-test`: `Device or resource busy`**: ein anderer Prozess hält das ALSA-Gerät bereits exklusiv offen - meistens `raspotify` (Wiedergabeseite) oder `ledfx`/`lan-audio-bridge` (Aufnahmeseite). Vor manuellen Tests immer kurz stoppen: `sudo systemctl stop raspotify ledfx lan-audio-bridge`, danach wieder starten.
- **Icecast-Mountpoint `/stream.mp3` erscheint nicht / ffmpeg beendet sich sofort**: Source-Passwort in `lan-audio-bridge.service` und `/etc/icecast2/icecast.xml` müssen übereinstimmen (`journalctl -u lan-audio-bridge -f` zeigt ffmpeg-Fehler wie `403 Forbidden` bei falschem Passwort). Nach Änderung: `systemctl daemon-reload && systemctl restart icecast2 lan-audio-bridge`.
- **`sonos-autoplay.service` findet keinen Sonos-Lautsprecher**: SoCo nutzt SSDP-Multicast - funktioniert nur, wenn Pi und Sonos im selben Layer-2-Netz/Subnetz hängen (kein VLAN-/Client-Isolation-Problem im WLAN). Mit `journalctl -u sonos-autoplay -f` prüfen, ob Discovery überhaupt läuft; manueller Test siehe [LAN-Streaming als Ausgabe](#lan-streaming-als-ausgabe), Abschnitt "Sonos manuell ansteuern".
- **ALSA-`multi`-Plugin verteilt Audio nicht auf alle Abzweigungen**: reproduzierbar beobachtet, dass von zwei konfigurierten Slaves nur der erste tatsächlich Audiodaten bekam, der zweite blieb stumm - auch mit korrekter `bindings`-Punktnotation und einem echten Mehrkanal-Testsignal. Kein reiner Syntaxfehler, sondern eine Unzuverlässigkeit dieses Plugins in dieser ALSA-Version. Lösung: für "eine Aufnahme, mehrere Leser" stattdessen `dsnoop` verwenden (siehe [Bluetooth-Kopfhörer als Ausgabe](#bluetooth-kopfhörer-als-ausgabe)), nicht `multi`.
- **`/etc/asound.conf` hat nach mehreren Bearbeitungen widersprüchliche/doppelte `pcm.!default`-Blöcke**: passiert leicht bei mehrfachem Bearbeiten mit `nano`, wenn alter Inhalt nicht vollständig gelöscht wird (ALSA nimmt dann die letzte Definition, evtl. eine alte). Datei sicherheitshalber immer komplett neu schreiben statt zu editieren, z. B. mit `sudo tee /etc/asound.conf > /dev/null << 'EOF' ... EOF`, und danach mit `cat /etc/asound.conf` kontrollieren, dass nur ein `pcm.!default`-Block existiert.
