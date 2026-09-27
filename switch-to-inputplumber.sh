#!/usr/bin/env bash
set -e

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo:"
  echo "    sudo bash $0"
  exit 1
fi

echo "[1/5] Stopping and disabling Handheld Daemon (HHD)..."
systemctl stop hhd@qqcry.service 2>/dev/null || true
systemctl disable hhd@qqcry.service 2>/dev/null || true
systemctl stop hhd.service 2>/dev/null || true
systemctl disable hhd.service 2>/dev/null || true

echo "[2/5] Installing InputPlumber..."
pacman -S --needed --noconfirm inputplumber

echo "[3/5] Configuring InputPlumber for 'deck-uhid' (Steam Deck emulation with gyro & ABXY)..."
mkdir -p /etc/inputplumber/devices.d

# Copy profile for Legion Go and configure for deck-uhid
if [ -f /usr/share/inputplumber/devices/50-legion_go.yaml ]; then
  cp /usr/share/inputplumber/devices/50-legion_go.yaml /etc/inputplumber/devices.d/50-legion_go.yaml
elif [ -f /usr/share/inputplumber/devices/50-legion_go.yaml.bak ]; then
  cp /usr/share/inputplumber/devices/50-legion_go.yaml.bak /etc/inputplumber/devices.d/50-legion_go.yaml
fi

# Replace xbox-elite with deck-uhid
sed -i 's/xbox-elite/deck-uhid/g' /etc/inputplumber/devices.d/50-legion_go.yaml

# Ensure accel_3d is configured alongside gyro_3d
if ! grep -q "name: accel_3d" /etc/inputplumber/devices.d/50-legion_go.yaml; then
  sed -i '/name: gyro_3d/{n;N;N;N;a\  - group: imu\n    iio:\n      name: accel_3d\n      mount_matrix:\n        x: [0, 1, 0]\n        y: [-1, 0, 0]\n        z: [0, 0, 1]
}' /etc/inputplumber/devices.d/50-legion_go.yaml
fi

echo "[4/5] Enabling and starting InputPlumber service..."
systemctl daemon-reload
systemctl enable --now inputplumber.service

echo "[5/5] Checking status..."
sleep 2
if systemctl is-active --quiet inputplumber.service; then
  echo "[+] InputPlumber is running successfully!"
  echo ""
  echo "=========================================================="
  echo "Migration complete!"
  echo "Steam now recognizes the Legion Go as a Steam Deck controller."
  echo "-> Native ABXY glyphs in all games"
  echo "-> Full gyro and touchpad support"
  echo ""
  echo "Recommendation: Restart your system or restart Steam now."
  echo "=========================================================="
else
  echo "[!] Failed to start InputPlumber. Check with: journalctl -u inputplumber -n 50"
fi
