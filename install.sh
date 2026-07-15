#!/usr/bin/env bash
#
# install.sh - Kompletteinrichtung fuer happy_birthday auf dem Raspberry Pi 5.
#
# Richtet den Pi als Spotify-Connect-Lautsprecher (Raspotify) ein und steuert
# gleichzeitig einen WS281x/NeoPixel-LED-Streifen audioreaktiv ueber LedFx.
#
# Ausfuehren NACH dem ersten Boot, per SSH auf dem Pi, im Home-Verzeichnis:
#   ssh <user>@<host>.local
#   scp -r happy_birthday/ <user>@<host>.local:~/
#   cd ~/happy_birthday
#   chmod +x install.sh
#   sudo ./install.sh
#
# Dauer: ca. 5-10 Minuten (Downloads + Kompilierung von python-rtmidi).
#
# Hintergrund/Warum dieses Setup so aussieht (siehe auch README.md):
# - rpi_ws281x (die "klassische" WS281x-Bibliothek) unterstuetzt den Pi 5
#   nicht (neuer RP1-I/O-Chip statt PWM/DMA-Register wie bei aelteren Pis).
#   Wir nutzen stattdessen Pi5Neo ueber SPI (GPIO10/Pin19 statt GPIO18).
# - librespot gibt es nicht als fertiges Debian-Paket fuer Raspberry Pi OS.
#   Wir installieren stattdessen Raspotify (bündelt librespot als .deb).
# - Ohne echten Lautsprecher/USB-DAC zeigt "default" bei Pi-5-HDMI-Audio oft
#   Fehler (kein EDID/Display). Deshalb zeigt "default" hier direkt auf das
#   ALSA-Loopback-Device statt auf einen physischen Ausgang. Sobald ein
#   USB-DAC angeschlossen ist, kann man wieder einen echten Tee (physisch +
#   Loopback gleichzeitig) einbauen - siehe README.md, Abschnitt "Echten Ton
#   hinzufuegen".
# - Audioausgabe erfolgt NICHT mehr ueber Bluetooth, sondern ueber LAN:
#   Icecast2 stellt einen HTTP-MP3-Stream im lokalen Netz bereit
#   (http://<host>.local:8000/stream.mp3), gespeist per ffmpeg aus derselben
#   "loopback_capture"-Aufnahme wie LedFx. Jeder Player im LAN kann das jetzt
#   abspielen (aktuell z.B. VLC/mpv/Browser auf dem MacBook); ein Sonos-
#   Lautsprecher kann denselben Stream spaeter per SoCo automatisch
#   abspielen, siehe README.md und scripts/sonos_autoplay.py.
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Bitte mit sudo ausfuehren: sudo ./install.sh" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-pi}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Nutzer: $TARGET_USER, Home: $TARGET_HOME, Repo: $REPO_DIR"

echo "==> [1/12] Paketquellen aktualisieren"
apt-get update

echo "==> [2/12] Systempakete installieren"
# Bluetooth/PipeWire werden NICHT mehr benoetigt - Audioausgabe laeuft jetzt
# ueber LAN (Icecast2 + ffmpeg), siehe README.md
export DEBIAN_FRONTEND=noninteractive
apt-get install -y \
    alsa-utils \
    libasound2-plugins \
    libasound2-dev \
    libportaudio2 \
    pulseaudio-utils \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    git \
    ffmpeg \
    icecast2

echo "==> [3/12] SPI aktivieren (fuer Pi5Neo/WS2812 ueber GPIO10)"
raspi-config nonint do_spi 0

echo "==> [4/12] snd-aloop (ALSA Loopback) aktivieren, Index 2 (0/1 sind bei"
echo "    Pi 5 durch die beiden HDMI-Ausgaenge belegt)"
mkdir -p /etc/modules-load.d
if ! grep -q "^snd-aloop" /etc/modules-load.d/snd-aloop.conf 2>/dev/null; then
    echo "snd-aloop" > /etc/modules-load.d/snd-aloop.conf
fi
cat > /etc/modprobe.d/snd-aloop.conf <<'EOF'
options snd-aloop enable=1 index=2
EOF
modprobe snd-aloop || true

