#!/usr/bin/env bash
set -e

MULT_FILE="/etc/inputplumber/ds5_gyro_multiplier"

FACTOR="${1:-1.0}"

# Validierung: Zahl oder Fließkommazahl
if ! [[ "$FACTOR" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "[-] Ungültiger Faktor: '$FACTOR'. Bitte gib eine Zahl ein (z. B. 0.5, 1.0, 1.5, 2.0)."
  exit 1
fi

if [ -w "$MULT_FILE" ]; then
  echo "$FACTOR" > "$MULT_FILE"
elif [ "$EUID" -eq 0 ]; then
  mkdir -p /etc/inputplumber
  echo "$FACTOR" > "$MULT_FILE"
  chmod 666 "$MULT_FILE"
else
  echo "[*] Datei benötigt Root-Rechte zur Anpassung..."
  echo "$FACTOR" | sudo tee "$MULT_FILE" >/dev/null
  sudo chmod 666 "$MULT_FILE"
fi

echo "[+] DS5 Gyro-Multiplikator erfolgreich auf ${FACTOR}x gesetzt ($MULT_FILE)."
echo "[*] InputPlumber übernimmt die neue Geschwindigkeit automatisch in Echtzeit (innerhalb von 1 Sekunde)!"
