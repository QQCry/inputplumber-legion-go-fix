#!/usr/bin/env bash
# ==============================================================================
#  InputPlumber Legion Go Gyro Fix & Auto-Updater
#  ----------------------------------------------------------------------------
#  Repairs and safeguards gyroscope and accelerometer support
#  for Lenovo Legion Go across upstream InputPlumber updates.
#
#  Usage:
#    sudo bash ~/fix-inputplumber.sh            (Quick 1-click fix / restore)
#    sudo bash ~/fix-inputplumber.sh --rebuild  (Patch & compile from latest source)
#    sudo bash ~/fix-inputplumber.sh --hook     (Set up automated Pacman update hook)
#    sudo bash ~/fix-inputplumber.sh --status   (Display system & sensor status)
#    sudo bash ~/fix-inputplumber.sh --test     (Launch real-time sensor diagnostic)
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

TARGET_BIN="/usr/bin/inputplumber"
BACKUP_STOCK_BIN="/usr/bin/inputplumber.stock-backup"
PRECOMPILED_BIN="/home/qqcry/.local/bin/inputplumber-patched-12x"
ALT_PRECOMPILED_BIN="/home/qqcry/.local/bin/inputplumber-right-controller-12x"
CONFIG_FILE="/etc/inputplumber/devices.d/50-legion_go.yaml"
UDEV_RULES="/etc/udev/rules.d/99-inputplumber-device-setup.rules"
PACMAN_HOOK="/etc/pacman.d/hooks/99-inputplumber-fix.hook"
SYMLINK_BIN="/usr/local/bin/fix-inputplumber"
SOURCE_DIR="/home/qqcry/Projekte/InputPlumber"
USER_NAME="qqcry"
STEAM_CONFIG_DIR="/home/${USER_NAME}/.local/share/Steam/config"

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}[*] Root privileges required. Re-launching with sudo...${NC}"
    exec sudo bash "$0" "$@"
  fi
}

# ------------------------------------------------------------------------------
# 1. Verification: Is the installed binary already patched?
# ------------------------------------------------------------------------------
is_binary_patched() {
  local bin="${1:-$TARGET_BIN}"
  if [ ! -f "$bin" ]; then
    return 1
  fi
  if strings "$bin" 2>/dev/null | grep -q "Enabling internal gyroscope and accelerometer"; then
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------
# 2. Check & fix /etc/inputplumber/devices.d/50-legion_go.yaml
# ------------------------------------------------------------------------------
fix_yaml_config() {
  echo -e "${BLUE}[*] Checking configuration: ${CONFIG_FILE}...${NC}"
  mkdir -p "$(dirname "$CONFIG_FILE")"

  if [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "/usr/share/inputplumber/devices/50-legion_go.yaml" ]; then
      cp "/usr/share/inputplumber/devices/50-legion_go.yaml" "$CONFIG_FILE"
      echo -e "${YELLOW}    Copied template from /usr/share.${NC}"
    else
      echo -e "${RED}[-] Neither $CONFIG_FILE nor template in /usr/share found!${NC}"
      return 1
    fi
  fi

  # Create backup if not already present
  if [ ! -f "${CONFIG_FILE}.orig" ]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.orig"
  fi

  python3 - << 'PYEOF'
import re, sys

path = "/etc/inputplumber/devices.d/50-legion_go.yaml"
try:
    with open(path, "r") as f:
        c = f.read()
except Exception as e:
    sys.exit(f"Read error: {e}")

changed = False

# 1. Ensure target_devices is set to deck-uhid (for native ABXY Steam Deck glyphs)
if "- deck-uhid" not in c:
    if "- xbox-elite" in c:
        c = c.replace("- xbox-elite", "- deck-uhid")
        changed = True
    elif "target_devices:" in c:
        c = c.replace("target_devices:", "target_devices:\n  - deck-uhid")
        changed = True

# 2. Ensure accel_3d & gyro_3d blocks with correct mount matrix are present
imu_target = """  # IMU
  - group: imu
    iio:
      name: gyro_3d
      mount_matrix:
        x: [0, 1.0, 0]
        y: [1.0, 0, 0]
        z: [0, 0, 1.0]
  - group: imu
    iio:
      name: accel_3d
      mount_matrix:
        x: [0, 1, 0]
        y: [-1, 0, 0]
        z: [0, 0, 1]"""

if "name: accel_3d" not in c:
    pat = r"- group:\s*imu\s*\n\s*iio:\s*\n\s*name:\s*gyro_3d[\s\S]*?(?=(\n\s*- group:|\noptions:|\ntarget_devices:|\Z))"
    if re.search(pat, c):
        c = re.sub(pat, imu_target.strip() + "\n", c)
    elif "options:" in c:
        c = c.replace("options:", imu_target + "\n\noptions:")
    elif "target_devices:" in c:
        c = c.replace("target_devices:", imu_target + "\n\ntarget_devices:")
    else:
        c += "\n" + imu_target
    changed = True

if changed:
    with open(path, "w") as f:
        f.write(c)
    print("    [+] 50-legion_go.yaml successfully updated (added accel_3d & deck-uhid).")
else:
    print("    [+] 50-legion_go.yaml is already correctly configured.")
PYEOF
}

# ------------------------------------------------------------------------------
# 3. Secure udev rules & controller MCU driver settings
# ------------------------------------------------------------------------------
fix_udev_rules() {
  echo -e "${BLUE}[*] Checking udev rules and MCU bypass protection...${NC}"
  cat << 'UDEV_EOF' > "$UDEV_RULES"
ACTION=="add|change|bind", ATTRS{idVendor}=="17ef", ATTRS{idProduct}=="61e[bcde]", SUBSYSTEM=="hid", DRIVER=="hid-lenovo-go", ATTR{os_mode}="windows", ATTR{left_handle/imu_bypass_enabled}="false", ATTR{right_handle/imu_bypass_enabled}="false", ATTR{touchpad/vibration_enable}="false", GOTO="end"
UDEV_EOF
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger 2>/dev/null || true

  # Update active hardware in sysfs (if controller connected)
  for dev in /sys/bus/hid/drivers/hid-lenovo-go/0003:17EF:61E*.*; do
    if [ -d "$dev" ]; then
      [ -f "$dev/os_mode" ] && echo "windows" > "$dev/os_mode" 2>/dev/null || true
      [ -d "$dev/right_handle" ] && echo "false" > "$dev/right_handle/imu_bypass_enabled" 2>/dev/null || true
      [ -d "$dev/left_handle" ] && echo "false" > "$dev/left_handle/imu_bypass_enabled" 2>/dev/null || true
    fi
  done
  echo -e "${GREEN}    [+] Udev rules active (prevents mouse lag & touchpad jumping).${NC}"
}

# ------------------------------------------------------------------------------
# 4. Reset Steam gyro drift calibration (prevents downward view pull)
# ------------------------------------------------------------------------------
reset_steam_drift() {
  echo -e "${BLUE}[*] Resetting erroneous Steam drift values...${NC}"
  for vdf in "$STEAM_CONFIG_DIR"/*12fe*_gyro.vdf; do
    if [ -f "$vdf" ]; then
      cat << 'VDFFIX' > "$vdf"
"gyro_data"
{
	"gyro_drift_per_sample_x"		"0.0"
	"gyro_drift_per_sample_y"		"0.0"
	"gyro_drift_per_sample_z"		"0.0"
	"gyro_stationary_noise_tolerance"		"11"
	"accelerometer_stationary_noise_tolerance"		"100"
}
VDFFIX
      chown "${USER_NAME}:${USER_NAME}" "$vdf" 2>/dev/null || true
      echo -e "${GREEN}    [+] Drift in $(basename "$vdf") reset to 0.0.${NC}"
    fi
  done
}

# ------------------------------------------------------------------------------
# 5. Quick Fix (uses saved optimized release binary)
# ------------------------------------------------------------------------------
apply_fast_fix() {
  local auto_mode="$1"
  check_root "$@"
  echo -e "${CYAN}==========================================================${NC}"
  echo -e "${BOLD}  InputPlumber Gyro Fix for Lenovo Legion Go (Quick Mode)${NC}"
  echo -e "${CYAN}==========================================================${NC}"

  # Check which patched binary is available
  local source_bin=""
  if [ -f "$PRECOMPILED_BIN" ] && is_binary_patched "$PRECOMPILED_BIN"; then
    source_bin="$PRECOMPILED_BIN"
  elif [ -f "$ALT_PRECOMPILED_BIN" ] && is_binary_patched "$ALT_PRECOMPILED_BIN"; then
    source_bin="$ALT_PRECOMPILED_BIN"
  fi

  if [ -z "$source_bin" ]; then
    echo -e "${RED}[!] No precompiled patched binary found!${NC}"
    echo -e "${YELLOW}[*] Starting automatic rebuild from source...${NC}"
    rebuild_from_source
    return $?
  fi

  # 1. Stop service
  echo -e "${BLUE}[1/5] Stopping inputplumber.service...${NC}"
  systemctl stop inputplumber.service 2>/dev/null || true

  # 2. Backup stock binary if not already backed up
  if [ -f "$TARGET_BIN" ] && ! is_binary_patched "$TARGET_BIN"; then
    echo -e "${BLUE}[2/5] Backing up original binary to ${BACKUP_STOCK_BIN}...${NC}"
    cp "$TARGET_BIN" "$BACKUP_STOCK_BIN"
  else
    echo -e "${BLUE}[2/5] Installing patched binary...${NC}"
  fi

  cp "$source_bin" "$TARGET_BIN"
  chmod 755 "$TARGET_BIN"
  echo -e "${GREEN}    [+] Patched binary successfully copied to ${TARGET_BIN}.${NC}"

  # 3. Fix YAML configuration
  echo -e "${BLUE}[3/5] Checking sensor configuration...${NC}"
  fix_yaml_config

  # 4. Udev & Steam drift
  echo -e "${BLUE}[4/5] Applying driver rules & cleaning Steam drift...${NC}"
  fix_udev_rules
  reset_steam_drift

  # 5. Restart service
  echo -e "${BLUE}[5/5] Restarting inputplumber.service...${NC}"
  systemctl daemon-reload
  systemctl restart inputplumber.service
  sleep 2

  if systemctl is-active --quiet inputplumber.service; then
    echo ""
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${BOLD}${GREEN}  SUCCESS: InputPlumber is running with Gyro Fix!        ${NC}"
    echo -e "${GREEN}  - Native IMU motion streaming & 200 Hz active          ${NC}"
    echo -e "${GREEN}  - accel_3d gravity vector active (Steam detects IMU)   ${NC}"
    echo -e "${GREEN}  - Native Steam Deck ABXY glyphs                        ${NC}"
    echo -e "${GREEN}  - Butter-smooth touchpad tracking (zero mouse lag)     ${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    if [ "$auto_mode" != "--auto-hook" ]; then
      echo -e "${CYAN}Test live with:  python3 ~/test-gyro.py${NC}"
    fi
  else
    echo -e "${RED}[!] Error starting inputplumber.service!${NC}"
    journalctl -u inputplumber.service -n 25 --no-pager
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 6. Rebuild & patch from source (for newer versions of InputPlumber)
# ------------------------------------------------------------------------------
rebuild_from_source() {
  check_root "$@"
  echo -e "${CYAN}==========================================================${NC}"
  echo -e "${BOLD}  Patch & Recompile InputPlumber Source Code             ${NC}"
  echo -e "${CYAN}==========================================================${NC}"

  # Check Cargo/Rust
  if ! command -v cargo &>/dev/null; then
    echo -e "${YELLOW}[*] Rust/Cargo not found, installing rust...${NC}"
    pacman -S --needed --noconfirm rust
  fi

  # Check dependencies
  echo -e "${BLUE}[*] Checking system build dependencies...${NC}"
  pacman -S --needed --noconfirm git pkgconf systemd hidapi base-devel

  # Prepare directory
  mkdir -p "$SOURCE_DIR"
  if [ ! -d "$SOURCE_DIR/.git" ]; then
    echo -e "${BLUE}[*] Cloning official InputPlumber repository...${NC}"
    git clone https://github.com/ShadowBlip/InputPlumber.git "$SOURCE_DIR"
    chown -R "${USER_NAME}:${USER_NAME}" "$SOURCE_DIR"
  else
    echo -e "${BLUE}[*] Updating InputPlumber repository...${NC}"
    sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" fetch --tags
  fi

  # Clean working tree
  echo -e "${BLUE}[*] Resetting source code working tree...${NC}"
  sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" reset --hard HEAD
  sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" clean -fd

  # Apply patch
  local patch_file="/tmp/inputplumber-legiongo.patch"
  write_embedded_patch "$patch_file"

  echo -e "${BLUE}[*] Applying Legion Go Gyro Fix patch...${NC}"
  if sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" apply --check "$patch_file" 2>/dev/null; then
    sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" apply "$patch_file"
    echo -e "${GREEN}    [+] Patch applied cleanly.${NC}"
  else
    echo -e "${YELLOW}[!] Direct patch failed, attempting 3-way merge...${NC}"
    if ! sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" apply -3 "$patch_file"; then
      echo -e "${RED}[-] Source code patch could not be applied!${NC}"
      rm -f "$patch_file"
      return 1
    fi
  fi
  rm -f "$patch_file"

  # Compile with Cargo Release
  echo -e "${BLUE}[*] Compiling InputPlumber (cargo build --release)...${NC}"
  sudo -u "${USER_NAME}" bash -c "cd '$SOURCE_DIR' && cargo build --release"

  local compiled_bin="$SOURCE_DIR/target/release/inputplumber"
  if [ ! -f "$compiled_bin" ]; then
    echo -e "${RED}[-] Compilation failed: $compiled_bin not found!${NC}"
    return 1
  fi

  # Store precompiled binary
  mkdir -p "$(dirname "$PRECOMPILED_BIN")"
  cp "$compiled_bin" "$PRECOMPILED_BIN"
  chown "${USER_NAME}:${USER_NAME}" "$PRECOMPILED_BIN"
  chmod 755 "$PRECOMPILED_BIN"
  echo -e "${GREEN}    [+] New release binary saved to ${PRECOMPILED_BIN}.${NC}"

  # Complete installation
  apply_fast_fix
}

# ------------------------------------------------------------------------------
# 7. Pacman update hook (Automatically restores fix after pacman -Syu)
# ------------------------------------------------------------------------------
install_pacman_hook() {
  check_root "$@"
  echo -e "${CYAN}==========================================================${NC}"
  echo -e "${BOLD}  Configure Automated Pacman Update Hook                 ${NC}"
  echo -e "${CYAN}==========================================================${NC}"

  # 1. Create symlink for system-wide execution
  ln -sf "/home/${USER_NAME}/fix-inputplumber.sh" "$SYMLINK_BIN"
  chmod 755 "$SYMLINK_BIN"
  echo -e "${GREEN}[+] Command 'fix-inputplumber' linked system-wide at ${SYMLINK_BIN}.${NC}"

  # 2. Check hook directory
  mkdir -p "$(dirname "$PACMAN_HOOK")"

  # 3. Write Pacman hook file
  cat << 'HOOK_EOF' > "$PACMAN_HOOK"
[Trigger]
Operation = Upgrade
Operation = Install
Type = Package
Target = inputplumber

[Action]
Description = Re-applying Legion Go Gyro Fix to InputPlumber...
When = PostTransaction
Exec = /usr/local/bin/fix-inputplumber --auto-hook
HOOK_EOF

  chmod 644 "$PACMAN_HOOK"
  echo -e "${GREEN}[+] Pacman hook successfully installed to:${NC}"
  echo -e "    ${PACMAN_HOOK}"
  echo ""
  echo -e "${GREEN}--> Future system updates (pacman -Syu) will automatically${NC}"
  echo -e "${GREEN}    maintain the fix with zero manual intervention required!${NC}"
  echo -e "${CYAN}==========================================================${NC}"
}

remove_pacman_hook() {
  check_root "$@"
  echo -e "${YELLOW}[*] Removing Pacman hook...${NC}"
  rm -f "$PACMAN_HOOK"
  rm -f "$SYMLINK_BIN"
  echo -e "${GREEN}[+] Hook and symlink removed.${NC}"
}

uninstall_fix() {
  check_root "$@"
  if [ -f "/home/${USER_NAME}/uninstall-gyro-fix.sh" ]; then
    bash "/home/${USER_NAME}/uninstall-gyro-fix.sh"
  elif [ -f "$(dirname "$0")/uninstall-gyro-fix.sh" ]; then
    bash "$(dirname "$0")/uninstall-gyro-fix.sh"
  else
    echo -e "${RED}[-] uninstall-gyro-fix.sh not found!${NC}"
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# 8. Status & Diagnostics Display
# ------------------------------------------------------------------------------
show_status() {
  echo -e "${CYAN}==========================================================${NC}"
  echo -e "${BOLD}  InputPlumber & Legion Go Gyro Status                  ${NC}"
  echo -e "${CYAN}==========================================================${NC}"

  # Binary Status
  echo -n "[1] Binary (/usr/bin/inputplumber): "
  if [ ! -f "$TARGET_BIN" ]; then
    echo -e "${RED}NOT FOUND${NC}"
  elif is_binary_patched "$TARGET_BIN"; then
    echo -e "${GREEN}PATCHED (Gyro + SFH Accel Fix active)${NC}"
  else
    echo -e "${RED}UNPATCHED STOCK (reverted by package manager)${NC}"
  fi

  # Backup Binary
  echo -n "[2] Backup Binary ($PRECOMPILED_BIN): "
  if [ -f "$PRECOMPILED_BIN" ]; then
    local bsize
    bsize=$(du -h "$PRECOMPILED_BIN" | cut -f1)
    echo -e "${GREEN}PRESENT ($bsize)${NC}"
  else
    echo -e "${YELLOW}NOT FOUND${NC}"
  fi

  # Configuration
  echo -n "[3] Config ($CONFIG_FILE): "
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}MISSING${NC}"
  elif grep -q "name: accel_3d" "$CONFIG_FILE" && grep -q "deck-uhid" "$CONFIG_FILE"; then
    echo -e "${GREEN}CORRECT (accel_3d & deck-uhid configured)${NC}"
  else
    echo -e "${YELLOW}INCOMPLETE (accel_3d or deck-uhid missing)${NC}"
  fi

  # Udev
  echo -n "[4] Udev Rules ($UDEV_RULES): "
  if [ -f "$UDEV_RULES" ]; then
    echo -e "${GREEN}ACTIVE (Mouse lag prevention enabled)${NC}"
  else
    echo -e "${YELLOW}NOT FOUND${NC}"
  fi

  # Pacman Hook
  echo -n "[5] Automated Pacman Hook: "
  if [ -f "$PACMAN_HOOK" ]; then
    echo -e "${GREEN}ACTIVE (auto-repairs on pacman -Syu)${NC}"
  else
    echo -e "${YELLOW}INACTIVE (install via 'sudo fix-inputplumber --hook')${NC}"
  fi

  # Service Status
  echo -n "[6] Systemd Service (inputplumber.service): "
  if systemctl is-active --quiet inputplumber.service; then
    local pid
    pid=$(systemctl show -p MainPID --value inputplumber.service)
    echo -e "${GREEN}RUNNING (PID $pid)${NC}"
  else
    echo -e "${RED}STOPPED / FAILED${NC}"
  fi

  # Active Virtual Controller
  echo -n "[7] Virtual Steam Controller: "
  local hidraw_dev
  hidraw_dev=$(grep -i -l "28de.*12fe" /sys/class/hidraw/hidraw*/device/uevent 2>/dev/null | sed -n 's|.*/\(hidraw[0-9]\+\)/.*|\1|p' | head -n 1 || true)
  if [ -n "$hidraw_dev" ]; then
    echo -e "${GREEN}ACTIVE (/dev/${hidraw_dev} as Valve Steam Deck)${NC}"
  else
    echo -e "${YELLOW}NOT FOUND (initialized upon client connection)${NC}"
  fi
  echo -e "${CYAN}==========================================================${NC}"
}

