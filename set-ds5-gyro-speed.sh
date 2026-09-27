#!/usr/bin/env bash
set -e

MULT_FILE="/etc/inputplumber/ds5_gyro_multiplier"

FACTOR="${1:-1.0}"

# Validation: integer or floating-point number
if ! [[ "$FACTOR" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "[-] Invalid factor: '$FACTOR'. Please specify a valid number (e.g. 0.5, 1.0, 1.5, 2.0)."
  exit 1
fi

if [ -w "$MULT_FILE" ]; then
  echo "$FACTOR" > "$MULT_FILE"
elif [ "$EUID" -eq 0 ]; then
  mkdir -p /etc/inputplumber
  echo "$FACTOR" > "$MULT_FILE"
  chmod 666 "$MULT_FILE"
else
  echo "[*] File requires root privileges to modify..."
  echo "$FACTOR" | sudo tee "$MULT_FILE" >/dev/null
  sudo chmod 666 "$MULT_FILE"
fi

echo "[+] DS5 gyro multiplier successfully set to ${FACTOR}x ($MULT_FILE)."
echo "[*] InputPlumber will automatically apply the new rate in real-time (within 1 second)!"