echo "==> [5/14] ALSA-Basiskonfiguration schreiben"
echo "    (kein physischer Lautsprecher/DAC vorhanden -> default zeigt direkt"
echo "    auf das Loopback-Device, siehe Kommentar oben im Script)"
echo "    Zusaetzlich: 'loopback_capture' als dsnoop-Geraet, damit LedFx UND"
echo "    die LAN-Audio-Bridge (Icecast/ffmpeg) gleichzeitig von derselben"
echo "    Aufnahme lesen koennen (siehe README.md, Abschnitt 'LAN-Streaming"
echo "    als Ausgabe'). Das ALSA-'multi'-Plugin wurde hierfuer bewusst NICHT"
echo "    verwendet - es hat sich als unzuverlaessig erwiesen (verteilt Audio"
echo "    nicht zuverlaessig auf mehr als eine Abzweigung, siehe README.md"
echo "    Troubleshooting)."
cat > /etc/asound.conf <<'EOF'
pcm.loopback_capture {
    type dsnoop
    ipc_key 219219
    slave {
        pcm "hw:Loopback,1,0"
        channels 2
        rate 44100
        format S16_LE
    }
}

pcm.!default {
    type plug
    slave.pcm "hw:Loopback,0,0"
}
EOF

# Alte PulseAudio-ALSA-Snippets deaktivieren (koennen "default" ueberschreiben,
# obwohl gar kein PulseAudio-Daemon laeuft)
for f in /etc/alsa/conf.d/50-pulseaudio.conf /usr/share/alsa/alsa.conf.d/50-pulseaudio.conf; do
    if [[ -f "$f" ]]; then
        mv "$f" "$f.disabled"
    fi
done

echo "==> [6/14] Raspotify installieren (Spotify Connect)"
if ! dpkg -l | grep -q raspotify; then
    curl -sL https://dtcooper.github.io/raspotify/install.sh | sh
fi

cat > /etc/raspotify/conf <<EOF
LIBRESPOT_NAME="$TARGET_USER"
LIBRESPOT_DEVICE="plughw:Loopback,0,0"
LIBRESPOT_QUIET=
TMPDIR=/tmp
EOF

echo "==> [7/14] Pi5Neo installieren (WS281x ueber SPI)"
python3 -m pip install --user pi5neo --break-system-packages
python3 -m pip install pi5neo --break-system-packages

echo "==> [8/14] LED-UDP-Bridge-Script installieren + systemd-Unit anlegen"
mkdir -p "$REPO_DIR/scripts"
chmod +x "$REPO_DIR/scripts/led_udp_bridge.py"
chmod +x "$REPO_DIR/scripts/sonos_autoplay.py"
chown -R "$TARGET_USER":"$TARGET_USER" "$REPO_DIR"

cat > /etc/systemd/system/led-udp-bridge.service <<EOF
[Unit]
Description=LED UDP Bridge (DRGB -> WS281x SPI)
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 $REPO_DIR/scripts/led_udp_bridge.py
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "==> [9/14] LedFx installieren + systemd-Unit anlegen"
sudo -u "$TARGET_USER" python3 -m pip install --user --upgrade pip --break-system-packages
sudo -u "$TARGET_USER" python3 -m pip install --user ledfx --break-system-packages

mkdir -p "$TARGET_HOME/.ledfx"
chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.ledfx"

cat > /etc/systemd/system/ledfx.service <<EOF
[Unit]
Description=LedFx Audioreactive LED Controller
After=network-online.target sound.target led-udp-bridge.service
Wants=network-online.target

[Service]
ExecStart=$TARGET_HOME/.local/bin/ledfx --config $TARGET_HOME/.ledfx
Restart=on-failure
RestartSec=3
User=$TARGET_USER
Group=audio

[Install]
WantedBy=multi-user.target
EOF
# Bewusst OHNE "Requires=led-udp-bridge.service": das fuehrt sonst dazu, dass
# ein Neustart/Stopp der Bridge automatisch auch LedFx mit stoppt.

echo "==> [10/14] Icecast2 (LAN-Audio-Stream) konfigurieren"
echo "    Ersetzt den frueheren Bluetooth/PipeWire-Weg: der Ton wird jetzt als"
echo "    HTTP-MP3-Stream im LAN bereitgestellt (http://<host>.local:8000/stream.mp3)."
echo "    Passwoerter aendern, falls der Pi in einem nicht vertrauenswuerdigen"
echo "    Netz haengt - Icecast bindet hier bewusst nur an 0.0.0.0 im LAN,"
echo "    es gibt keine Authentifizierung fuer Hoerer, nur fuer den Source-Client."
ICECAST_SOURCE_PASSWORD="hackme"
ICECAST_ADMIN_PASSWORD="hackme_admin"

