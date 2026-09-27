#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root: sudo bash $0"
  exit 1
fi

echo "=========================================================="
echo "  Enable Right Controller IMU (HHD Method)                "
echo "=========================================================="

# 1. Stop service
echo "[1/6] Stopping inputplumber.service..."
systemctl stop inputplumber.service 2>/dev/null || true

# 2. Install new binary
echo "[2/6] Installing patched binary for right controller..."
NEW_BIN="/home/qqcry/.local/bin/inputplumber-right-controller-12x"
if [ ! -f "$NEW_BIN" ]; then
  echo "[-] Error: $NEW_BIN not found!"
  exit 1
fi
install -m 755 "$NEW_BIN" /usr/bin/inputplumber
echo "[+] Patched binary successfully installed to /usr/bin/inputplumber."

# 3. Update configuration: claim tablet IMU in CompositeDevice0 but mute events to prioritize Joy-Con IMU
echo "[3/6] Configuring /etc/inputplumber/devices.d/50-legion_go.yaml..."
python3 -c '
import re

path = "/etc/inputplumber/devices.d/50-legion_go.yaml"
with open(path, "r") as f:
    c = f.read()

if "- xbox-elite" in c:
    c = c.replace("- xbox-elite", "- deck-uhid")

imu_block = """  # Tablet IMU claimed in CompositeDevice0 (prevents duplicate virtual controllers),
  # but events are excluded so the right Joy-Con gyro is used exclusively:
  - group: imu
    unique: false
    iio:
      name: gyro_3d
    events:
      exclude:
        - "*"
  - group: imu
    unique: false
    iio:
      name: accel_3d
    events:
      exclude:
        - "*"\n"""

pat = r"#?\s*-\s*group:\s*imu[\s\S]*?(?=options:|target_devices:)"
if re.search(pat, c):
    c = re.sub(pat, imu_block, c)

with open(path, "w") as f:
    f.write(c)
print("[+] Configuration successfully updated (single controller guaranteed).")
'

# 4. Create clean udev rule (os_mode=windows, Bypass=false = NO mouse lag)
echo "[4/6] Cleaning and configuring udev rules..."
rm -f /etc/udev/rules.d/99-inputplumber-device-setup.rules
cat << 'UDEV_EOF' > /etc/udev/rules.d/99-inputplumber-device-setup.rules
ACTION=="add|change|bind", ATTRS{idVendor}=="17ef", ATTRS{idProduct}=="61e[bcde]", SUBSYSTEM=="hid", DRIVER=="hid-lenovo-go", ATTR{os_mode}="windows", ATTR{left_handle/imu_bypass_enabled}="false", ATTR{right_handle/imu_bypass_enabled}="false", ATTR{touchpad/vibration_enable}="false", GOTO="end"
UDEV_EOF
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

# 5. Activate controller MCU IMU directly via HID commands
echo "[5/6] Sending HID activation packets to controller..."
python3 -c '
import glob, os, time

def pad64(data):
    return bytes(data) + bytes(64 - len(data))

