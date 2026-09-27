#!/usr/bin/env bash
set -e

CONFIG_FILE="/etc/inputplumber/devices.d/50-legion_go.yaml"

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo:"
  echo "    sudo bash $0 [FACTOR]"
  echo "    Example for 2.5x faster motion:"
  echo "    sudo bash $0 2.5"
  exit 1
fi

FACTOR="${1:-2.5}"

# Validation: allow numbers and decimal points only
if ! [[ "$FACTOR" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "[-] Invalid factor: '$FACTOR'. Please enter a valid number (e.g. 2.0, 2.5, 3.0)."
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[-] Configuration file $CONFIG_FILE does not exist!"
  exit 1
fi

echo "[1/3] Creating backup and setting gyro amplification to ${FACTOR}x..."
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

python3 -c "
import os, re, sys

factor = sys.argv[1]
with open('$CONFIG_FILE', 'r') as f:
    content = f.read()

pattern = r'(- group: imu\s*\n\s*iio:\s*\n\s*name: gyro_3d\s*\n\s*mount_matrix:\s*\n\s*x:\s*\[0,\s*)[^,]+(,\s*0\]\s*\n\s*y:\s*\[)[^,]+(,\s*0,\s*0\]\s*\n\s*z:\s*\[0,\s*0,\s*)[^\]]+(\])'
if not re.search(pattern, content):
    print('[-] Could not find gyro_3d mount_matrix. Please check configuration manually.')
    sys.exit(1)

new_content = re.sub(pattern, rf'\g<1>{factor}\g<2>{factor}\g<3>{factor}\g<4>', content)
with open('$CONFIG_FILE', 'w') as f:
    f.write(new_content)
print(f'[+] Gyro mount matrix successfully set to factor {factor}x.')

# Reset Steam gyro drift calibration if present
import glob
home_dirs = ['/home/qqcry']
if 'SUDO_USER' in os.environ:
    user_home = os.path.expanduser(f'~{os.environ[\"SUDO_USER\"]}')
    if user_home not in home_dirs:
        home_dirs.append(user_home)

for h in home_dirs:
    for vdf in glob.glob(f'{h}/.local/share/Steam/config/*gyro*.vdf'):
        try:
            with open(vdf, 'r') as vf:
                vdf_content = vf.read()
            vdf_fixed = re.sub(r'\"gyro_drift_per_sample_[xyz]\"\s*\"[^\"]*\"', lambda m: m.group(0).split()[0] + '\t\t\"0.0\"', vdf_content)
            with open(vdf, 'w') as vf:
                vf.write(vdf_fixed)
            print(f'[+] Steam gyro drift in {os.path.basename(vdf)} reset to 0.0.')
        except Exception as ex:
            print(f'[-] Could not update {vdf}: {ex}')
" "$FACTOR"

echo "[2/3] Restarting inputplumber.service..."
systemctl restart inputplumber.service
sleep 1.5

echo "[3/3] Checking status..."
if systemctl is-active --quiet inputplumber.service; then
  echo "[+] InputPlumber is running with new gyro factor ${FACTOR}x!"
  echo ""
  echo "=========================================================="
  echo "Success: Gyro sensitivity adjusted system-wide!"
  echo "You can test the values now with: python3 ~/test-gyro.py"
  echo "=========================================================="
else
  echo "[!] InputPlumber failed to start. Restoring backup..."
  cp "${CONFIG_FILE}.bak" "$CONFIG_FILE"
  systemctl restart inputplumber.service
  exit 1
fi
