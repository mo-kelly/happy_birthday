#!/usr/bin/env bash
#
# install.sh - richtet den Raspberry Pi als Spotify-Connect-Lautsprecher mit
# LedFx-gesteuertem WS281x-LED-Streifen ein.
#
# Ausfuehren mit: sudo ./install.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Bitte mit sudo ausfuehren." >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-pi}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

echo "==> Paketquellen aktualisieren"
apt-get update

echo "==> Systempakete installieren"
apt-get install -y \
    librespot \
    alsa-utils \
    libasound2-plugins \
    pulseaudio-utils \
    python3 \
    python3-pip \
    python3-venv \
    git

echo "==> snd-aloop (ALSA Loopback) aktivieren"
if ! grep -q "^snd-aloop" /etc/modules 2>/dev/null; then
    echo "snd-aloop" >> /etc/modules
fi
modprobe snd-aloop || true
cat > /etc/modprobe.d/snd-aloop.conf <<'EOF'
options snd-aloop enable=1 index=1
EOF

echo "==> librespot-Konfiguration installieren"
cp "$REPO_DIR/config/librespot.env" /etc/default/librespot

echo "==> Standard-ALSA-Konfiguration (USB, Kartenindex 0) setzen"
"$REPO_DIR/scripts/switch-audio-output.sh" usb --card 0 || true

echo "==> Python-Abhaengigkeiten fuer LedFx und LED-Bridge installieren"
sudo -u "$TARGET_USER" python3 -m pip install --user --upgrade pip
sudo -u "$TARGET_USER" python3 -m pip install --user ledfx
python3 -m pip install rpi_ws281x

echo "==> LedFx-Grundkonfiguration kopieren"
mkdir -p "$TARGET_HOME/.ledfx"
cp "$REPO_DIR/config/ledfx_config.yaml" "$TARGET_HOME/.ledfx/config.yaml"
chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.ledfx"

echo "==> Repo-Kopie fuer systemd-Pfade sicherstellen"
if [[ "$REPO_DIR" != "$TARGET_HOME/happy_birthday" ]]; then
    echo "Hinweis: systemd-Units erwarten das Repo unter $TARGET_HOME/happy_birthday."
    echo "Aktueller Pfad: $REPO_DIR"
fi

echo "==> systemd-Units installieren"
cp "$REPO_DIR"/systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable librespot led-udp-bridge ledfx

echo ""
echo "Installation abgeschlossen."
echo "Audioausgabe pruefen/umschalten mit: sudo ./scripts/switch-audio-output.sh usb|lan ..."
echo "Neustart empfohlen: sudo reboot"