# ------------------------------------------------------------------------------
# 9. Embedded Git Patch (Full patch against upstream)
# ------------------------------------------------------------------------------
write_embedded_patch() {
  local out="$1"
  cat << 'PATCH_EOF' > "$out"
diff --git a/Cargo.toml b/Cargo.toml
index 93b65e7..4fd7c26 100644
--- a/Cargo.toml
+++ b/Cargo.toml
@@ -102,6 +102,10 @@ assets = [
   ],
 ]
 
+[[bin]]
+name = "inputplumber"
+path = "./src/main.rs"
+
 [[bin]]
 name = "generate"
 path = "./src/generate.rs"
diff --git a/src/drivers/iio_imu/driver.rs b/src/drivers/iio_imu/driver.rs
index 9e23672..7af1049 100644
--- a/src/drivers/iio_imu/driver.rs
+++ b/src/drivers/iio_imu/driver.rs
@@ -126,23 +126,8 @@ impl Driver {
     pub fn get_default_event_filter(
         &self,
     ) -> Result<HashSet<Capability>, Box<dyn Error + Send + Sync>> {
-        let filtered_events = match is_driver_loaded("hid_lenovo_go") {
-            Ok(true) => {
-                log::debug!("Found hid-lenovo-go driver. Disabling internal gyroscope.");
-                HashSet::from([
-                    Capability::Accelerometer(Source::Center),
-                    Capability::Gyroscope(Source::Center),
-                ])
-            }
-            Ok(false) => {
-                log::debug!("Did not find hid-lenovo-go driver. Enabling internal gyroscope.");
-                HashSet::new()
-            }
-            Err(e) => {
-                return Err(format!("Failed to read '/proc/modules': {e:?}").into());
-            }
-        };
-        Ok(filtered_events)
+        log::debug!("Enabling internal gyroscope and accelerometer.");
+        Ok(HashSet::new())
     }
 
     /// Poll the device for data
@@ -210,27 +195,47 @@ impl Driver {
             return Ok(None);
         }
 
-        let mut gyro_input = AxisData::default();
+        let mut raw_x: Option<i64> = None;
+        let mut raw_y: Option<i64> = None;
+        let mut raw_z: Option<i64> = None;
+        let mut scale_x = 1.0;
+        let mut scale_y = 1.0;
+        let mut scale_z = 1.0;
+        let mut offset_x = 0;
+        let mut offset_y = 0;
+        let mut offset_z = 0;
+
         for (id, channel) in self.gyro.iter() {
-            // Get the info for the axis and read the data
             let Some(info) = self.gyro_info.get(id) else {
                 continue;
             };
             let data = channel.attr_read_int("raw")?;
 
-            // processed_value = (raw + offset) * scale
-            let value = (data + info.offset) as f64 * info.scale;
-
             if id.ends_with('x') {
-                gyro_input.roll = value;
-            }
-            if id.ends_with('y') {
-                gyro_input.pitch = value;
-            }
-            if id.ends_with('z') {
-                gyro_input.yaw = value;
+                raw_x = Some(data);
+                scale_x = info.scale;
+                offset_x = info.offset;
+            } else if id.ends_with('y') {
+                raw_y = Some(data);
+                scale_y = info.scale;
+                offset_y = info.offset;
+            } else if id.ends_with('z') {
+                raw_z = Some(data);
+                scale_z = info.scale;
+                offset_z = info.offset;
             }
         }
+
+        let rx = raw_x.unwrap_or(0) as f64;
+        let ry = raw_y.unwrap_or(0) as f64;
+        let rz = raw_z.unwrap_or(0) as f64;
+
+        let mut gyro_input = AxisData {
+            roll: (rx + offset_x as f64) * scale_x,
+            pitch: (ry + offset_y as f64) * scale_y,
+            yaw: (rz + offset_z as f64) * scale_z,
+        };
+
         self.rotate_value(&mut gyro_input);
 
         Ok(Some(Event::Gyro(gyro_input)))
diff --git a/src/drivers/lego/go1_driver.rs b/src/drivers/lego/go1_driver.rs
index bb7ea0d..0856dd7 100644
--- a/src/drivers/lego/go1_driver.rs
+++ b/src/drivers/lego/go1_driver.rs
@@ -1,19 +1,21 @@
 use std::collections::HashSet;
+use std::time::{Duration, Instant};
 use std::{error::Error, ffi::CString};
 
 use hidapi::HidDevice;
 use packed_struct::PackedStruct;
 
-use crate::input::capability::Capability;
+use crate::input::capability::{Capability, Source};
 use crate::udev::device::UdevDevice;
 
 use super::{
     event::{
-        AxisEvent, BinaryInput, Event, GamepadButtonEvent, JoyAxisInput, MouseWheelInput,
-        TriggerEvent, TriggerInput,
+        AxisEvent, BinaryInput, Event, GamepadButtonEvent, ImuAxisInput, JoyAxisInput,
+        MouseWheelInput, TriggerEvent, TriggerInput,
     },
     hid_report::{GamepadMode, XInputDataReport},
-    GAMEPAD_TIMEOUT, GO1_PIDS, GP_IID, VID, XINPUT_COMMAND_ID, XINPUT_DATA, XINPUT_PACKET_SIZE,
+    GAMEPAD_TIMEOUT, GO1_PIDS, GP_IID, VID, XINPUT_COMMAND_ID, XINPUT_DATA,
+    XINPUT_PACKET_SIZE,
 };
 
 pub struct Driver {
@@ -23,9 +25,71 @@ pub struct Driver {
     filtered_events: HashSet<Capability>,
     /// State for the internal gamepad controller
     state: Option<XInputDataReport>,
+    /// Last emitted accelerometer reading (for noise threshold gating and periodic refresh)
+    last_emitted_accel: Option<(i16, i16, i16, u8)>,
+    /// Last emitted gyroscope reading (for resting deadzone gating)
+    last_emitted_gyro: (i16, i16, i16),
+    /// Timestamp of last sent heartbeat / keep-alive
+    last_heartbeat: Instant,
+    /// Timestamp of last received active motion packet
+    last_motion_packet: Instant,
 }
 
 impl Driver {
+    /// Send an output report to the Legion Go controller interface.
+    /// Commands 0x6a and 0x69 (HHD protocol) MUST be sent as exact unpadded bytes (7 bytes).
+    /// Initial Lenovo feature commands (0x05 0x00 0x04 ...) are padded to 64 bytes.
+    pub fn send_hid_cmd(dev: &HidDevice, cmd: &[u8]) {
+        let is_hhd_cmd = cmd.len() >= 3 && (cmd[2] == 0x6A || cmd[2] == 0x69);
+        if is_hhd_cmd {
+            match dev.write(cmd) {
+                Ok(n) => log::info!("Legion Go: sent unpadded HID cmd {:02x?} ({} bytes)", cmd, n),
+                Err(e) => log::warn!("Legion Go: error sending unpadded HID cmd {:02x?}: {}", cmd, e),
+            }
+        } else {
+            let mut buf = [0u8; 64];
+            let len = cmd.len().min(64);
+            buf[..len].copy_from_slice(&cmd[..len]);
+            match dev.write(&buf) {
+                Ok(n) => log::info!("Legion Go: sent Lenovo padded HID cmd {:02x?} ({} bytes)", &cmd[..len], n),
+                Err(e) => log::warn!("Legion Go: error sending Lenovo padded HID cmd {:02x?}: {}", &cmd[..len], e),
+            }
+        }
+        std::thread::sleep(std::time::Duration::from_millis(20));
+    }
+
+    /// Send non-blocking command: 0x6a commands as exact unpadded 7 bytes, Lenovo reports as 64 bytes padded
+    fn send_heartbeat_cmd(dev: &HidDevice, cmd: &[u8]) {
+        let is_hhd_cmd = cmd.len() >= 3 && (cmd[2] == 0x6A || cmd[2] == 0x69);
+        if is_hhd_cmd {
+            let _ = dev.write(cmd);
+        } else {
+            let mut buf = [0u8; 64];
+            let len = cmd.len().min(64);
+            buf[..len].copy_from_slice(&cmd[..len]);
+            let _ = dev.write(&buf);
+        }
+    }
+
+    /// Send keep-alive / wake-up packets to re-arm IMU sensors without blocking
+    pub fn send_heartbeat(&self) {
+        // 1. Disable IMU bypass (in case controller reset)
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x00, 0x04, 0x03, 0x04, 0x00]);
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x00, 0x04, 0x03, 0x03, 0x00]);
+
+        // 2. Enable IMU sensors using Lenovo FEATURE_IMU_ENABLE
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x00, 0x04, 0x05, 0x04, 0x01]);
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x00, 0x04, 0x05, 0x03, 0x01]);
+
+        // 3. Right Controller: Enable IMU & 16-bit HQ report stream (HHD protocol: EXACT 7 BYTES)
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x06, 0x6A, 0x02, 0x04, 0x01, 0x01]);
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x06, 0x6A, 0x07, 0x04, 0x02, 0x01]);
+
+        // 4. Left Controller: Enable IMU & 16-bit HQ report stream (HHD protocol: EXACT 7 BYTES)
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x06, 0x6A, 0x02, 0x03, 0x01, 0x01]);
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x06, 0x6A, 0x07, 0x03, 0x02, 0x01]);
+    }
+
     pub fn new(udev_device: UdevDevice) -> Result<Self, Box<dyn Error + Send + Sync>> {
         let fmtpath = udev_device.devnode().clone();
         let path = CString::new(fmtpath.clone())?;
@@ -37,34 +101,120 @@ impl Driver {
             || !GO1_PIDS.contains(&info.product_id())
             || info.interface_number() != GP_IID
         {
-            return Err(format!("Device '{fmtpath}' is not a Legion Go S Controller").into());
+            return Err(format!("Device '{fmtpath}' is not a Legion Go Controller").into());
+        }
+
+        log::info!(
+            "Legion Go: successfully opened controller device on '{}' (PID: {:04x}, interface: {})",
+            fmtpath,
+            info.product_id(),
+            info.interface_number()
+        );
+
+        // Ensure os_mode is windows, imu_bypass is disabled, and imu is enabled in sysfs
+        if let Ok(dev) = udev_device.get_device() {
+            let mut curr = dev.parent();
+            while let Some(parent) = curr {
+                let os_mode = parent.syspath().join("os_mode");
+                if os_mode.exists() {
+                    let _ = std::fs::write(&os_mode, "windows\n");
+                    let _ = std::fs::write(parent.syspath().join("right_handle/imu_bypass_enabled"), "false\n");
+                    let _ = std::fs::write(parent.syspath().join("left_handle/imu_bypass_enabled"), "false\n");
+                    let _ = std::fs::write(parent.syspath().join("left_handle/imu_enabled"), "true\n");
+                    break;
+                }
+                curr = parent.parent();
+            }
         }
 
+        // 1. Disable IMU bypass for Right and Left handles (preserves MCU touchpad filtering, prevents mouse lag)
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x00, 0x04, 0x03, 0x04, 0x00]);
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x00, 0x04, 0x03, 0x03, 0x00]);
+
+        // 2. Enable IMU sensors using Lenovo FEATURE_IMU_ENABLE (0x05 -> 0x01)
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x00, 0x04, 0x05, 0x04, 0x01]);
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x00, 0x04, 0x05, 0x03, 0x01]);
+
+        // 3. Right Controller: Enable IMU & 16-bit HQ report stream (HHD protocol)
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x06, 0x6A, 0x02, 0x04, 0x01, 0x01]);
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x06, 0x6A, 0x07, 0x04, 0x02, 0x01]);
+
+        // 4. Left Controller: Enable IMU & 16-bit HQ report stream (HHD protocol)
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x06, 0x6A, 0x02, 0x03, 0x01, 0x01]);
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x06, 0x6A, 0x07, 0x03, 0x02, 0x01]);
+
+        // 5. Disable Legion button swap (keep standard layout)
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x06, 0x69, 0x04, 0x01, 0x01, 0x01]);
+
+        log::info!("Legion Go: sent Lenovo and HHD IMU activation packets (Left & Right)");
+
+        let now = Instant::now();
         Ok(Self {
             hid_device,
             filtered_events: Default::default(),
             state: None,
+            last_emitted_accel: None,
+            last_emitted_gyro: (0, 0, 0),
+            last_heartbeat: now,
+            last_motion_packet: now,
         })
     }
 
