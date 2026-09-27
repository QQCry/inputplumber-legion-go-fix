#!/usr/bin/env bash
set -e

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo:"
  echo "    sudo bash $0"
  exit 1
fi

echo "[1/3] Stopping and disabling InputPlumber..."
systemctl stop inputplumber.service 2>/dev/null || true
systemctl disable inputplumber.service 2>/dev/null || true

echo "[2/3] Enabling and starting Handheld Daemon (HHD)..."
systemctl daemon-reload
systemctl enable --now hhd@qqcry.service

echo "[3/3] Checking status..."
sleep 2
if systemctl is-active --quiet hhd@qqcry.service; then
  echo "[+] HHD is running successfully!"
  echo "=========================================================="
  echo "Rollback complete: HHD (DualSense emulation) is active again."
  echo "=========================================================="
else
  echo "[!] Failed to start HHD. Check with: journalctl -u hhd@qqcry -n 50"
fi
