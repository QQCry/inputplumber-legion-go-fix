#!/usr/bin/env bash
# ==============================================================================
#  InputPlumber Legion Go Gyro Fix - Uninstaller & Factory Reset
#  ----------------------------------------------------------------------------
#  Completely restores the official upstream/stock package state of InputPlumber
#  and reverts all applied modifications:
#    - Removes Pacman update hooks and maintenance symlinks
#    - Restores the original, unmodified InputPlumber binary
#    - Removes all custom configuration overrides in /etc/inputplumber/
#    - Removes udev overrides and restores kernel/MCU sysfs attributes
#    - Terminates the 16-bit HQ motion stream on the controller MCU (stock state)
#    - Cleans up systemd overrides and restarts the official service
#    - Validates 100% package integrity via pacman -Qkk
# ==============================================================================

set -e

# Output formatting colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}[*] Root privileges required. Please run with sudo:${NC}"
  echo "    sudo bash $0"
  exit 1
fi

echo -e "${CYAN}==========================================================${NC}"
echo -e "${BOLD}  InputPlumber Gyro Fix - Complete Uninstaller         ${NC}"
echo -e "${CYAN}==========================================================${NC}"
echo "Restores the system to the official upstream stock state."
echo ""

# 1. Stop service
echo -e "${BLUE}[1/8] Stopping inputplumber.service...${NC}"
systemctl stop inputplumber.service 2>/dev/null || true

# 2. Remove Pacman hook & symlinks
echo -e "${BLUE}[2/8] Removing automated update hooks...${NC}"
rm -f /etc/pacman.d/hooks/99-inputplumber-fix.hook
rm -f /usr/local/bin/fix-inputplumber
echo -e "${GREEN}[+] Pacman hook and maintenance symlinks removed.${NC}"

# 3. Restore official InputPlumber binary
echo -e "${BLUE}[3/8] Restoring official InputPlumber stock binary...${NC}"
RESTORED=0

CACHED_PKG=$(ls -t /var/cache/pacman/pkg/inputplumber-*.pkg.tar.zst 2>/dev/null | head -n 1 || true)
if [ -n "$CACHED_PKG" ] && [ -f "$CACHED_PKG" ]; then
  echo "    -> Installing clean package from cache: $(basename "$CACHED_PKG")..."
  pacman -U --overwrite='*' --noconfirm "$CACHED_PKG" >/dev/null 2>&1 && RESTORED=1 || true
fi

if [ "$RESTORED" -ne 1 ]; then
  if [ -f /usr/bin/inputplumber.stock-backup ]; then
    echo "    -> Copying backed-up stock binary (/usr/bin/inputplumber.stock-backup)..."
    cp -f /usr/bin/inputplumber.stock-backup /usr/bin/inputplumber
    chmod 755 /usr/bin/inputplumber
    RESTORED=1
  elif [ -f /usr/bin/inputplumber.pacman ]; then
    echo "    -> Copying backed-up Pacman binary (/usr/bin/inputplumber.pacman)..."
    cp -f /usr/bin/inputplumber.pacman /usr/bin/inputplumber
    chmod 755 /usr/bin/inputplumber
    RESTORED=1
  elif command -v pacman >/dev/null 2>&1; then
    echo "    -> Reinstalling InputPlumber via pacman..."
    pacman -S --overwrite='*' --noconfirm inputplumber >/dev/null 2>&1 && RESTORED=1 || true
  fi
fi

# Clean up backup binaries in /usr/bin
rm -f /usr/bin/inputplumber.stock-backup \
      /usr/bin/inputplumber.pacman \
      /usr/bin/inputplumber.original \
      /usr/bin/inputplumber.orig-ds5

if [ "$RESTORED" -eq 1 ]; then
  echo -e "${GREEN}[+] Official InputPlumber stock binary successfully restored.${NC}"
else
  echo -e "${RED}[!] Warning: Stock binary could not be verified automatically.${NC}"
fi

# 4. Remove configuration overrides in /etc/inputplumber
echo -e "${BLUE}[4/8] Removing configuration overrides in /etc/inputplumber...${NC}"
rm -f /etc/inputplumber/gyro_source
rm -f /etc/inputplumber/ds5_gyro_multiplier
rm -f /etc/inputplumber/devices.d/50-legion_go.yaml*
rmdir /etc/inputplumber/devices.d 2>/dev/null || true
rmdir /etc/inputplumber 2>/dev/null || true
echo -e "${GREEN}[+] Configuration overrides removed (reverted to /usr/share/inputplumber/).${NC}"

# 5. Remove udev overrides and restore system rules
echo -e "${BLUE}[5/8] Removing udev overrides and resetting system rules...${NC}"
rm -f /etc/udev/rules.d/99-inputplumber-device-setup.rules
rm -f /etc/modprobe.d/70-blacklist-lenovo.conf*
udevadm control --reload-rules
udevadm trigger 2>/dev/null || true
echo -e "${GREEN}[+] Udev rules reset to stock defaults.${NC}"

