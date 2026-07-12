#!/usr/bin/env bash
#
# switch-audio-output.sh - schaltet die physische Audioausgabe manuell zwischen
# USB-DAC und einem PulseAudio-Ziel im LAN um.
#
# Usage:
#   sudo ./switch-audio-output.sh usb --card <index>
#   sudo ./switch-audio-output.sh lan --server <ip-oder-hostname>
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Bitte mit sudo ausfuehren." >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
shift || true

CARD=""
SERVER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --card) CARD="$2"; shift 2 ;;
        --server) SERVER="$2"; shift 2 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 1 ;;
    esac
done

case "$MODE" in
    usb)
        if [[ -z "$CARD" ]]; then
            echo "Fehler: --card <index> erforderlich (siehe 'aplay -l')." >&2
            exit 1
        fi
        SNIPPET="$(sed "s/{{CARD}}/${CARD}/g" "$REPO_DIR/config/physical-usb.conf.snippet")"
        ;;
    lan)
        if [[ -z "$SERVER" ]]; then
            echo "Fehler: --server <ip-oder-hostname> erforderlich." >&2
            exit 1
        fi
        SNIPPET="$(sed "s/{{SERVER}}/${SERVER}/g" "$REPO_DIR/config/physical-lan.conf.snippet")"
        ;;
    *)
        echo "Usage: $0 usb --card <index> | lan --server <ip>" >&2
        exit 1
        ;;
esac

TMP_FILE="$(mktemp)"
awk -v snippet="$SNIPPET" '
    /\{\{PHYSICAL_PCM\}\}/ { print snippet; next }
    { print }
' "$REPO_DIR/config/asound.conf.template" > "$TMP_FILE"

cp "$TMP_FILE" /etc/asound.conf
rm -f "$TMP_FILE"

echo "Audioausgabe auf '$MODE' gesetzt, /etc/asound.conf aktualisiert."

echo "Starte librespot und ledfx neu..."
systemctl restart librespot ledfx || true

echo "Fertig. Test: speaker-test -D physical -c 2"
