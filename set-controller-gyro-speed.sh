#!/usr/bin/env bash
set -e

SPEED_FILE="/etc/inputplumber/controller_gyro_speed"

if [ -z "$1" ]; then
  CURRENT="0.7"
  [ -f "$SPEED_FILE" ] && CURRENT=$(cat "$SPEED_FILE")
  echo "Aktueller Controller-Gyrospeed: ${CURRENT}x"
  echo "Verwendung: $0 <faktor> (z. B. 0.7, 0.6, 0.8, 1.0)"
  exit 0
fi

FACTOR="$1"

# Validation
if ! [[ "$FACTOR" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "[-] Ungültiger Faktor: '$FACTOR'. Bitte eine Zahl angeben (z. B. 0.7, 0.8)."
  exit 1
fi

echo "$FACTOR" | sudo tee "$SPEED_FILE" > /dev/null
sudo chmod 666 "$SPEED_FILE"

echo "[+] Controller-Gyrospeed erfolgreich auf ${FACTOR}x gesetzt!"
echo "[*] InputPlumber wendet den neuen Wert innerhalb von 1 Sekunde im laufenden Betrieb an."
