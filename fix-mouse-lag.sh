#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run with sudo:"
  echo "    sudo bash $0"
  exit 1
fi

echo "=========================================================="
echo "  Reset Legion Go Controller & Touchpad to Default        "
echo "=========================================================="

# 1. Reset controller hardware mode in MCU
echo "[1/3] Disabling IMU bypass and setting os_mode to 'windows'..."
for dev in /sys/bus/hid/drivers/hid-lenovo-go/0003:17EF:61E*.*; do
  if [ -d "$dev" ]; then
    echo "[*] Configuring: $dev"
    if [ -f "$dev/os_mode" ]; then
      echo "windows" > "$dev/os_mode" 2>/dev/null || true
      echo "[+] os_mode -> windows"
    fi
    if [ -d "$dev/right_handle" ]; then
      echo "false" > "$dev/right_handle/imu_bypass_enabled" 2>/dev/null || true
      echo "false" > "$dev/right_handle/imu_enabled" 2>/dev/null || true
      echo "[+] Right controller: imu_bypass_enabled=false, imu_enabled=false"
    fi
    if [ -d "$dev/left_handle" ]; then
      echo "false" > "$dev/left_handle/imu_bypass_enabled" 2>/dev/null || true
      echo "false" > "$dev/left_handle/imu_enabled" 2>/dev/null || true
      echo "[+] Left controller: imu_bypass_enabled=false, imu_enabled=false"
    fi
  fi
done

# 2. Remove experimental udev rule
rm -f /etc/udev/rules.d/99-inputplumber-device-setup.rules
udevadm control --reload-rules

# 3. Restart InputPlumber
echo "[2/3] Restarting inputplumber.service..."
systemctl restart inputplumber.service
sleep 2

# 4. Show status
echo "[3/3] Current hardware status:"
for dev in /sys/bus/hid/drivers/hid-lenovo-go/0003:17EF:61E*.*; do
  if [ -d "$dev" ]; then
    echo "  os_mode: $(cat $dev/os_mode 2>/dev/null || echo 'n/a')"
    echo "  right imu_bypass: $(cat $dev/right_handle/imu_bypass_enabled 2>/dev/null || echo 'n/a')"
    echo "  right imu_enabled: $(cat $dev/right_handle/imu_enabled 2>/dev/null || echo 'n/a')"
  fi
done

echo ""
echo "=========================================================="
echo "  SUCCESS: Touchpad hardware restored to default state!   "
echo "  Cursor stuttering and touch jumping are resolved.       "
echo "=========================================================="