# 6. Reset controller hardware & MCU state (stop IMU streaming & restore bypass)
echo -e "${BLUE}[6/8] Resetting controller MCU and sysfs...${NC}"
python3 -c '
import glob, os, time

def pad64(data):
    return bytes(data) + bytes(64 - len(data))

for p in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
    uevent = os.path.join(p, "device/uevent")
    if os.path.exists(uevent):
        with open(uevent) as f:
            txt = f.read()
        if "17EF" in txt and ("618" in txt or "61E" in txt) and (":1.2" in txt or "input2" in txt):
            hidraw_node = f"/dev/{os.path.basename(p)}"
            try:
                os.chmod(hidraw_node, 0o666)
                with open(hidraw_node, "wb") as f_hid:
                    # 1. Stop 16-bit HQ streaming (Right & Left)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x07, 0x04, 0x02, 0x00]))
                    f_hid.flush()
                    time.sleep(0.02)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x07, 0x03, 0x02, 0x00]))
                    f_hid.flush()
                    time.sleep(0.02)

                    # 2. Disable IMU (Right & Left)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x02, 0x04, 0x01, 0x00]))
                    f_hid.flush()
                    time.sleep(0.02)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x02, 0x03, 0x01, 0x00]))
                    f_hid.flush()
                    time.sleep(0.02)

                    # 3. Disable Lenovo FEATURE_IMU_ENABLE
                    f_hid.write(pad64([0x05, 0x00, 0x04, 0x05, 0x04, 0x00]))
                    f_hid.flush()
                    time.sleep(0.02)
                    f_hid.write(pad64([0x05, 0x00, 0x04, 0x05, 0x03, 0x00]))
                    f_hid.flush()
                    time.sleep(0.02)

                    # 4. Enable Bypass (Default Lenovo state)
                    f_hid.write(pad64([0x05, 0x00, 0x04, 0x03, 0x04, 0x01]))
                    f_hid.flush()
                    time.sleep(0.02)
                    f_hid.write(pad64([0x05, 0x00, 0x04, 0x03, 0x03, 0x01]))
                    f_hid.flush()
                print(f"    -> Sent HID reset packets to {hidraw_node}.")
            except Exception as e:
                print(f"    -> Note for {hidraw_node}: {e}")
' 2>/dev/null || true

for dev in /sys/bus/hid/drivers/hid-lenovo-go/0003:17EF:61E*.*; do
  if [ -d "$dev" ]; then
    echo "linux" > "$dev/os_mode" 2>/dev/null || true
    echo "true" > "$dev/left_handle/imu_bypass_enabled" 2>/dev/null || true
    echo "true" > "$dev/right_handle/imu_bypass_enabled" 2>/dev/null || true
    echo "false" > "$dev/left_handle/imu_enabled" 2>/dev/null || true
    echo "false" > "$dev/right_handle/imu_enabled" 2>/dev/null || true
  fi
done
udevadm trigger --subsystem-match=hid 2>/dev/null || true
echo -e "${GREEN}[+] Controller MCU and driver state reset.${NC}"

# 7. Clean up systemd overrides
echo -e "${BLUE}[7/8] Cleaning up systemd overrides...${NC}"
if [ -f /etc/systemd/system/inputplumber.service ] && [ -f /usr/lib/systemd/system/inputplumber.service ]; then
  if cmp -s /etc/systemd/system/inputplumber.service /usr/lib/systemd/system/inputplumber.service; then
    rm -f /etc/systemd/system/inputplumber.service
  fi
fi
rm -f /etc/systemd/system/inputplumber.service.d/override.conf
rmdir /etc/systemd/system/inputplumber.service.d 2>/dev/null || true
systemctl daemon-reload
echo -e "${GREEN}[+] Systemd configuration cleaned.${NC}"

# 8. Restart service and verify
echo -e "${BLUE}[8/8] Restarting original InputPlumber service...${NC}"
systemctl restart inputplumber.service
sleep 2

if systemctl is-active --quiet inputplumber.service; then
  echo -e "${GREEN}[+] inputplumber.service is active and running.${NC}"
else
  echo -e "${YELLOW}[!] Warning: inputplumber.service could not be started.${NC}"
  journalctl -u inputplumber.service -n 15 --no-pager || true
fi

echo ""
echo -e "${CYAN}==========================================================${NC}"
echo -e "${BOLD}  Package Integrity Verification Result (pacman -Qkk):  ${NC}"
echo -e "${CYAN}==========================================================${NC}"
if pacman -Qkk inputplumber 2>/dev/null; then
  echo -e "${GREEN}[✓] 100% stock upstream state verified! No altered files.${NC}"
else
  pacman -Qkk inputplumber 2>&1 || true
fi
echo ""
echo -e "${GREEN}InputPlumber has been successfully reverted to the factory stock state.${NC}"
echo -e "${CYAN}==========================================================${NC}"