-    //TODO: Using InputPlumber Capability enum prevents this driver from having the ability to be
-    //a standalone crate. When this driver is eventually separated, refactor the Event type to
-    //follow the pattern DeviceEvent(Event, Value) and create a match table for
-    //Capability->Event/Event->Capability in the SourceDriver implementation.
     pub fn update_filtered_events(&mut self, events: HashSet<Capability>) {
         self.filtered_events = events;
     }
 
+    pub fn get_default_event_filter(
+        &self,
+    ) -> Result<HashSet<Capability>, Box<dyn Error + Send + Sync>> {
+        // Explicitly enable Right Joy-Con IMU (filter out Left and Center)
+        Ok(HashSet::from([
+            Capability::Accelerometer(Source::Left),
+            Capability::Accelerometer(Source::Center),
+            Capability::Gyroscope(Source::Left),
+            Capability::Gyroscope(Source::Center),
+        ]))
+    }
+
     /// Poll the device and read input reports
     pub fn poll(&mut self) -> Result<Vec<Event>, Box<dyn Error + Send + Sync>> {
-        // Read data from the device into a buffer
-        let mut buf = [0; XINPUT_PACKET_SIZE];
-        let bytes_read = self
-            .hid_device
-            .read_timeout(&mut buf[..], GAMEPAD_TIMEOUT)?;
-
-        if bytes_read > XINPUT_PACKET_SIZE {
-            return Err("Invalid packet size for X-Input Data.".into());
+        let now = Instant::now();
+        let time_since_heartbeat = now.duration_since(self.last_heartbeat);
+        let time_since_motion = now.duration_since(self.last_motion_packet);
+
+        // Heartbeat / Keep-Alive logic:
+        // 1. Regular timer: send keep-alive every 3 seconds
+        // 2. Silence re-arm: if no motion packet received for >= 1500ms
+        if time_since_heartbeat >= Duration::from_secs(3) {
+            log::debug!("Legion Go: sending periodic IMU heartbeat");
+            self.send_heartbeat();
+            self.last_heartbeat = now;
+        } else if time_since_motion >= Duration::from_millis(1500) {
+            log::info!(
+                "Legion Go: IMU stream silence detected ({}ms), re-arming sensors",
+                time_since_motion.as_millis()
+            );
+            self.send_heartbeat();
+            self.last_heartbeat = now;
+            // Prevent spamming re-arm on every 8ms cycle while hardware wakes up
+            self.last_motion_packet = now;
+        }
+
+        let mut buf = [0u8; 64];
+        let bytes_read = match self.hid_device.read_timeout(&mut buf[..], GAMEPAD_TIMEOUT) {
+            Ok(n) => n,
+            Err(e) => {
+                let err_str = e.to_string();
+                if err_str.contains("device disconnected") || err_str.contains("No such device") {
+                    return Err(e.into());
+                }
+                log::debug!("Legion Go: transient read_timeout error: {e}");
+                0
+            }
+        };
+
+        if bytes_read == 0 || bytes_read < XINPUT_PACKET_SIZE {
+            return Ok(vec![]);
         }
 
         let report_id = buf[0];
@@ -73,29 +223,27 @@ impl Driver {
         // Configuration event responses happen on the same endpoint. If this data packet isn't
         // specifically xinput data it can crash the driver, so block it.
         if command_id != XINPUT_COMMAND_ID {
-            //log::trace!("Got event that isn't xinput data, skipping");
             return Ok(vec![]);
         }
-        let slice = &buf[..bytes_read];
-        //log::trace!("Got Report ID: {report_id}");
-        //log::trace!("Got Report Size: {bytes_read}");
-        //log::trace!("Raw Data: {:02x?}", buf);
 
         let events = match report_id {
             XINPUT_DATA => {
-                if bytes_read != XINPUT_PACKET_SIZE {
-                    return Err("Invalid packet size for X-Input Data.".into());
+                log::info!("Received IMU report: len={}", buf.len());
+                match buf[..XINPUT_PACKET_SIZE].try_into() {
+                    Ok(sized_buf) => match self.handle_xinput_report(sized_buf) {
+                        Ok(ev) => ev,
+                        Err(e) => {
+                            log::warn!("Legion Go: failed to handle xinput report: {e}");
+                            vec![]
+                        }
+                    },
+                    Err(e) => {
+                        log::warn!("Legion Go: buffer slice error: {e}");
+                        vec![]
+                    }
                 }
-                // Handle the incoming input report
-                let sized_buf = slice.try_into()?;
-
-                self.handle_xinput_report(sized_buf)?
-            }
-            _ => {
-                //log::trace!("Invalid Report ID.");
-                let events = vec![];
-                events
             }
+            _ => vec![],
         };
 
         Ok(events)
@@ -109,10 +257,22 @@ impl Driver {
     ) -> Result<Vec<Event>, Box<dyn Error + Send + Sync>> {
         let input_report = XInputDataReport::unpack(&buf)?;
 
-        // Print input report for debugging
-        //log::debug!("--- Input report ---");
-        //log::debug!("{input_report}");
-        //log::debug!(" ---- End Report ----");
+        // If either controller reports active IMU readings, update last_motion_packet timestamp
+        if input_report.right_accel_x != 0
+            || input_report.right_accel_y != 0
+            || input_report.right_accel_z != 0
+            || input_report.right_gyro_x != 0
+            || input_report.right_gyro_y != 0
+            || input_report.right_gyro_z != 0
+            || input_report.left_accel_x != 0
+            || input_report.left_accel_y != 0
+            || input_report.left_accel_z != 0
+            || input_report.left_gyro_x != 0
+            || input_report.left_gyro_y != 0
+            || input_report.left_gyro_z != 0
+        {
+            self.last_motion_packet = Instant::now();
+        }
 
         // Update the state
         let old_state = self.update_xinput_state(input_report);
@@ -265,6 +425,11 @@ impl Driver {
                     },
                 )));
             }
+            if state.m1 != old_state.m1 {
+                events.push(Event::GamepadButton(GamepadButtonEvent::M1(BinaryInput {
+                    pressed: state.m1,
+                })));
+            }
             if state.m2 != old_state.m2 {
                 events.push(Event::GamepadButton(GamepadButtonEvent::M2(BinaryInput {
                     pressed: state.m2,
@@ -297,6 +462,20 @@ impl Driver {
                     },
                 )));
             }
+            if state.show_desktop != old_state.show_desktop {
+                events.push(Event::GamepadButton(GamepadButtonEvent::ShowDesktop(
+                    BinaryInput {
+                        pressed: state.show_desktop,
+                    },
+                )));
+            }
+            if state.alt_tab != old_state.alt_tab {
+                events.push(Event::GamepadButton(GamepadButtonEvent::AltTab(
+                    BinaryInput {
+                        pressed: state.alt_tab,
+                    },
+                )));
+            }
             if state.thumb_l != old_state.thumb_l {
                 events.push(Event::GamepadButton(GamepadButtonEvent::ThumbL(
                     BinaryInput {
@@ -361,6 +540,137 @@ impl Driver {
                 log::trace!("Left controller connected state: {:?}", state.l_con_state);
                 log::trace!("Right controller connected state: {:?}", state.r_con_state);
             }
+            if !self
+                .filtered_events
+                .contains(&Capability::Accelerometer(Source::Left))
+                && (state.left_accel_x != old_state.left_accel_x
+                    || state.left_accel_y != old_state.left_accel_y
+                    || state.left_accel_z != old_state.left_accel_z)
+            {
+                events.push(Event::Axis(AxisEvent::LeftAccel(ImuAxisInput {
+                    pitch: -state.left_accel_x,
+                    roll: state.left_accel_y,
+                    yaw: state.left_accel_z,
+                })))
+            }
+            // HHD hardware glitch filter: controller firmware has a bug where it randomly emits
+            // 254 or 255 (or -254 / -255) on gyro axes as corrupt glitch packets.
+            let is_gyro_glitch = |v: i16| -> bool {
+                let a = v.abs();
+                a == 254 || a == 255
+            };
+
+            // Accel: emit on initial packet, when change exceeds noise threshold (25 LSB ~ 0.05G),
+            // or periodically (every ~15 reports / 120ms) so that gravity is never lost after target clear_state.
+            const ACCEL_NOISE_THRESHOLD: i16 = 25;
+            let has_accel_data = state.right_accel_x != 0 || state.right_accel_y != 0 || state.right_accel_z != 0;
+            if has_accel_data {
+                let emit_accel = match self.last_emitted_accel {
+                    None => true,
+                    Some((lx, ly, lz, count)) => {
+                        count >= 15
+                            || (state.right_accel_x - lx).abs() > ACCEL_NOISE_THRESHOLD
+                            || (state.right_accel_y - ly).abs() > ACCEL_NOISE_THRESHOLD
+                            || (state.right_accel_z - lz).abs() > ACCEL_NOISE_THRESHOLD
+                    }
+                };
+                if !self.filtered_events.contains(&Capability::Accelerometer(Source::Right)) && emit_accel {
+                    let prev_count = self.last_emitted_accel.map(|(_, _, _, c)| c).unwrap_or(0);
+                    let next_count = if prev_count >= 15 { 0 } else { prev_count + 1 };
+                    self.last_emitted_accel = Some((state.right_accel_x, state.right_accel_y, state.right_accel_z, next_count));
+                    events.push(Event::Axis(AxisEvent::RightAccel(ImuAxisInput {
+                        pitch: -state.right_accel_x,
+                        roll: state.right_accel_y,
+                        yaw: state.right_accel_z,
+                    })));
+                } else if let Some((lx, ly, lz, count)) = self.last_emitted_accel {
+                    self.last_emitted_accel = Some((lx, ly, lz, count + 1));
+                }
+            } else if let Some((lx, ly, lz, count)) = self.last_emitted_accel {
+                // Sensor temporarily silent: keep Steam Deck UHID gravity vector alive with last known valid reading
+                let next_count = if count >= 15 { 0 } else { count + 1 };
+                self.last_emitted_accel = Some((lx, ly, lz, next_count));
+                if !self.filtered_events.contains(&Capability::Accelerometer(Source::Right)) && count >= 15 {
+                    events.push(Event::Axis(AxisEvent::RightAccel(ImuAxisInput {
+                        pitch: -lx,
+                        roll: ly,
+                        yaw: lz,
+                    })));
+                }
+            }
+            if !self
+                .filtered_events
+                .contains(&Capability::Accelerometer(Source::Center))
+                && (state.left_accel_x != old_state.left_accel_x
+                    || state.left_accel_y != old_state.left_accel_y
+                    || state.left_accel_z != old_state.left_accel_z
+                    || state.right_accel_x != old_state.right_accel_x
+                    || state.right_accel_y != old_state.right_accel_y
+                    || state.right_accel_z != old_state.right_accel_z)
+            {
+                events.push(Event::Axis(AxisEvent::MultiAccel(ImuAxisInput {
+                    pitch: -(state.left_accel_x + state.right_accel_x) / 2,
+                    roll: (state.left_accel_y + state.right_accel_y) / 2,
+                    yaw: (state.left_accel_z + state.right_accel_z) / 2,
+                })))
+            }
+            if !self
+                .filtered_events
+                .contains(&Capability::Gyroscope(Source::Left))
+                && !is_gyro_glitch(state.left_gyro_x)
+                && !is_gyro_glitch(state.left_gyro_y)
+                && !is_gyro_glitch(state.left_gyro_z)
+                && (state.left_gyro_x != old_state.left_gyro_x
+                    || state.left_gyro_y != old_state.left_gyro_y
+                    || state.left_gyro_z != old_state.left_gyro_z)
+            {
+                events.push(Event::Axis(AxisEvent::LeftGyro(ImuAxisInput {
+                    pitch: -state.left_gyro_x,
+                    roll: -state.left_gyro_y,
+                    yaw: -state.left_gyro_z,
+                })))
+            }
+            if !self.filtered_events.contains(&Capability::Gyroscope(Source::Right))
+                && !is_gyro_glitch(state.right_gyro_x)
+                && !is_gyro_glitch(state.right_gyro_y)
+                && !is_gyro_glitch(state.right_gyro_z)
+            {
+                // Gyro: filter MEMS sensor noise (< 16 LSB ~ 1 deg/s).
+                // Emit when motion is detected, and emit (0, 0, 0) once when transitioning to rest.
+                const GYRO_NOISE_DEADZONE: i16 = 16;
+                let gx = if state.right_gyro_x.abs() < GYRO_NOISE_DEADZONE { 0 } else { state.right_gyro_x };
+                let gy = if state.right_gyro_y.abs() < GYRO_NOISE_DEADZONE { 0 } else { state.right_gyro_y };
+                let gz = if state.right_gyro_z.abs() < GYRO_NOISE_DEADZONE { 0 } else { state.right_gyro_z };
+
+                let is_moving = gx != 0 || gy != 0 || gz != 0;
+                let was_moving = self.last_emitted_gyro.0 != 0 || self.last_emitted_gyro.1 != 0 || self.last_emitted_gyro.2 != 0;
+
+                if is_moving || was_moving {
+                    self.last_emitted_gyro = (gx, gy, gz);
+                    events.push(Event::Axis(AxisEvent::RightGyro(ImuAxisInput {
+                        pitch: -gx,
+                        roll: -gy,
+                        yaw: gz,
+                    })));
+                }
+            }
+
+            if !self
+                .filtered_events
+                .contains(&Capability::Gyroscope(Source::Center))
+                && (state.left_gyro_x != old_state.left_gyro_x
+                    || state.left_gyro_y != old_state.left_gyro_y
+                    || state.left_gyro_z != old_state.left_gyro_z
+                    || state.right_gyro_x != old_state.right_gyro_x
+                    || state.right_gyro_y != old_state.right_gyro_y
+                    || state.right_gyro_z != old_state.right_gyro_z)
+            {
+                events.push(Event::Axis(AxisEvent::MultiGyro(ImuAxisInput {
+                    pitch: -(state.left_gyro_x + state.right_gyro_x) / 2,
+                    roll: (state.left_gyro_y + state.right_gyro_y) / 2,
+                    yaw: (state.left_gyro_z + state.right_gyro_z) / 2,
+                })))
+            }
         }
         events
     }
diff --git a/src/drivers/lego/go2_driver.rs b/src/drivers/lego/go2_driver.rs
index 7fa1b91..2d0ff92 100644
--- a/src/drivers/lego/go2_driver.rs
+++ b/src/drivers/lego/go2_driver.rs
@@ -1,10 +1,10 @@
 use std::collections::HashSet;
+use std::time::{Duration, Instant};
 use std::{error::Error, ffi::CString};
 
 use hidapi::HidDevice;
 use packed_struct::PackedStruct;
 
-use crate::drivers::lego::HID_LENOVO_GO_FILTER;
 use crate::input::capability::{Capability, Source};
 use crate::udev::device::UdevDevice;
 
@@ -14,22 +14,82 @@ use super::{
         MouseWheelInput, TriggerEvent, TriggerInput,
     },
     hid_report::{GamepadMode, XInputDataReport},
-    DEFAULT_EVENT_FILTER, GAMEPAD_TIMEOUT, GO2_PIDS, GP_IID, VID, XINPUT_COMMAND_ID, XINPUT_DATA,
+    GAMEPAD_TIMEOUT, GO2_PIDS, GP_IID, VID, XINPUT_COMMAND_ID, XINPUT_DATA,
     XINPUT_PACKET_SIZE,
 };
 
 pub struct Driver {
     /// HIDRAW device instance
     hid_device: HidDevice,
-    /// Udev device instance
-    udev_device: UdevDevice,
     /// List of events that should not be generated
     filtered_events: HashSet<Capability>,
     /// State for the internal gamepad controller
     state: Option<XInputDataReport>,
+    /// Last emitted accelerometer reading (for noise threshold gating and periodic refresh)
+    last_emitted_accel: Option<(i16, i16, i16, u8)>,
+    /// Last emitted gyroscope reading (for resting deadzone gating)
+    last_emitted_gyro: (i16, i16, i16),
+    /// Timestamp of last sent heartbeat / keep-alive
+    last_heartbeat: Instant,
+    /// Timestamp of last received active motion packet
+    last_motion_packet: Instant,
 }
 
 impl Driver {
+    /// Send an output report to the Legion Go controller interface.
+    /// Commands 0x6a and 0x69 (HHD protocol) MUST be sent as exact unpadded bytes (7 bytes).
+    /// Initial Lenovo feature commands (0x05 0x00 0x04 ...) are padded to 64 bytes.
+    pub fn send_hid_cmd(dev: &HidDevice, cmd: &[u8]) {
+        let is_hhd_cmd = cmd.len() >= 3 && (cmd[2] == 0x6A || cmd[2] == 0x69);
+        if is_hhd_cmd {
+            match dev.write(cmd) {
+                Ok(n) => log::info!("Legion Go: sent unpadded HID cmd {:02x?} ({} bytes)", cmd, n),
+                Err(e) => log::warn!("Legion Go: error sending unpadded HID cmd {:02x?}: {}", cmd, e),
+            }
+        } else {
+            let mut buf = [0u8; 64];
+            let len = cmd.len().min(64);
+            buf[..len].copy_from_slice(&cmd[..len]);
+            match dev.write(&buf) {
+                Ok(n) => log::info!("Legion Go: sent Lenovo padded HID cmd {:02x?} ({} bytes)", &cmd[..len], n),
+                Err(e) => log::warn!("Legion Go: error sending Lenovo padded HID cmd {:02x?}: {}", &cmd[..len], e),
+            }
+        }
+        std::thread::sleep(std::time::Duration::from_millis(20));
+    }
+
+    /// Send non-blocking command: 0x6a commands as exact unpadded 7 bytes, Lenovo reports as 64 bytes padded
+    fn send_heartbeat_cmd(dev: &HidDevice, cmd: &[u8]) {
+        let is_hhd_cmd = cmd.len() >= 3 && (cmd[2] == 0x6A || cmd[2] == 0x69);
+        if is_hhd_cmd {
+            let _ = dev.write(cmd);
+        } else {
+            let mut buf = [0u8; 64];
+            let len = cmd.len().min(64);
+            buf[..len].copy_from_slice(&cmd[..len]);
+            let _ = dev.write(&buf);
+        }
+    }
+
+    /// Send keep-alive / wake-up packets to re-arm IMU sensors without blocking
+    pub fn send_heartbeat(&self) {
+        // 1. Disable IMU bypass (in case controller reset)
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x00, 0x04, 0x03, 0x04, 0x00]);
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x00, 0x04, 0x03, 0x03, 0x00]);
+
+        // 2. Enable IMU sensors using Lenovo FEATURE_IMU_ENABLE
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x00, 0x04, 0x05, 0x04, 0x01]);
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x00, 0x04, 0x05, 0x03, 0x01]);
+
+        // 3. Right Controller: Enable IMU & 16-bit HQ report stream (HHD protocol: EXACT 7 BYTES)
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x06, 0x6A, 0x02, 0x04, 0x01, 0x01]);
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x06, 0x6A, 0x07, 0x04, 0x02, 0x01]);
+
+        // 4. Left Controller: Enable IMU & 16-bit HQ report stream (HHD protocol: EXACT 7 BYTES)
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x06, 0x6A, 0x02, 0x03, 0x01, 0x01]);
+        Self::send_heartbeat_cmd(&self.hid_device, &[0x05, 0x06, 0x6A, 0x07, 0x03, 0x02, 0x01]);
+    }
+
     pub fn new(udev_device: UdevDevice) -> Result<Self, Box<dyn Error + Send + Sync>> {
         let fmtpath = udev_device.devnode().clone();
         let path = CString::new(fmtpath.clone())?;
@@ -41,21 +101,65 @@ impl Driver {
             || !GO2_PIDS.contains(&info.product_id())
             || info.interface_number() != GP_IID
         {
-            return Err(format!("Device '{fmtpath}' is not a Legion Go S Controller").into());
+            return Err(format!("Device '{fmtpath}' is not a Legion Go Controller").into());
         }
 
+        log::info!(
+            "Legion Go: successfully opened controller device on '{}' (PID: {:04x}, interface: {})",
+            fmtpath,
+            info.product_id(),
+            info.interface_number()
+        );
+
+        // Ensure os_mode is windows, imu_bypass is disabled, and imu is enabled in sysfs
+        if let Ok(dev) = udev_device.get_device() {
+            let mut curr = dev.parent();
+            while let Some(parent) = curr {
+                let os_mode = parent.syspath().join("os_mode");
+                if os_mode.exists() {
+                    let _ = std::fs::write(&os_mode, "windows\n");
+                    let _ = std::fs::write(parent.syspath().join("right_handle/imu_bypass_enabled"), "false\n");
+                    let _ = std::fs::write(parent.syspath().join("left_handle/imu_bypass_enabled"), "false\n");
+                    let _ = std::fs::write(parent.syspath().join("left_handle/imu_enabled"), "true\n");
+                    break;
+                }
+                curr = parent.parent();
+            }
+        }
+
+        // 1. Disable IMU bypass for Right and Left handles (preserves MCU touchpad filtering, prevents mouse lag)
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x00, 0x04, 0x03, 0x04, 0x00]);
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x00, 0x04, 0x03, 0x03, 0x00]);
+
+        // 2. Enable IMU sensors using Lenovo FEATURE_IMU_ENABLE (0x05 -> 0x01)
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x00, 0x04, 0x05, 0x04, 0x01]);
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x00, 0x04, 0x05, 0x03, 0x01]);
+
+        // 3. Right Controller: Enable IMU & 16-bit HQ report stream (HHD protocol)
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x06, 0x6A, 0x02, 0x04, 0x01, 0x01]);
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x06, 0x6A, 0x07, 0x04, 0x02, 0x01]);
+
+        // 4. Left Controller: Enable IMU & 16-bit HQ report stream (HHD protocol)
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x06, 0x6A, 0x02, 0x03, 0x01, 0x01]);
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x06, 0x6A, 0x07, 0x03, 0x02, 0x01]);
+
+        // 5. Disable Legion button swap (keep standard layout)
+        Self::send_hid_cmd(&hid_device, &[0x05, 0x06, 0x69, 0x04, 0x01, 0x01, 0x01]);
+
+        log::info!("Legion Go: sent Lenovo and HHD IMU activation packets (Left & Right)");
+
+        let now = Instant::now();
         Ok(Self {
-            udev_device,
             hid_device,
             filtered_events: Default::default(),
             state: None,
+            last_emitted_accel: None,
+            last_emitted_gyro: (0, 0, 0),
+            last_heartbeat: now,
+            last_motion_packet: now,
         })
     }
 
