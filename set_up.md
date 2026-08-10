# Happy Birthday! Mit dem Folgenden Setup kann wird der Rasberry Pi be spotify als Lautsprecher angezeigt und kann  LEDs und Musik parallel steuern. Unabhängig von diesem Projekt glaube ich, dass du mit dem Rasberry sehr viel Spaß haben wirst! Alles gute zum Geburtstag, ich lieble dich <3 

# Pi in neuem WLAN mit neuer Bluetooth-Box einrichten

Komplettanleitung, um das happy_birthday-Setup (Branch `max_bluetooth`) an
einem neuen Standort mit neuem WLAN und neuer Bluetooth-Box zum Laufen zu
bringen.

Platzhalter zum Ersetzen:
- `<WLAN-SSID>` / `<WLAN-PASSWORT>` – neues WLAN
- `<user>` – Benutzername auf dem Pi (bisher: `happybirthday`)
- `<hostname>` – Hostname des Pi (bisher: `happybirthday`)
- `<BOX-MAC>` – MAC-Adresse der Bluetooth-Box, Format `XX:XX:XX:XX:XX:XX`
- `<SINK-NAME>` – PipeWire-Sink-Name, Format `bluez_output.XX_XX_XX_XX_XX_XX.1`

---

## 1. SD-Karte flashen

Raspberry Pi Imager → Raspberry Pi OS Lite → erweiterte Einstellungen
(Zahnrad):
- SSH aktivieren (Passwort-Auth)
- Hostname setzen: `<hostname>`
- Benutzername/Passwort setzen
- WLAN: `<WLAN-SSID>` / `<WLAN-PASSWORT>` (SSID genau prüfen)

## 2. Pi booten und per SSH verbinden

```bash
ssh <user>@<hostname>.local
```

**Falls Warnung "REMOTE HOST IDENTIFICATION HAS CHANGED"** (normal nach
Neuflashen unter gleichem Hostname – der Pi hat einen neuen SSH-Key):

```bash
ssh-keygen -R <hostname>.local
ssh <user>@<hostname>.local
```

Bei "Are you sure you want to continue connecting?" mit `yes` bestätigen.

## 3. Repo klonen (auf dem Pi)

```bash
git clone -b max_bluetooth https://github.com/mo-kelly/happy_birthday.git
cd happy_birthday
```

## 4. install.sh ausführen

```bash
chmod +x install.sh
sudo ./install.sh
```

Dauer ca. 5–10 Minuten. Installiert Raspotify, Pi5Neo, LedFx, aktiviert SPI,
richtet ALSA-Loopback und alle systemd-Dienste ein.

Danach prüfen:
```bash
curl http://localhost:8888/api/virtuals/elemax
curl http://localhost:8888/api/audio/devices
```

## 5. LED-Streifen verkabeln

**Kurztest ohne externes Netzteil** (nur wenige LEDs, reduzierte Helligkeit):

| Funktion | Pin | Übliche Kabelfarbe* |
|---|---|---|
| DIN (Data) | Pin 19 | meist Grün/Gelb |
| GND | Pin 6 | meist Schwarz/Weiß |
| 5V | Pin 2 oder Pin 4 | meist Rot |


## 6. Neue Bluetooth-Box koppeln (einmalig, physischer Knopfdruck nötig)

Box in Pairing-Modus bringen (ggf. vorher von Handy/Laptop trennen, sonst
geht sie nicht in den Pairing-Modus). Dann auf dem Pi:

```bash
bluetoothctl
power on
agent on
scan on
# warten, bis <BOX-MAC> in der Liste auftaucht
scan off
pair <BOX-MAC>
trust <BOX-MAC>
connect <BOX-MAC>
exit
```

## 7. Sink-Namen ermitteln

```bash
pactl list sinks short
```

Zeile mit `bluez_output.<...>` notieren → `<SINK-NAME>`.

## 8. MAC und Sink-Namen im Code anpassen (nur falls andere Box als zuvor)

Lokal auf dem Mac im Repo (Branch `max_bluetooth`):

- `scripts/led_udp_bridge.py` → Konstante `BOSE_MAC` auf `<BOX-MAC>` setzen
- `systemd/bt-bridge-bose.service` → `--device=<...>` auf `<SINK-NAME>` setzen

```bash
git add scripts/led_udp_bridge.py systemd/bt-bridge-bose.service
git commit -m "Neue Bluetooth-Box: MAC und Sink aktualisiert"
git push
```

## 9. Auf dem Pi: Änderungen holen und Dienste einrichten

```bash
cd ~/happy_birthday
git pull
mkdir -p ~/.config/systemd/user
cp systemd/bt-bridge-bose.service ~/.config/systemd/user/
sudo systemctl restart led-udp-bridge
systemctl --user daemon-reload
systemctl --user enable --now bt-bridge-bose
```

## 10. Linger aktivieren (falls noch nicht geschehen)

Sorgt dafür, dass PipeWire/die Bridge auch ohne aktive SSH-Session
weiterläuft:

```bash
loginctl show-user <user> | grep Linger
sudo loginctl enable-linger <user>   # falls nicht aktiv
```

## 11. Logs prüfen

```bash
journalctl -u led-udp-bridge -n 30
```

Sollte Zeilen von `connect_bose` zeigen (Verbindungsversuch bzw. Erfolg).
Box muss dafür eingeschaltet und in Reichweite sein, sonst läuft der
Connect-Versuch nach 10 Versuchen (à 3s) in den Timeout.

## 12. Kompletttest per Reboot

```bash
sudo reboot
```

Erwarteter Ablauf danach:
1. LED-Lauflicht (Startup-Animation)
2. Automatischer Verbindungsversuch zur Bluetooth-Box
3. Bei Erfolg: kurzes grünes Bestätigungsblinken
4. Ton über die Box hörbar, sobald Spotify abspielt
5. LEDs reagieren audioreaktiv auf die Musik

---

## Dienste im Überblick

| Dienst | Zweck |
|---|---|
| `raspotify.service` | Spotify-Connect-Empfang |
| `led-udp-bridge.service` | UDP → SPI, LED-Steuerung, Bose-Connect + Blink |
| `ledfx.service` | Audioanalyse + Effektberechnung |
| `bt-bridge-bose.service` (Nutzer-Dienst) | Ton an die Bluetooth-Box |
| `pipewire`, `pipewire-pulse`, `wireplumber` (Nutzer-Dienste) | Bluetooth-Audio-Backend |

Status: `sudo systemctl status raspotify ledfx led-udp-bridge`
Bluetooth-Bridge: `systemctl --user status bt-bridge-bose pipewire pipewire-pulse wireplumber`
