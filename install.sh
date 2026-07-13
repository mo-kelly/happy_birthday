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

echo "==> [1/11] Paketquellen aktualisieren"
apt-get update

echo "==> [2/11] Systempakete installieren"
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
    git

echo "==> [3/11] SPI aktivieren (fuer Pi5Neo/WS2812 ueber GPIO10)"
raspi-config nonint do_spi 0

echo "==> [4/11] snd-aloop (ALSA Loopback) aktivieren, Index 2 (0/1 sind bei"
echo "    Pi 5 durch die beiden HDMI-Ausgaenge belegt)"
mkdir -p /etc/modules-load.d
if ! grep -q "^snd-aloop" /etc/modules-load.d/snd-aloop.conf 2>/dev/null; then
    echo "snd-aloop" > /etc/modules-load.d/snd-aloop.conf
fi
cat > /etc/modprobe.d/snd-aloop.conf <<'EOF'
options snd-aloop enable=1 index=2
EOF
modprobe snd-aloop || true

echo "==> [5/11] ALSA-Basiskonfiguration schreiben"
echo "    (kein physischer Lautsprecher/DAC vorhanden -> default zeigt direkt"
echo "    auf das Loopback-Device, siehe Kommentar oben im Script)"
cat > /etc/asound.conf <<'EOF'
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

echo "==> [6/11] Raspotify installieren (Spotify Connect)"
if ! dpkg -l | grep -q raspotify; then
    curl -sL https://dtcooper.github.io/raspotify/install.sh | sh
fi

cat > /etc/raspotify/conf <<EOF
LIBRESPOT_NAME="$TARGET_USER"
LIBRESPOT_DEVICE="hw:Loopback,0,0"
LIBRESPOT_QUIET=
TMPDIR=/tmp
EOF

echo "==> [7/11] Pi5Neo installieren (WS281x ueber SPI)"
python3 -m pip install --user pi5neo --break-system-packages
python3 -m pip install pi5neo --break-system-packages

echo "==> [8/11] LED-UDP-Bridge-Script installieren + systemd-Unit anlegen"
mkdir -p "$REPO_DIR/scripts"
chmod +x "$REPO_DIR/scripts/led_udp_bridge.py"
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

echo "==> [9/11] LedFx installieren + systemd-Unit anlegen"
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

echo "==> [10/11] Dienste aktivieren und starten"
systemctl daemon-reload
systemctl enable --now led-udp-bridge
systemctl enable --now ledfx
systemctl enable --now raspotify

echo "==> [11/11] LedFx-Geraet/Virtual/Effekt/Audioquelle per API einrichten"
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
# ledfx/api/audio_devices.py im installierten Paket). Device-Index 1 ist bei
# unserem Loopback-Setup die Aufnahmeseite ("hw:Loopback,1,0").
curl -s -X PUT http://localhost:8888/api/audio/devices \
    -H "Content-Type: application/json" \
    -d '{"audio_device": 1}' \
    > /dev/null || true

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
echo "Status pruefen:"
echo "  sudo systemctl status raspotify led-udp-bridge ledfx"
echo "=================================================================="
