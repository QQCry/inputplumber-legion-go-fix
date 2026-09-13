#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Bitte mit sudo ausführen: sudo bash $0"
  exit 1
fi

echo "=========================================================="
echo "  Installiere InputPlumber mit DualSense 12x Gyro Support"
echo "=========================================================="

SOURCE_BIN="/home/qqcry/.local/bin/inputplumber-patched-dualsense-12x"

if [ ! -f "$SOURCE_BIN" ]; then
  echo "[-] Kompiliertes Binary nicht gefunden unter $SOURCE_BIN!"
  exit 1
fi

echo "[1/3] Stoppe inputplumber.service..."
systemctl stop inputplumber.service || true

echo "[2/3] Installiere neues Binary nach /usr/bin/inputplumber..."
if [ -f /usr/bin/inputplumber ] && [ ! -f /usr/bin/inputplumber.orig-ds5 ]; then
  cp /usr/bin/inputplumber /usr/bin/inputplumber.orig-ds5
  echo "      Backup erstellt unter /usr/bin/inputplumber.orig-ds5"
fi
cp "$SOURCE_BIN" /usr/bin/inputplumber
chmod 755 /usr/bin/inputplumber
cp /home/qqcry/fix-inputplumber.sh /usr/local/bin/fix-inputplumber 2>/dev/null || true

# Erstelle gyro_source Konfigurationsdatei falls noch nicht existent
mkdir -p /etc/inputplumber
if [ ! -f /etc/inputplumber/gyro_source ]; then
  echo "tablet" > /etc/inputplumber/gyro_source
fi
chmod 666 /etc/inputplumber/gyro_source 2>/dev/null || true

echo "[3/3] Starte inputplumber.service neu..."
systemctl daemon-reload
systemctl restart inputplumber.service

sleep 2
if systemctl is-active --quiet inputplumber.service; then
  echo ""
  echo "=========================================================="
  echo "[+] ERFOLG: InputPlumber ist aktualisiert & aktiv!"
  echo "    - Feste DualSense MAC-Adresse: Steam verliert keine Gyro-Kalibrierung mehr!"
  echo "    - Standard-Controller bleibt Steam Deck (deck-uhid) beim Booten"
  echo "    - Dynamischer Gyro-Umschalter aktiv (Tablet <-> Controller)"
  echo "=========================================================="
  echo "Sensor umschalten (jederzeit ohne Neustart möglich):"
  echo "  ~/set-gyro-source.sh controller   -> Rechter Controller-Sensor (angedockt)"
  echo "  ~/set-gyro-source.sh tablet       -> Interner Tablet-Sensor (Standard)"
  echo "  ~/set-gyro-source.sh status       -> Aktuellen Status anzeigen"
  echo "=========================================================="
  echo "Du kannst die Bewegungssensoren jetzt live testen mit:"
  echo "  python3 ~/test-dualsense-gyro.py"
  echo "=========================================================="
else
  echo "[-] Fehler beim Starten von inputplumber.service!"
  journalctl -u inputplumber.service -n 20 --no-pager
  exit 1
fi