cat > /etc/icecast2/icecast.xml <<EOF
<icecast>
    <location>ELEMAX</location>
    <admin>admin@localhost</admin>
    <limits>
        <clients>20</clients>
        <sources>2</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
        <burst-on-connect>1</burst-on-connect>
        <burst-size>65535</burst-size>
    </limits>
    <authentication>
        <source-password>${ICECAST_SOURCE_PASSWORD}</source-password>
        <relay-password>${ICECAST_SOURCE_PASSWORD}</relay-password>
        <admin-user>admin</admin-user>
        <admin-password>${ICECAST_ADMIN_PASSWORD}</admin-password>
    </authentication>
    <hostname>${TARGET_USER}.local</hostname>
    <listen-socket>
        <port>8000</port>
        <bind-address>0.0.0.0</bind-address>
    </listen-socket>
    <fileserve>1</fileserve>
    <paths>
        <basedir>/usr/share/icecast2</basedir>
        <logdir>/var/log/icecast2</logdir>
        <webroot>/usr/share/icecast2/web</webroot>
        <adminroot>/usr/share/icecast2/admin</adminroot>
        <alias source="/" destination="/status.xsl"/>
    </paths>
    <logging>
        <accesslog>access.log</accesslog>
        <errorlog>error.log</errorlog>
        <loglevel>3</loglevel>
        <logsize>10000</logsize>
    </logging>
    <security>
        <chroot>0</chroot>
    </security>
</icecast>
EOF

# icecast2-Paket fragt beim Postinst normalerweise interaktiv nach
# "als Dienst starten?" - per debconf vorbelegen, damit das unter
# DEBIAN_FRONTEND=noninteractive sauber durchlaeuft
echo "icecast2 icecast2/icecast-setup boolean true" | debconf-set-selections
dpkg-reconfigure -f noninteractive icecast2 || true

echo "==> [11/14] LAN-Audio-Bridge einrichten (Loopback -> ffmpeg -> Icecast)"
cat > /etc/systemd/system/lan-audio-bridge.service <<EOF
[Unit]
Description=Loopback-Tee -> LAN-Audio-Stream (Icecast, fuer MacBook/Sonos)
After=network-online.target icecast2.service
Wants=network-online.target
Requires=icecast2.service

[Service]
ExecStart=/bin/sh -c 'arecord -D loopback_capture -f S16_LE -r 44100 -c 2 -t raw | ffmpeg -loglevel error -f s16le -ar 44100 -ac 2 -i - -c:a libmp3lame -b:a 192k -content_type audio/mpeg -f mp3 icecast://source:${ICECAST_SOURCE_PASSWORD}@localhost:8000/stream.mp3'
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "==> [12/14] SoCo installieren + Sonos-Autoplay-Dienst einrichten"
echo "    (optional/zukunftssicher: sobald ein Sonos-Lautsprecher im selben"
echo "    LAN erscheint, wird ihm automatisch der Icecast-Stream als"
echo "    Wiedergabe-URL geschickt - kein manuelles Koppeln noetig, siehe"
echo "    README.md, Abschnitt 'LAN-Streaming als Ausgabe')"
sudo -u "$TARGET_USER" python3 -m pip install --user soco --break-system-packages

cat > /etc/systemd/system/sonos-autoplay.service <<EOF
[Unit]
Description=Findet Sonos-Lautsprecher im LAN und spielt den Icecast-Stream ab
After=network-online.target lan-audio-bridge.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 $REPO_DIR/scripts/sonos_autoplay.py --stream-url http://${TARGET_USER}.local:8000/stream.mp3
Restart=on-failure
RestartSec=5
User=$TARGET_USER

[Install]
WantedBy=multi-user.target
EOF

echo "==> [13/14] Dienste aktivieren und starten"
systemctl daemon-reload
systemctl enable --now led-udp-bridge
systemctl enable --now ledfx
systemctl enable --now raspotify
systemctl enable --now icecast2
systemctl enable --now lan-audio-bridge
systemctl enable --now sonos-autoplay

echo "==> [14/14] LedFx-Geraet/Virtual/Effekt/Audioquelle per API einrichten"
echo "    (LedFx liest keine eigene config.yaml-Vorlage ein, deshalb hier"
echo "    per REST-API direkt)"

for i in $(seq 1 30); do
    if curl -s -o /dev/null http://localhost:8888/api/devices; then
        break
    fi
    sleep 1
done

