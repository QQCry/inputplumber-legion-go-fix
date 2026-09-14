#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Bitte mit sudo ausführen: sudo bash $0"
  exit 1
fi

echo "=========================================================="
echo "  Aktiviere Rechten Controller-Sensor (HHD-Methode)       "
echo "=========================================================="

# 1. Dienst stoppen
echo "[1/6] Stoppe inputplumber.service..."
systemctl stop inputplumber.service 2>/dev/null || true

# 2. Neues Binary installieren
echo "[2/6] Installiere gepatchtes Binary für rechten Controller..."
NEW_BIN="/home/qqcry/.local/bin/inputplumber-right-controller-12x"
if [ ! -f "$NEW_BIN" ]; then
  echo "[-] Fehler: $NEW_BIN nicht gefunden!"
  exit 1
fi
install -m 755 "$NEW_BIN" /usr/bin/inputplumber
echo "[+] Gepatchtes Binary erfolgreich nach /usr/bin/inputplumber installiert."

# 3. Konfiguration anpassen: Tablet-IMU in CompositeDevice0 einbinden aber stummschalten
echo "[3/6] Konfiguriere /etc/inputplumber/devices.d/50-legion_go.yaml..."
python3 -c '
import re

path = "/etc/inputplumber/devices.d/50-legion_go.yaml"
with open(path, "r") as f:
    c = f.read()

if "- xbox-elite" in c:
    c = c.replace("- xbox-elite", "- deck-uhid")

imu_block = """  # Tablet-IMU in CompositeDevice0 beansprucht (verhindert zweiten Controller),
  # aber Events stummgeschaltet, damit der rechte Joy-Con-Gyro exklusiv genutzt wird:
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
print("[+] Konfiguration erfolgreich aktualisiert (Einzell-Controller garantiert).")
'

# 4. Saubere Udev-Regel anlegen (os_mode=windows, Bypass=false = KEIN Mauslag)
echo "[4/6] Bereinige udev-Regeln..."
rm -f /etc/udev/rules.d/99-inputplumber-device-setup.rules
cat << 'UDEV_EOF' > /etc/udev/rules.d/99-inputplumber-device-setup.rules
ACTION=="add|change|bind", ATTRS{idVendor}=="17ef", ATTRS{idProduct}=="61e[bcde]", SUBSYSTEM=="hid", DRIVER=="hid-lenovo-go", ATTR{os_mode}="windows", ATTR{left_handle/imu_bypass_enabled}="false", ATTR{right_handle/imu_bypass_enabled}="false", ATTR{touchpad/vibration_enable}="false", GOTO="end"
UDEV_EOF
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

# 5. Controller MCU IMU direkt über 64-Byte HID-Befehle aktivieren
echo "[5/6] Sende 64-Byte HID-Aktivierungsbefehle an Controller..."
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

                    # 3. Right: Enable IMU & 16-bit HQ report stream (HHD protocol: EXACT 7 BYTES)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x02, 0x04, 0x01, 0x01]))
                    f_hid.flush()
                    time.sleep(0.04)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x07, 0x04, 0x02, 0x01]))
                    f_hid.flush()
                    time.sleep(0.04)

                    # 4. Left: Enable IMU & 16-bit HQ report stream (HHD protocol: EXACT 7 BYTES)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x02, 0x03, 0x01, 0x01]))
                    f_hid.flush()
                    time.sleep(0.04)
                    f_hid.write(bytes([0x05, 0x06, 0x6A, 0x07, 0x03, 0x02, 0x01]))
                    f_hid.flush()
                print(f"[+] HID-Aktivierungspakete (Lenovo 64B & HHD 7B) erfolgreich an {hidraw_node} gesendet!")
            except Exception as e:
                print(f"[-] Fehler beim Senden an {hidraw_node}: {e}")
'

# Sysfs Hardware-Modus sicherstellen (Windows-Modus, Bypass aus = Butterweicher Touchpad-Mauszeiger)
for dev in /sys/bus/hid/drivers/hid-lenovo-go/0003:17EF:61E*.*; do
  if [ -d "$dev" ]; then
    if [ -f "$dev/os_mode" ]; then
      echo "windows" > "$dev/os_mode" 2>/dev/null || true
    fi
    if [ -d "$dev/right_handle" ]; then
      echo "false" > "$dev/right_handle/imu_bypass_enabled" 2>/dev/null || true
      # Hinweis: right_handle/imu_enabled in sysfs hat einen Kernel-Treiber-Bug (sendet Bypass 0x3).
      # Daher aktivieren wir die IMU direkt via HID-Paket (0x05) oben und belassen sysfs imu_bypass_enabled auf false.
    fi
    if [ -d "$dev/left_handle" ]; then
      echo "false" > "$dev/left_handle/imu_bypass_enabled" 2>/dev/null || true
      echo "true" > "$dev/left_handle/imu_enabled" 2>/dev/null || true
    fi
  fi
done

# 6. Dienst starten
echo "[6/6] Starte inputplumber.service..."
systemctl daemon-reload
systemctl restart inputplumber.service
sleep 2

echo "[*] Überprüfe Hardware-Status in sysfs..."
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
  echo "  ERFOLG: Rechter Controller-Sensor ist aktiv!            "
  echo "  - Controller-Typ: Valve Steam Deck (ABXY-Glyphen)       "
  echo "  - Nur 1 Controller: Zweiter Controller blockiert        "
  echo "  - Touchpad: Kein Ruckeln / kein Mauslag                 "
  echo "  - Rollback jederzeit: sudo bash ~/restore-stable-gyro.sh"
  echo "=========================================================="
  echo "Starte jetzt den Sensortest mit:"
  echo "    python3 ~/test-gyro.py"
else
  echo "[!] Fehler beim Starten von inputplumber.service!"
  journalctl -u inputplumber.service -n 25 --no-pager
  exit 1
fi