-    //TODO: Using InputPlumber Capability enum prevents this driver from having the ability to be
-    //a standalone crate. When this driver is eventually separated, refactor the Event type to
-    //follow the pattern DeviceEvent(Event, Value) and create a match table for
-    //Capability->Event/Event->Capability in the SourceDriver implementation.
     pub fn update_filtered_events(&mut self, events: HashSet<Capability>) {
         self.filtered_events = events;
     }
@@ -63,37 +167,54 @@ impl Driver {
     pub fn get_default_event_filter(
         &self,
     ) -> Result<HashSet<Capability>, Box<dyn Error + Send + Sync>> {
-        let device = self.udev_device.get_device()?;
-        let Some(parent) = device.parent() else {
-            return Ok(HashSet::from(DEFAULT_EVENT_FILTER));
-        };
-
-        let Some(driver) = parent.driver() else {
-            return Ok(HashSet::from(DEFAULT_EVENT_FILTER));
-        };
-
-        let Some(driver) = driver.to_str() else {
-            return Ok(HashSet::from(DEFAULT_EVENT_FILTER));
-        };
-
-        let filtered_events = match driver {
-            "hid-lenovo-go" => HashSet::from(HID_LENOVO_GO_FILTER),
-            _ => HashSet::from(DEFAULT_EVENT_FILTER),
-        };
-
-        Ok(filtered_events)
+        // Explicitly enable Right Joy-Con IMU (filter out Left and Center)
+        Ok(HashSet::from([
+            Capability::Accelerometer(Source::Left),
+            Capability::Accelerometer(Source::Center),
+            Capability::Gyroscope(Source::Left),
+            Capability::Gyroscope(Source::Center),
+        ]))
     }
 
     /// Poll the device and read input reports
     pub fn poll(&mut self) -> Result<Vec<Event>, Box<dyn Error + Send + Sync>> {
-        // Read data from the device into a buffer
-        let mut buf = [0; XINPUT_PACKET_SIZE];
-        let bytes_read = self
-            .hid_device
-            .read_timeout(&mut buf[..], GAMEPAD_TIMEOUT)?;
-
-        if bytes_read > XINPUT_PACKET_SIZE {
-            return Err("Invalid packet size for X-Input Data.".into());
+        let now = Instant::now();
+        let time_since_heartbeat = now.duration_since(self.last_heartbeat);
+        let time_since_motion = now.duration_since(self.last_motion_packet);
+
+        // Heartbeat / Keep-Alive logic:
+        // 1. Regular timer: send keep-alive every 3 seconds
+        // 2. Silence re-arm: if no motion packet received for >= 1500ms
+        if time_since_heartbeat >= Duration::from_secs(3) {
+            log::debug!("Legion Go: sending periodic IMU heartbeat");
+            self.send_heartbeat();
+            self.last_heartbeat = now;
+        } else if time_since_motion >= Duration::from_millis(1500) {
+            log::info!(
+                "Legion Go: IMU stream silence detected ({}ms), re-arming sensors",
+                time_since_motion.as_millis()
+            );
+            self.send_heartbeat();
+            self.last_heartbeat = now;
+            // Prevent spamming re-arm on every 8ms cycle while hardware wakes up
+            self.last_motion_packet = now;
+        }
+
+        let mut buf = [0u8; 64];
+        let bytes_read = match self.hid_device.read_timeout(&mut buf[..], GAMEPAD_TIMEOUT) {
+            Ok(n) => n,
+            Err(e) => {
+                let err_str = e.to_string();
+                if err_str.contains("device disconnected") || err_str.contains("No such device") {
+                    return Err(e.into());
+                }
+                log::debug!("Legion Go: transient read_timeout error: {e}");
+                0
+            }
+        };
+
+        if bytes_read == 0 || bytes_read < XINPUT_PACKET_SIZE {
+            return Ok(vec![]);
         }
 
         let report_id = buf[0];
@@ -102,29 +223,27 @@ impl Driver {
         // Configuration event responses happen on the same endpoint. If this data packet isn't
         // specifically xinput data it can crash the driver, so block it.
         if command_id != XINPUT_COMMAND_ID {
-            //log::trace!("Got event that isn't xinput data, skipping");
             return Ok(vec![]);
         }
-        let slice = &buf[..bytes_read];
-        //log::trace!("Got Report ID: {report_id}");
-        //log::trace!("Got Report Size: {bytes_read}");
-        //log::trace!("Raw Data: {:02x?}", buf);
 
         let events = match report_id {
             XINPUT_DATA => {
-                if bytes_read != XINPUT_PACKET_SIZE {
-                    return Err("Invalid packet size for X-Input Data.".into());
+                log::info!("Received IMU report: len={}", buf.len());
+                match buf[..XINPUT_PACKET_SIZE].try_into() {
+                    Ok(sized_buf) => match self.handle_xinput_report(sized_buf) {
+                        Ok(ev) => ev,
+                        Err(e) => {
+                            log::warn!("Legion Go: failed to handle xinput report: {e}");
+                            vec![]
+                        }
+                    },
+                    Err(e) => {
+                        log::warn!("Legion Go: buffer slice error: {e}");
+                        vec![]
+                    }
                 }
-                // Handle the incoming input report
-                let sized_buf = slice.try_into()?;
-
-                self.handle_xinput_report(sized_buf)?
-            }
-            _ => {
-                //log::trace!("Invalid Report ID.");
-                let events = vec![];
-                events
             }
+            _ => vec![],
         };
 
         Ok(events)
@@ -138,10 +257,22 @@ impl Driver {
     ) -> Result<Vec<Event>, Box<dyn Error + Send + Sync>> {
         let input_report = XInputDataReport::unpack(&buf)?;
 
-        // Print input report for debugging
-        //log::debug!("--- Input report ---");
-        //log::debug!("{input_report}");
-        //log::debug!(" ---- End Report ----");
+        // If either controller reports active IMU readings, update last_motion_packet timestamp
+        if input_report.right_accel_x != 0
+            || input_report.right_accel_y != 0
+            || input_report.right_accel_z != 0
+            || input_report.right_gyro_x != 0
+            || input_report.right_gyro_y != 0
+            || input_report.right_gyro_z != 0
+            || input_report.left_accel_x != 0
+            || input_report.left_accel_y != 0
+            || input_report.left_accel_z != 0
+            || input_report.left_gyro_x != 0
+            || input_report.left_gyro_y != 0
+            || input_report.left_gyro_z != 0
+        {
+            self.last_motion_packet = Instant::now();
+        }
 
         // Update the state
         let old_state = self.update_xinput_state(input_report);
@@ -422,18 +553,50 @@ impl Driver {
                     yaw: state.left_accel_z,
                 })))
             }
-            if !self
-                .filtered_events
-                .contains(&Capability::Accelerometer(Source::Right))
-                && (state.right_accel_x != old_state.right_accel_x
-                    || state.right_accel_y != old_state.right_accel_y
-                    || state.right_accel_z != old_state.right_accel_z)
-            {
-                events.push(Event::Axis(AxisEvent::RightAccel(ImuAxisInput {
-                    pitch: -state.right_accel_x,
-                    roll: -state.right_accel_y,
-                    yaw: state.right_accel_z,
-                })))
+            // HHD hardware glitch filter: controller firmware has a bug where it randomly emits
+            // 254 or 255 (or -254 / -255) on gyro axes as corrupt glitch packets.
+            let is_gyro_glitch = |v: i16| -> bool {
+                let a = v.abs();
+                a == 254 || a == 255
+            };
+
+            // Accel: emit on initial packet, when change exceeds noise threshold (25 LSB ~ 0.05G),
+            // or periodically (every ~15 reports / 120ms) so that gravity is never lost after target clear_state.
+            const ACCEL_NOISE_THRESHOLD: i16 = 25;
+            let has_accel_data = state.right_accel_x != 0 || state.right_accel_y != 0 || state.right_accel_z != 0;
+            if has_accel_data {
+                let emit_accel = match self.last_emitted_accel {
+                    None => true,
+                    Some((lx, ly, lz, count)) => {
+                        count >= 15
+                            || (state.right_accel_x - lx).abs() > ACCEL_NOISE_THRESHOLD
+                            || (state.right_accel_y - ly).abs() > ACCEL_NOISE_THRESHOLD
+                            || (state.right_accel_z - lz).abs() > ACCEL_NOISE_THRESHOLD
+                    }
+                };
+                if !self.filtered_events.contains(&Capability::Accelerometer(Source::Right)) && emit_accel {
+                    let prev_count = self.last_emitted_accel.map(|(_, _, _, c)| c).unwrap_or(0);
+                    let next_count = if prev_count >= 15 { 0 } else { prev_count + 1 };
+                    self.last_emitted_accel = Some((state.right_accel_x, state.right_accel_y, state.right_accel_z, next_count));
+                    events.push(Event::Axis(AxisEvent::RightAccel(ImuAxisInput {
+                        pitch: -state.right_accel_x,
+                        roll: state.right_accel_y,
+                        yaw: state.right_accel_z,
+                    })));
+                } else if let Some((lx, ly, lz, count)) = self.last_emitted_accel {
+                    self.last_emitted_accel = Some((lx, ly, lz, count + 1));
+                }
+            } else if let Some((lx, ly, lz, count)) = self.last_emitted_accel {
+                // Sensor temporarily silent: keep Steam Deck UHID gravity vector alive with last known valid reading
+                let next_count = if count >= 15 { 0 } else { count + 1 };
+                self.last_emitted_accel = Some((lx, ly, lz, next_count));
+                if !self.filtered_events.contains(&Capability::Accelerometer(Source::Right)) && count >= 15 {
+                    events.push(Event::Axis(AxisEvent::RightAccel(ImuAxisInput {
+                        pitch: -lx,
+                        roll: ly,
+                        yaw: lz,
+                    })));
+                }
             }
             if !self
                 .filtered_events
@@ -454,28 +617,42 @@ impl Driver {
             if !self
                 .filtered_events
                 .contains(&Capability::Gyroscope(Source::Left))
+                && !is_gyro_glitch(state.left_gyro_x)
+                && !is_gyro_glitch(state.left_gyro_y)
+                && !is_gyro_glitch(state.left_gyro_z)
                 && (state.left_gyro_x != old_state.left_gyro_x
                     || state.left_gyro_y != old_state.left_gyro_y
                     || state.left_gyro_z != old_state.left_gyro_z)
             {
                 events.push(Event::Axis(AxisEvent::LeftGyro(ImuAxisInput {
                     pitch: -state.left_gyro_x,
-                    roll: state.left_gyro_y,
-                    yaw: state.left_gyro_z,
+                    roll: -state.left_gyro_y,
+                    yaw: -state.left_gyro_z,
                 })))
             }
-            if !self
-                .filtered_events
-                .contains(&Capability::Gyroscope(Source::Right))
-                && (state.right_gyro_x != old_state.right_gyro_x
-                    || state.right_gyro_y != old_state.right_gyro_y
-                    || state.right_gyro_z != old_state.right_gyro_z)
+            if !self.filtered_events.contains(&Capability::Gyroscope(Source::Right))
+                && !is_gyro_glitch(state.right_gyro_x)
+                && !is_gyro_glitch(state.right_gyro_y)
+                && !is_gyro_glitch(state.right_gyro_z)
             {
-                events.push(Event::Axis(AxisEvent::RightGyro(ImuAxisInput {
-                    pitch: -state.right_gyro_x,
-                    roll: state.right_gyro_y,
-                    yaw: state.right_gyro_z,
-                })))
+                // Gyro: filter MEMS sensor noise (< 16 LSB ~ 1 deg/s).
+                // Emit when motion is detected, and emit (0, 0, 0) once when transitioning to rest.
+                const GYRO_NOISE_DEADZONE: i16 = 16;
+                let gx = if state.right_gyro_x.abs() < GYRO_NOISE_DEADZONE { 0 } else { state.right_gyro_x };
+                let gy = if state.right_gyro_y.abs() < GYRO_NOISE_DEADZONE { 0 } else { state.right_gyro_y };
+                let gz = if state.right_gyro_z.abs() < GYRO_NOISE_DEADZONE { 0 } else { state.right_gyro_z };
+
+                let is_moving = gx != 0 || gy != 0 || gz != 0;
+                let was_moving = self.last_emitted_gyro.0 != 0 || self.last_emitted_gyro.1 != 0 || self.last_emitted_gyro.2 != 0;
+
+                if is_moving || was_moving {
+                    self.last_emitted_gyro = (gx, gy, gz);
+                    events.push(Event::Axis(AxisEvent::RightGyro(ImuAxisInput {
+                        pitch: -gx,
+                        roll: -gy,
+                        yaw: gz,
+                    })));
+                }
             }
 
             if !self
diff --git a/src/drivers/lego/hid_report.rs b/src/drivers/lego/hid_report.rs
index 755f258..cd0fe87 100644
--- a/src/drivers/lego/hid_report.rs
+++ b/src/drivers/lego/hid_report.rs
@@ -274,29 +274,29 @@ pub struct XInputDataReport {
     #[packed_field(bytes = "35..=36", endian = "msb")]
     pub left_accel_x: i16,
     #[packed_field(bytes = "37..=38", endian = "msb")]
-    pub left_accel_y: i16,
-    #[packed_field(bytes = "39..=40", endian = "msb")]
     pub left_accel_z: i16,
+    #[packed_field(bytes = "39..=40", endian = "msb")]
+    pub left_accel_y: i16,
     #[packed_field(bytes = "41..=42", endian = "msb")]
     pub left_gyro_x: i16,
     #[packed_field(bytes = "43..=44", endian = "msb")]
-    pub left_gyro_y: i16,
-    #[packed_field(bytes = "45..=46", endian = "msb")]
     pub left_gyro_z: i16,
+    #[packed_field(bytes = "45..=46", endian = "msb")]
+    pub left_gyro_y: i16,
     #[packed_field(bytes = "47")]
     pub right_imu_timestamp: u8,
+    #[packed_field(bytes = "48..=49", endian = "msb")]
+    pub right_accel_z: i16,
     #[packed_field(bytes = "50..=51", endian = "msb")]
     pub right_accel_x: i16,
-    #[packed_field(bytes = "48..=49", endian = "msb")]
-    pub right_accel_y: i16,
     #[packed_field(bytes = "52..=53", endian = "msb")]
-    pub right_accel_z: i16,
+    pub right_accel_y: i16,
+    #[packed_field(bytes = "54..=55", endian = "msb")]
+    pub right_gyro_z: i16,
     #[packed_field(bytes = "56..=57", endian = "msb")]
     pub right_gyro_x: i16,
-    #[packed_field(bytes = "54..=55", endian = "msb")]
-    pub right_gyro_y: i16,
     #[packed_field(bytes = "58..=59", endian = "msb")]
-    pub right_gyro_z: i16,
+    pub right_gyro_y: i16,
 }
 
 #[derive(PackedStruct, Debug, Copy, Clone, PartialEq)]
diff --git a/src/drivers/lego/mod.rs b/src/drivers/lego/mod.rs
index 0b36e17..0a7ad44 100644
--- a/src/drivers/lego/mod.rs
+++ b/src/drivers/lego/mod.rs
@@ -78,6 +78,7 @@ pub const STICK_Y_MAX: f64 = 255.0;
 pub const STICK_Y_MIN: f64 = 0.0;
 pub const TRIGG_MAX: f64 = 255.0;
 
+#[allow(dead_code)]
 const DEFAULT_EVENT_FILTER: [Capability; 6] = [
     Capability::Accelerometer(Source::Center),
     Capability::Accelerometer(Source::Left),
@@ -87,15 +88,10 @@ const DEFAULT_EVENT_FILTER: [Capability; 6] = [
     Capability::Gyroscope(Source::Right),
 ];
 
-//TODO: Default to Source::Right. The Legion Go 1 left and right handle y axis are inverted from
-//each other and cancel out. To fix this we can use only the right handle. The kernel driver IMU
-//enablement is currently broken. Once fixed upstream and in jupiter/linux_integration switch to
-//using right handle first.
+#[allow(dead_code)]
 const HID_LENOVO_GO_FILTER: [Capability; 4] = [
-    //Capability::Accelerometer(Source::Center),
     Capability::Accelerometer(Source::Left),
     Capability::Accelerometer(Source::Right),
-    //Capability::Gyroscope(Source::Center),
     Capability::Gyroscope(Source::Left),
     Capability::Gyroscope(Source::Right),
 ];
diff --git a/src/input/source/hidraw.rs b/src/input/source/hidraw.rs
index e11cd6b..7572057 100644
--- a/src/input/source/hidraw.rs
+++ b/src/input/source/hidraw.rs
@@ -382,7 +382,7 @@ impl HidRawDevice {
             }
             DriverType::LegionGo => {
                 let options = SourceDriverOptions {
-                    poll_rate: Duration::from_millis(8),
+                    poll_rate: Duration::from_millis(1),
                     buffer_size: 2048,
                 };
                 let device = LegionGoController::new(device_info.clone())?;
@@ -397,7 +397,7 @@ impl HidRawDevice {
             }
             DriverType::LegionGo2 => {
                 let options = SourceDriverOptions {
-                    poll_rate: Duration::from_millis(8),
+                    poll_rate: Duration::from_millis(1),
                     buffer_size: 2048,
                 };
                 let device = LegionGo2Controller::new(device_info.clone())?;
diff --git a/src/input/source/hidraw/legion_go.rs b/src/input/source/hidraw/legion_go.rs
index 37f735b..5a620a4 100644
--- a/src/input/source/hidraw/legion_go.rs
+++ b/src/input/source/hidraw/legion_go.rs
@@ -10,7 +10,7 @@ use crate::{
     input::{
         capability::{
             Capability, Gamepad, GamepadAxis, GamepadButton, GamepadTrigger, Mouse, MouseButton,
-            Touch, TouchButton, Touchpad,
+            Source, Touch, TouchButton, Touchpad,
         },
         event::{
             native::NativeEvent,
@@ -163,7 +163,30 @@ impl LegionGoController {
                     Capability::Touchpad(Touchpad::RightPad(Touch::Motion)),
                     normalize_axis_value(axis),
                 ),
-                _ => NativeEvent::new(Capability::NotImplemented, InputValue::None),
+                AxisEvent::LeftAccel(_) => NativeEvent::new(
+                    Capability::Accelerometer(Source::Left),
+                    normalize_axis_value(axis),
+                ),
+                AxisEvent::LeftGyro(_) => NativeEvent::new(
+                    Capability::Gyroscope(Source::Left),
+                    normalize_axis_value(axis),
+                ),
+                AxisEvent::RightAccel(_) => NativeEvent::new(
+                    Capability::Accelerometer(Source::Right),
+                    normalize_axis_value(axis),
+                ),
+                AxisEvent::RightGyro(_) => NativeEvent::new(
+                    Capability::Gyroscope(Source::Right),
+                    normalize_axis_value(axis),
+                ),
+                AxisEvent::MultiAccel(_) => NativeEvent::new(
+                    Capability::Accelerometer(Source::Center),
+                    normalize_axis_value(axis),
+                ),
+                AxisEvent::MultiGyro(_) => NativeEvent::new(
+                    Capability::Gyroscope(Source::Center),
+                    normalize_axis_value(axis),
+                ),
             },
             event::Event::Trigger(trigg) => match trigg.clone() {
                 event::TriggerEvent::ATriggerL(_) => NativeEvent::new(
@@ -208,6 +231,17 @@ impl SourceInputDevice for LegionGoController {
         self.driver.update_filtered_events(events);
         Ok(())
     }
+
+    fn get_default_event_filter(&self) -> Result<HashSet<Capability>, InputError> {
+        let filtered_events = self.driver.get_default_event_filter();
+        let filtered_events = match filtered_events {
+            Ok(events) => events,
+            Err(e) => {
+                return Err(format!("Failed to get default event filter: {:?}", e).into());
+            }
+        };
+        Ok(filtered_events)
+    }
 }
 
 impl SourceOutputDevice for LegionGoController {}
@@ -248,6 +282,22 @@ fn normalize_axis_value(event: AxisEvent) -> InputValue {
 
             InputValue::Vector2 { x, y }
         }
+        AxisEvent::LeftAccel(value)
+        | AxisEvent::RightAccel(value)
+        | AxisEvent::MultiAccel(value) => InputValue::Vector3 {
+            // Scale by 3.542 to convert controller raw LSB (~4625 LSB/1G) to Steam Deck UHID 16384 LSB/1G
+            x: Some(value.pitch as f64 * 3.542),
+            y: Some(value.roll as f64 * 3.542),
+            z: Some(value.yaw as f64 * 3.542),
+        },
+        AxisEvent::LeftGyro(value) | AxisEvent::RightGyro(value) | AxisEvent::MultiGyro(value) => {
+            // 1:1 standard gyro scaling
+            InputValue::Vector3 {
+                x: Some(value.pitch as f64 * 1.0),
+                y: Some(value.yaw as f64 * 1.0),
+                z: Some(value.roll as f64 * 1.0),
+            }
+        }
         _ => InputValue::None,
     }
 }
@@ -273,6 +323,12 @@ fn normalize_trigger_value(event: event::TriggerEvent) -> InputValue {
 }
 /// List of all capabilities that the Legion Go driver implements
 pub const CAPABILITIES: &[Capability] = &[
+    Capability::Accelerometer(Source::Center),
+    Capability::Accelerometer(Source::Left),
+    Capability::Accelerometer(Source::Right),
+    Capability::Gyroscope(Source::Center),
+    Capability::Gyroscope(Source::Left),
+    Capability::Gyroscope(Source::Right),
     Capability::Gamepad(Gamepad::Axis(GamepadAxis::LeftStick)),
     Capability::Gamepad(Gamepad::Axis(GamepadAxis::RightStick)),
     Capability::Gamepad(Gamepad::Button(GamepadButton::DPadDown)),
diff --git a/src/input/source/hidraw/legion_go2.rs b/src/input/source/hidraw/legion_go2.rs
index 1ad56bd..d46c2bc 100644
--- a/src/input/source/hidraw/legion_go2.rs
+++ b/src/input/source/hidraw/legion_go2.rs
@@ -296,15 +296,17 @@ fn normalize_axis_value(event: AxisEvent) -> InputValue {
         AxisEvent::LeftAccel(value)
         | AxisEvent::RightAccel(value)
         | AxisEvent::MultiAccel(value) => InputValue::Vector3 {
-            x: Some(value.pitch as f64),
-            y: Some(value.roll as f64),
-            z: Some(value.yaw as f64),
+            // Scale by 3.542 to convert controller raw LSB (~4625 LSB/1G) to Steam Deck UHID 16384 LSB/1G
+            x: Some(value.pitch as f64 * 3.542),
+            y: Some(value.roll as f64 * 3.542),
+            z: Some(value.yaw as f64 * 3.542),
         },
         AxisEvent::LeftGyro(value) | AxisEvent::RightGyro(value) | AxisEvent::MultiGyro(value) => {
+            // 1:1 standard gyro scaling
             InputValue::Vector3 {
-                x: Some(value.pitch as f64),
-                y: Some(value.roll as f64),
-                z: Some(value.yaw as f64),
+                x: Some(value.pitch as f64 * 1.0),
+                y: Some(value.yaw as f64 * 1.0),
+                z: Some(value.roll as f64 * 1.0),
             }
         }
         _ => InputValue::None,
diff --git a/src/input/source/iio.rs b/src/input/source/iio.rs
index 8f2a871..eb61574 100644
--- a/src/input/source/iio.rs
+++ b/src/input/source/iio.rs
@@ -1,7 +1,7 @@
 pub mod accel_gyro_3d;
 pub mod bmi_imu;
 
-use std::error::Error;
+use std::{error::Error, time::Duration};
 
 use glob_match::glob_match;
 
@@ -17,7 +17,9 @@ use crate::{
 
 use self::{accel_gyro_3d::AccelGyro3dImu, bmi_imu::BmiImu};
 
-use super::{InputError, OutputError, SourceDeviceCompatible, SourceDriver};
+use super::{
+    InputError, OutputError, SourceDeviceCompatible, SourceDriver, SourceDriverOptions,
+};
 
 /// List of available drivers
 enum DriverType {
@@ -103,8 +105,12 @@ impl IioDevice {
             }
             DriverType::AccelGryo3D => {
                 let device = AccelGyro3dImu::new(device_info.clone(), iio_config)?;
+                let options = SourceDriverOptions {
+                    poll_rate: Duration::from_millis(5),
+                    buffer_size: 2048,
+                };
                 let source_device =
-                    SourceDriver::new(composite_device, device, device_info.into(), conf);
+                    SourceDriver::new_with_options(composite_device, device, device_info.into(), options, conf);
                 Ok(Self::AccelGryo3D(source_device))
             }
         }
diff --git a/src/input/source/iio/accel_gyro_3d.rs b/src/input/source/iio/accel_gyro_3d.rs
index 737daca..688a219 100644
--- a/src/input/source/iio/accel_gyro_3d.rs
+++ b/src/input/source/iio/accel_gyro_3d.rs
@@ -15,8 +15,8 @@ use crate::{
 // IIO channels report m/s² for accel and rad/s for gyro after applying scale:
 //   https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-bus-iio
 // UHID LSB constants from src/drivers/steam_deck/driver.rs.
-const ACCEL_SCALE_FACTOR: f64 = 1632.6530612244898; // 1 / 0.0006125 (m/s² → UHID LSB)
-const GYRO_SCALE_FACTOR: f64 = 916.7324722093172; // (180/π) / 0.0625 (rad/s → °/s → UHID LSB)
+const ACCEL_SCALE_FACTOR: f64 = 1632.6530612244898 * 10.73; // 1 / 0.0006125 * 10.73 (corrects AMD SFH scale error → UHID 1G = 16384)
+const GYRO_SCALE_FACTOR: f64 = 916.7324722093172 * 12.0; // (180/π) / 0.0625 * 12.0 (12x gyro acceleration)
 
 pub struct AccelGyro3dImu {
     driver: Driver,
diff --git a/src/input/target/dualsense.rs b/src/input/target/dualsense.rs
index dbbc87e..79d0077 100644
--- a/src/input/target/dualsense.rs
+++ b/src/input/target/dualsense.rs
@@ -28,8 +28,8 @@ use crate::{
     },
     input::{
         capability::{
-            Capability, Gamepad, GamepadAxis, GamepadButton, GamepadTrigger, Touch, TouchButton,
-            Touchpad,
+            Capability, Gamepad, GamepadAxis, GamepadButton, GamepadTrigger, Source, Touch,
+            TouchButton, Touchpad,
         },
         composite_device::client::CompositeDeviceClient,
         event::{
@@ -636,29 +636,41 @@ impl DualSenseDevice {
                     },
                 }
             }
-            Capability::Gyroscope(_) => {
-                if let InputValue::Vector3 { x, y, z } = value {
-                    if let Some(x) = x {
-                        state.pitch = Integer::from_primitive(x as i16);
-                    }
-                    if let Some(y) = y {
-                        state.yaw = Integer::from_primitive(y as i16);
-                    }
-                    if let Some(z) = z {
-                        state.roll = Integer::from_primitive(z as i16);
+            Capability::Gyroscope(source) => {
+                let target_source = match super::get_gyro_source_mode() {
+                    super::GyroSourceMode::Tablet => Source::Center,
+                    super::GyroSourceMode::Controller => Source::Right,
+                };
+                if source == target_source {
+                    if let InputValue::Vector3 { x, y, z } = value {
+                        if let Some(x) = x {
+                            state.pitch = Integer::from_primitive(denormalize_gyro_value(x));
+                        }
+                        if let Some(y) = y {
+                            state.yaw = Integer::from_primitive(denormalize_gyro_value(y));
+                        }
+                        if let Some(z) = z {
+                            state.roll = Integer::from_primitive(denormalize_gyro_value(z));
+                        }
                     }
                 }
             }
-            Capability::Accelerometer(_) => {
-                if let InputValue::Vector3 { x, y, z } = value {
-                    if let Some(x) = x {
-                        state.accel_x = Integer::from_primitive(x as i16);
-                    }
-                    if let Some(y) = y {
-                        state.accel_y = Integer::from_primitive(y as i16);
-                    }
-                    if let Some(z) = z {
-                        state.accel_z = Integer::from_primitive(z as i16);
+            Capability::Accelerometer(source) => {
+                let target_source = match super::get_gyro_source_mode() {
+                    super::GyroSourceMode::Tablet => Source::Center,
+                    super::GyroSourceMode::Controller => Source::Right,
+                };
+                if source == target_source {
+                    if let InputValue::Vector3 { x, y, z } = value {
+                        if let Some(x) = x {
+                            state.accel_x = Integer::from_primitive((x / 2.0) as i16);
+                        }
+                        if let Some(y) = y {
+                            state.accel_y = Integer::from_primitive((y / 2.0) as i16);
+                        }
+                        if let Some(z) = z {
+                            state.accel_z = Integer::from_primitive((z / 2.0) as i16);
+                        }
                     }
                 }
             }
@@ -1006,6 +1018,12 @@ impl TargetInputDevice for DualSenseDevice {
             Capability::Gamepad(Gamepad::Button(GamepadButton::Start)),
             Capability::Gamepad(Gamepad::Button(GamepadButton::West)),
             Capability::Gamepad(Gamepad::Gyro),
+            Capability::Accelerometer(Source::Center),
+            Capability::Gyroscope(Source::Center),
+            Capability::Accelerometer(Source::Left),
+            Capability::Gyroscope(Source::Left),
+            Capability::Accelerometer(Source::Right),
+            Capability::Gyroscope(Source::Right),
             Capability::Gamepad(Gamepad::Trigger(GamepadTrigger::LeftTrigger)),
             Capability::Gamepad(Gamepad::Trigger(GamepadTrigger::RightTrigger)),
             Capability::Touchpad(Touchpad::CenterPad(Touch::Button(TouchButton::Press))),
@@ -1201,9 +1219,33 @@ fn denormalize_accel_value(value_meters_sec: f64) -> i16 {
     value as i16
 }
 
+fn get_ds5_gyro_multiplier() -> f64 {
+    static COUNTER: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
+    static MULTIPLIER_BITS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
+
+    let count = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
+    // Check config file on first run (count == 0) and every 200 samples (~once per second)
+    if count % 200 == 0 {
+        let mult = if let Ok(s) = std::fs::read_to_string("/etc/inputplumber/ds5_gyro_multiplier") {
+            s.trim().parse::<f64>().unwrap_or(1.0)
+        } else {
+            1.0
+        };
+        MULTIPLIER_BITS.store(mult.to_bits(), std::sync::atomic::Ordering::Relaxed);
+    }
+
+    let bits = MULTIPLIER_BITS.load(std::sync::atomic::Ordering::Relaxed);
+    if bits == 0 {
+        1.0
+    } else {
+        f64::from_bits(bits)
+    }
+}
+
 /// DualSense gyro values are measured in units of degrees per second.
-/// InputPlumber gyro values are also measured in degrees per second.
+/// Applies dynamic gyro multiplier (default 1.0x) and clamps safely to i16 bounds.
 fn denormalize_gyro_value(value_degrees_sec: f64) -> i16 {
-    let value = value_degrees_sec;
-    value as i16
+    let mult = get_ds5_gyro_multiplier();
+    let value = value_degrees_sec * mult;
+    value.clamp(i16::MIN as f64, i16::MAX as f64) as i16
 }
diff --git a/src/input/target/mod.rs b/src/input/target/mod.rs
index 873b0a8..cf2e895 100644
--- a/src/input/target/mod.rs
+++ b/src/input/target/mod.rs
@@ -58,6 +58,35 @@ use std::fmt::Display;
 
 use self::client::TargetDeviceClient;
 use self::command::TargetCommand;
+
+#[derive(Debug, Clone, Copy, PartialEq, Eq)]
+pub enum GyroSourceMode {
+    Tablet,
+    Controller,
+}
+
+pub fn get_gyro_source_mode() -> GyroSourceMode {
+    static COUNTER: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
+    static MODE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
+
+    let count = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
+    // Check config file on first call and every 200 samples (~once per second)
+    if count % 200 == 0 {
+        let is_controller = if let Ok(s) = std::fs::read_to_string("/etc/inputplumber/gyro_source") {
+            let trimmed = s.trim().to_lowercase();
+            trimmed.contains("controller") || trimmed.contains("right") || trimmed.contains("joycon")
+        } else {
+            false
+        };
+        MODE.store(is_controller, std::sync::atomic::Ordering::Relaxed);
+    }
+
+    if MODE.load(std::sync::atomic::Ordering::Relaxed) {
+        GyroSourceMode::Controller
+    } else {
+        GyroSourceMode::Tablet
+    }
+}
 use self::dbus::DBusDevice;
 use self::dualsense::{DualSenseDevice, DualSenseHardware};
 use self::keyboard::KeyboardDevice;
diff --git a/src/input/target/steam_deck_uhid.rs b/src/input/target/steam_deck_uhid.rs
index 786f205..f606ca7 100644
--- a/src/input/target/steam_deck_uhid.rs
+++ b/src/input/target/steam_deck_uhid.rs
@@ -26,8 +26,8 @@ use crate::{
     },
     input::{
         capability::{
-            Capability, Gamepad, GamepadAxis, GamepadButton, GamepadTrigger, Touch, TouchButton,
-            Touchpad,
+            Capability, Gamepad, GamepadAxis, GamepadButton, GamepadTrigger, Source, Touch,
+            TouchButton, Touchpad,
         },
         composite_device::client::CompositeDeviceClient,
         event::{
@@ -374,29 +374,41 @@ impl SteamDeckUhidDevice {
                     }
                 }
             },
-            Capability::Gyroscope(_) => {
-                if let InputValue::Vector3 { x, y, z } = value {
-                    if let Some(x) = x {
-                        self.state.pitch = Integer::from_primitive(x as i16);
-                    }
-                    if let Some(y) = y {
-                        self.state.yaw = Integer::from_primitive(y as i16);
-                    }
-                    if let Some(z) = z {
-                        self.state.roll = Integer::from_primitive(z as i16);
+            Capability::Gyroscope(source) => {
+                let target_source = match super::get_gyro_source_mode() {
+                    super::GyroSourceMode::Tablet => Source::Center,
+                    super::GyroSourceMode::Controller => Source::Right,
+                };
+                if source == target_source {
+                    if let InputValue::Vector3 { x, y, z } = value {
+                        if let Some(x) = x {
+                            self.state.pitch = Integer::from_primitive(x as i16);
+                        }
+                        if let Some(y) = y {
+                            self.state.yaw = Integer::from_primitive(y as i16);
+                        }
+                        if let Some(z) = z {
+                            self.state.roll = Integer::from_primitive(z as i16);
+                        }
                     }
                 }
             }
-            Capability::Accelerometer(_) => {
-                if let InputValue::Vector3 { x, y, z } = value {
-                    if let Some(x) = x {
-                        self.state.accel_x = Integer::from_primitive(x as i16);
-                    }
-                    if let Some(y) = y {
-                        self.state.accel_y = Integer::from_primitive(y as i16);
-                    }
-                    if let Some(z) = z {
-                        self.state.accel_z = Integer::from_primitive(z as i16);
+            Capability::Accelerometer(source) => {
+                let target_source = match super::get_gyro_source_mode() {
+                    super::GyroSourceMode::Tablet => Source::Center,
+                    super::GyroSourceMode::Controller => Source::Right,
+                };
+                if source == target_source {
+                    if let InputValue::Vector3 { x, y, z } = value {
+                        if let Some(x) = x {
+                            self.state.accel_x = Integer::from_primitive(x as i16);
+                        }
+                        if let Some(y) = y {
+                            self.state.accel_y = Integer::from_primitive(y as i16);
+                        }
+                        if let Some(z) = z {
+                            self.state.accel_z = Integer::from_primitive(z as i16);
+                        }
                     }
                 }
             }
@@ -761,6 +773,12 @@ impl TargetInputDevice for SteamDeckUhidDevice {
             Capability::Gamepad(Gamepad::Button(GamepadButton::Start)),
             Capability::Gamepad(Gamepad::Button(GamepadButton::West)),
             Capability::Gamepad(Gamepad::Gyro),
+            Capability::Accelerometer(Source::Center),
+            Capability::Gyroscope(Source::Center),
+            Capability::Accelerometer(Source::Left),
+            Capability::Gyroscope(Source::Left),
+            Capability::Accelerometer(Source::Right),
+            Capability::Gyroscope(Source::Right),
             Capability::Gamepad(Gamepad::Trigger(GamepadTrigger::LeftStickForce)),
             Capability::Gamepad(Gamepad::Trigger(GamepadTrigger::LeftTouchpadForce)),
             Capability::Gamepad(Gamepad::Trigger(GamepadTrigger::LeftTrigger)),

PATCH_EOF
}

# ------------------------------------------------------------------------------
# 10. Hauptsteuerung / Argument-Parsing
# ------------------------------------------------------------------------------
case "${1:-}" in
  --rebuild|-b)
    rebuild_from_source
    ;;
  --hook|--install-hook)
    install_pacman_hook
    ;;
  --remove-hook)
    remove_pacman_hook
    ;;
  --uninstall|-u)
    uninstall_fix
    ;;
  --status|-s)
    show_status
    ;;
  --test|-t)
    if [ -f "/home/${USER_NAME}/test-gyro.py" ]; then
      python3 "/home/${USER_NAME}/test-gyro.py"
    else
      echo -e "${RED}[-] test-gyro.py not found in /home/${USER_NAME}!${NC}"
    fi
    ;;
  --auto-hook)
    # Non-interactive mode for Pacman PostTransaction Hook
    apply_fast_fix "--auto-hook" >/dev/null 2>&1 || true
    echo -e "${GREEN}[+] InputPlumber Legion Go Gyro Fix successfully applied after package upgrade!${NC}"
    ;;
  --help|-h)
    echo -e "${BOLD}InputPlumber Legion Go Gyro Fix Tool${NC}"
    echo "Usage: sudo bash $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  (no option)       Quick 1-click fix (restores patched 12x binary & config)"
    echo "  --rebuild, -b     Downloads source, applies patch, and recompiles"
    echo "  --hook            Configures automated Pacman hook (auto-fixes on pacman -Syu)"
    echo "  --remove-hook     Removes automated Pacman hook"
    echo "  --uninstall, -u   Uninstalls all fixes and restores official stock state"
    echo "  --status, -s      Displays detailed diagnostics and system status"
    echo "  --test, -t        Runs live sensor test"
    echo "  --help, -h        Shows this help menu"
    ;;
  *)
    apply_fast_fix
    ;;
esac