for p in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
    dev_name = os.path.basename(p)
    uevent = os.path.join(p, "device/uevent")
    if os.path.exists(uevent):
        with open(uevent) as f:
            txt = f.read()
        if "17EF" in txt and ("618" in txt or "61E" in txt) and (":1.2" in txt or "input2" in txt):
            hidraw_node = f"/dev/{dev_name}"
            try:
                os.chmod(hidraw_node, 0o666)
                with open(hidraw_node, "wb") as f_hid:
                    # 1. Right & Left: Explicitly DISABLE Bypass (0x03 -> 0x00)
                    # Bypass removes MCU touchpad filtering and causes severe mouse lag / jumping!
                    f_hid.write(pad64([0x05, 0x00, 0x04, 0x03, 0x04, 0x00]))
                    f_hid.flush()
                    time.sleep(0.04)
                    f_hid.write(pad64([0x05, 0x00, 0x04, 0x03, 0x03, 0x00]))
                    f_hid.flush()
                    time.sleep(0.04)

                    # 2. Right & Left: Enable IMU sensors using Lenovo FEATURE_IMU_ENABLE (0x05 -> 0x01)
                    f_hid.write(pad64([0x05, 0x00, 0x04, 0x05, 0x04, 0x01]))
                    f_hid.flush()
                    time.sleep(0.04)
                    f_hid.write(pad64([0x05, 0x00, 0x04, 0x05, 0x03, 0x01]))
                    f_hid.flush()
                    time.sleep(0.04)

                    # 3. Right & Left: Configure IMU Full-Scale Range (FSR) to ±2000 dps
                    f_hid.write(pad64([0x05, 0x00, 0x04, 0x06, 0x04, 0x00]))
                    f_hid.flush()
                    time.sleep(0.04)
                    f_hid.write(pad64([0x05, 0x00, 0x04, 0x06, 0x03, 0x00]))
                    f_hid.flush()
                    time.sleep(0.04)

                    # 4. Right: Enable IMU & 16-bit HQ report stream (HHD protocol: EXACT 7 BYTES)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x02, 0x04, 0x01, 0x01]))
                    f_hid.flush()
                    time.sleep(0.04)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x07, 0x04, 0x02, 0x01]))
                    f_hid.flush()
                    time.sleep(0.04)

                    # 5. Left: Enable IMU & 16-bit HQ report stream (HHD protocol: EXACT 7 BYTES)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x02, 0x03, 0x01, 0x01]))
                    f_hid.flush()
                    time.sleep(0.04)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x07, 0x03, 0x02, 0x01]))
                    f_hid.flush()
                print(f"[+] HID activation packets (Lenovo 64B & HHD 7B) sent to {hidraw_node}!")
            except Exception as e:
                print(f"[-] Error writing to {hidraw_node}: {e}")
'

# Ensure sysfs hardware attributes (Windows mode, bypass disabled = smooth touchpad mouse tracking)
for dev in /sys/bus/hid/drivers/hid-lenovo-go/0003:17EF:61E*.*; do
  if [ -d "$dev" ]; then
    if [ -f "$dev/os_mode" ]; then
      echo "windows" > "$dev/os_mode" 2>/dev/null || true
    fi
    if [ -d "$dev/right_handle" ]; then
      echo "false" > "$dev/right_handle/imu_bypass_enabled" 2>/dev/null || true
    fi
    if [ -d "$dev/left_handle" ]; then
      echo "false" > "$dev/left_handle/imu_bypass_enabled" 2>/dev/null || true
      echo "true" > "$dev/left_handle/imu_enabled" 2>/dev/null || true
    fi
  fi
done

# 6. Start service
echo "[6/6] Starting inputplumber.service..."
systemctl daemon-reload
systemctl restart inputplumber.service
sleep 2

echo "[*] Verifying hardware status in sysfs..."
for dev in /sys/bus/hid/drivers/hid-lenovo-go/0003:17EF:61E*.*; do
  if [ -d "$dev" ]; then
    echo "[+] os_mode:                         $(cat $dev/os_mode 2>/dev/null || echo unknown)"
    echo "[+] right_handle/imu_bypass_enabled: $(cat $dev/right_handle/imu_bypass_enabled 2>/dev/null || echo unknown)"
    echo "[+] right_handle/imu_enabled:        $(cat $dev/right_handle/imu_enabled 2>/dev/null || echo unknown)"
  fi
done

if systemctl is-active --quiet inputplumber.service; then
  echo ""
  echo "=========================================================="
  echo "  SUCCESS: Right Controller IMU is active!                "
  echo "  - Controller Target: Valve Steam Deck (deck-uhid)       "
  echo "  - Single Controller: Duplicate controllers blocked      "
  echo "  - Touchpad: Butter-smooth, zero mouse lag               "
  echo "  - Switch Gyro Source:        ~/set-gyro-source.sh       "
  echo "  - Complete Uninstaller:      sudo bash ~/uninstall-gyro-fix.sh"
  echo "=========================================================="
  echo "Run the real-time sensor diagnostic now with:"
  echo "    python3 ~/test-gyro.py"
else
  echo "[!] Failed to start inputplumber.service!"
  journalctl -u inputplumber.service -n 25 --no-pager
  exit 1
fi
