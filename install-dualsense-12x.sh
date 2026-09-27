#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run with sudo: sudo bash $0"
  exit 1
fi

echo "=========================================================="
echo "  Install InputPlumber with DualSense 12x Gyro Support    "
echo "=========================================================="

SOURCE_BIN="/home/qqcry/.local/bin/inputplumber-patched-dualsense-12x"

if [ ! -f "$SOURCE_BIN" ]; then
  echo "[-] Compiled binary not found at $SOURCE_BIN!"
  exit 1
fi

echo "[1/3] Stopping inputplumber.service..."
systemctl stop inputplumber.service || true

echo "[2/3] Installing new binary to /usr/bin/inputplumber..."
if [ -f /usr/bin/inputplumber ] && [ ! -f /usr/bin/inputplumber.orig-ds5 ]; then
  cp /usr/bin/inputplumber /usr/bin/inputplumber.orig-ds5
  echo "      Backup created at /usr/bin/inputplumber.orig-ds5"
fi
cp "$SOURCE_BIN" /usr/bin/inputplumber
chmod 755 /usr/bin/inputplumber
cp /home/qqcry/fix-inputplumber.sh /usr/local/bin/fix-inputplumber 2>/dev/null || true

# Create gyro_source config file if not existing
mkdir -p /etc/inputplumber
if [ ! -f /etc/inputplumber/gyro_source ]; then
  echo "tablet" > /etc/inputplumber/gyro_source
fi
chmod 666 /etc/inputplumber/gyro_source 2>/dev/null || true

echo "[3/3] Restarting inputplumber.service..."
systemctl daemon-reload
systemctl restart inputplumber.service

sleep 2
if systemctl is-active --quiet inputplumber.service; then
  echo ""
  echo "=========================================================="
  echo "[+] SUCCESS: InputPlumber is updated & running!"
  echo "    - Static DualSense MAC address: Steam never loses calibration!"
  echo "    - Default target remains Steam Deck (deck-uhid) on boot"
  echo "    - Dynamic gyro switch active (Tablet <-> Controller)"
  echo "=========================================================="
  echo "Switch sensor anytime without restarting:"
  echo "  ~/set-gyro-source.sh controller   -> Right controller sensor (docked)"
  echo "  ~/set-gyro-source.sh tablet       -> Internal tablet sensor (default)"
  echo "  ~/set-gyro-source.sh status       -> Show current active sensor"
  echo "=========================================================="
  echo "You can test motion sensors in real-time with:"
  echo "  python3 ~/test-dualsense-gyro.py"
  echo "=========================================================="
else
  echo "[-] Failed to start inputplumber.service!"
  journalctl -u inputplumber.service -n 20 --no-pager
  exit 1
fi