curl -s -X POST http://localhost:8888/api/devices \
    -H "Content-Type: application/json" \
    -d '{"type": "udp", "config": {"name": "ELEMAX", "ip_address": "127.0.0.1", "port": 21324, "pixel_count": 15, "udp_packet_type": "DRGB", "refresh_rate": 60}}' \
    > /dev/null || true

curl -s -X POST http://localhost:8888/api/virtuals \
    -H "Content-Type: application/json" \
    -d '{"id": "elemax", "is_device": "elemax", "config": {"name": "ELEMAX"}}' \
    > /dev/null || true

# WICHTIG: der Feldname im Request ist "audio_device", NICHT "index" (die
# Fehlermeldung der API selbst ist irrefuehrend, siehe
# ledfx/api/audio_devices.py im installierten Paket).
#
# Der Geraete-Index ist NICHT fest (haengt von anderen erkannten Audiogeraeten
# ab), deshalb per Namenssuche ermitteln statt einen festen Wert zu raten.
# "loopback_capture" (dsnoop, siehe Schritt 5) statt der rohen Hardware
# ("hw:2,1"), damit die LAN-Audio-Bridge gleichzeitig mitlesen kann, ohne mit
# LedFx um das Geraet zu konkurrieren ("Device or resource busy").
LOOPBACK_CAPTURE_INDEX=""
for i in $(seq 1 10); do
    LOOPBACK_CAPTURE_INDEX=$(curl -s http://localhost:8888/api/audio/devices | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for idx, name in data.get('devices', {}).items():
    if 'loopback_capture' in name:
        print(idx)
        break
" 2>/dev/null || true)
    if [[ -n "$LOOPBACK_CAPTURE_INDEX" ]]; then
        break
    fi
    sleep 1
done

if [[ -n "$LOOPBACK_CAPTURE_INDEX" ]]; then
    curl -s -X PUT http://localhost:8888/api/audio/devices \
        -H "Content-Type: application/json" \
        -d "{\"audio_device\": $LOOPBACK_CAPTURE_INDEX}" \
        > /dev/null || true
else
    echo "    Warnung: 'loopback_capture' nicht gefunden, Audioquelle muss"
    echo "    manuell gesetzt werden (siehe README.md)."
fi

curl -s -X POST http://localhost:8888/api/virtuals/elemax/effects \
    -H "Content-Type: application/json" \
    -d '{"type": "blade_power_plus", "config": {"gradient": "#ff2800"}}' \
    > /dev/null || true

curl -s -X PUT http://localhost:8888/api/virtuals/elemax \
    -H "Content-Type: application/json" \
    -d '{"active": true}' \
    > /dev/null || true

echo ""
echo "=================================================================="
echo "Installation abgeschlossen - LedFx sollte bereits vollstaendig"
echo "eingerichtet und aktiv sein (Geraet, Virtual, Effekt, Audioquelle)."
echo ""
echo "Verkabelung LED-Streifen (siehe auch README.md):"
echo "  DIN (Data) -> Pin 19 (GPIO10 / MOSI)"
echo "  GND        -> Pin 6 (UND gemeinsame Masse mit externem Netzteil)"
echo "  5V         -> separates 5V-Netzteil (NICHT dauerhaft Pi-5V-Pin!)"
echo ""
echo "Pruefen, ob alles wirklich aktiv ist:"
echo "  curl http://localhost:8888/api/virtuals/elemax"
echo "  curl http://localhost:8888/api/audio/devices"
echo ""
echo "Falls die Web-UI (http://<host>.local:8888) bei manuellen Aenderungen"
echo "'Network Error' zeigt (bekannter Bug dieser LedFx-Version), immer per"
echo "curl auf dem Pi direkt aendern statt ueber die Oberflaeche."
echo ""
echo "Ton ist im LAN hoerbar unter:"
echo "  http://${TARGET_USER}.local:8000/stream.mp3"
echo "Jetzt zum Testen z.B. mit VLC/mpv/Browser auf dem MacBook oeffnen."
echo "Sobald spaeter ein Sonos-Lautsprecher im selben LAN ist, spielt er"
echo "denselben Stream automatisch ab (sonos-autoplay.service, per SoCo) -"
echo "kein manuelles Koppeln noetig. Details/Troubleshooting siehe README.md,"
echo "Abschnitt 'LAN-Streaming als Ausgabe'."
echo ""
echo "Status pruefen:"
echo "  sudo systemctl status raspotify led-udp-bridge ledfx icecast2 lan-audio-bridge sonos-autoplay"
echo "=================================================================="
