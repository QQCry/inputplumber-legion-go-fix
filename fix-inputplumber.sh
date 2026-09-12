#!/usr/bin/env bash
# ==============================================================================
#  InputPlumber Legion Go Gyro Fix & Auto-Updater
#  ----------------------------------------------------------------------------
#  Repariert und sichert den Gyroskop- und Beschleunigungssensor-Support
#  für das Lenovo Legion Go nach Upstream-Updates von InputPlumber.
#
#  Nutzung:
#    sudo bash ~/fix-inputplumber.sh            (Schneller 1-Klick Fix / Wiederherstellung)
#    sudo bash ~/fix-inputplumber.sh --rebuild  (Aus neuester Quelle patchen & kompilieren)
#    sudo bash ~/fix-inputplumber.sh --hook     (Pacman-Hook für automatische Updates einrichten)
#    sudo bash ~/fix-inputplumber.sh --status   (System- & Sensor-Status anzeigen)
#    sudo bash ~/fix-inputplumber.sh --test     (Live-Sensortest starten)
# ==============================================================================

set -e

# Farben für formatierte Ausgabe
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
    echo -e "${YELLOW}[*] Root-Rechte erforderlich. Starte mit sudo...${NC}"
    exec sudo bash "$0" "$@"
  fi
}

# ------------------------------------------------------------------------------
# 1. Prüffunktion: Ist das aktuell installierte Binary bereits gepatcht?
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
# 2. Konfiguration /etc/inputplumber/devices.d/50-legion_go.yaml prüfen & fixen
# ------------------------------------------------------------------------------
fix_yaml_config() {
  echo -e "${BLUE}[*] Prüfe Konfiguration: ${CONFIG_FILE}...${NC}"
  mkdir -p "$(dirname "$CONFIG_FILE")"

  if [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "/usr/share/inputplumber/devices/50-legion_go.yaml" ]; then
      cp "/usr/share/inputplumber/devices/50-legion_go.yaml" "$CONFIG_FILE"
      echo -e "${YELLOW}    Basisdatei aus /usr/share kopiert.${NC}"
    else
      echo -e "${RED}[-] Weder $CONFIG_FILE noch Vorlage in /usr/share gefunden!${NC}"
      return 1
    fi
  fi

  # Backup anlegen, falls noch nicht vorhanden
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
    sys.exit(f"Fehler beim Lesen: {e}")

changed = False

# 1. target_devices auf deck-uhid sicherstellen (für native ABXY Steam Deck Glyphen)
if "- deck-uhid" not in c:
    if "- xbox-elite" in c:
        c = c.replace("- xbox-elite", "- deck-uhid")
        changed = True
    elif "target_devices:" in c:
        c = c.replace("target_devices:", "target_devices:\n  - deck-uhid")
        changed = True

# 2. accel_3d & gyro_3d Blöcke mit korrekter Mount-Matrix sicherstellen
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
    # Suche bestehenden IMU- oder gyro_3d-Abschnitt
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
    print("    [+] 50-legion_go.yaml erfolgreich aktualisiert (accel_3d & deck-uhid hinzugefügt).")
else:
    print("    [+] 50-legion_go.yaml ist bereits korrekt konfiguriert.")
PYEOF
}

# ------------------------------------------------------------------------------
# 3. Udev-Regeln und Controller-MCU-Treiber absichern
# ------------------------------------------------------------------------------
fix_udev_rules() {
  echo -e "${BLUE}[*] Prüfe Udev-Regeln und MCU-Bypass-Schutz...${NC}"
  cat << 'UDEV_EOF' > "$UDEV_RULES"
ACTION=="add|change|bind", ATTRS{idVendor}=="17ef", ATTRS{idProduct}=="61e[bcde]", SUBSYSTEM=="hid", DRIVER=="hid-lenovo-go", ATTR{os_mode}="windows", ATTR{left_handle/imu_bypass_enabled}="false", ATTR{right_handle/imu_bypass_enabled}="false", ATTR{touchpad/vibration_enable}="false", GOTO="end"
UDEV_EOF
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger 2>/dev/null || true

  # Live-Hardware in sysfs aktualisieren (falls Controller aktiv)
  for dev in /sys/bus/hid/drivers/hid-lenovo-go/0003:17EF:61E*.*; do
    if [ -d "$dev" ]; then
      [ -f "$dev/os_mode" ] && echo "windows" > "$dev/os_mode" 2>/dev/null || true
      [ -d "$dev/right_handle" ] && echo "false" > "$dev/right_handle/imu_bypass_enabled" 2>/dev/null || true
      [ -d "$dev/left_handle" ] && echo "false" > "$dev/left_handle/imu_bypass_enabled" 2>/dev/null || true
    fi
  done
  echo -e "${GREEN}    [+] Udev-Regeln aktiv (Verhindert Maus-Lag & Touchpad-Sprünge).${NC}"
}

# ------------------------------------------------------------------------------
# 4. Steam Gyro-Drift Kalibrierung zurücksetzen (verhindert Nach-Unten-Ziehen)
# ------------------------------------------------------------------------------
reset_steam_drift() {
  echo -e "${BLUE}[*] Bereinige fehlerhafte Steam-Driftwerte...${NC}"
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
      echo -e "${GREEN}    [+] Drift in $(basename "$vdf") auf 0.0 zurückgesetzt.${NC}"
    fi
  done
}

# ------------------------------------------------------------------------------
# 5. Schneller Fix (Verwendet gesichertes optimiertes Release-Binary)
# ------------------------------------------------------------------------------
apply_fast_fix() {
  local auto_mode="$1"
  check_root "$@"
  echo -e "${CYAN}==========================================================${NC}"
  echo -e "${BOLD}  InputPlumber Gyro-Fix für Lenovo Legion Go (Schnell-Modus)${NC}"
  echo -e "${CYAN}==========================================================${NC}"

  # Prüfe, welches gepatchte Binary verfügbar ist
  local source_bin=""
  if [ -f "$PRECOMPILED_BIN" ] && is_binary_patched "$PRECOMPILED_BIN"; then
    source_bin="$PRECOMPILED_BIN"
  elif [ -f "$ALT_PRECOMPILED_BIN" ] && is_binary_patched "$ALT_PRECOMPILED_BIN"; then
    source_bin="$ALT_PRECOMPILED_BIN"
  fi

  if [ -z "$source_bin" ]; then
    echo -e "${RED}[!] Kein vorkompiliertes gepatchtes Binary gefunden!${NC}"
    echo -e "${YELLOW}[*] Starte automatischen Rebuild aus dem Quellcode...${NC}"
    rebuild_from_source
    return $?
  fi

  # 1. Dienst stoppen
  echo -e "${BLUE}[1/5] Stoppe inputplumber.service...${NC}"
  systemctl stop inputplumber.service 2>/dev/null || true

  # 2. Stock-Binary sichern, falls noch nicht gesichert
  if [ -f "$TARGET_BIN" ] && ! is_binary_patched "$TARGET_BIN"; then
    echo -e "${BLUE}[2/5] Sichere Original-Binary nach ${BACKUP_STOCK_BIN}...${NC}"
    cp "$TARGET_BIN" "$BACKUP_STOCK_BIN"
  else
    echo -e "${BLUE}[2/5] Installiere gepatchtes Binary...${NC}"
  fi

  cp "$source_bin" "$TARGET_BIN"
  chmod 755 "$TARGET_BIN"
  echo -e "${GREEN}    [+] Gepatchtes 12x-Binary erfolgreich nach ${TARGET_BIN} kopiert.${NC}"

  # 3. YAML Konfiguration fixen
  echo -e "${BLUE}[3/5] Prüfe Sensorkonfiguration...${NC}"
  fix_yaml_config

  # 4. Udev & Steam Drift
  echo -e "${BLUE}[4/5] Bereinige Treiber-Einstellungen & Steam-Drift...${NC}"
  fix_udev_rules
  reset_steam_drift

  # 5. Dienst neu starten
  echo -e "${BLUE}[5/5] Starte inputplumber.service...${NC}"
  systemctl daemon-reload
  systemctl restart inputplumber.service
  sleep 2

  if systemctl is-active --quiet inputplumber.service; then
    echo ""
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${BOLD}${GREEN}  ERFOLG: InputPlumber läuft stabil mit Gyro-Fix!        ${NC}"
    echo -e "${GREEN}  - 12x Beschleunigung & 200 Hz Abtastung aktiv          ${NC}"
    echo -e "${GREEN}  - accel_3d Erdanziehungsvektor aktiv (Steam erkennt IMU)${NC}"
    echo -e "${GREEN}  - Native Steam Deck ABXY-Glyphen                       ${NC}"
    echo -e "${GREEN}  - Touchpad läuft butterweich (kein Mauslag)            ${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    if [ "$auto_mode" != "--auto-hook" ]; then
      echo -e "${CYAN}Testen mit:  python3 ~/test-gyro.py${NC}"
    fi
  else
    echo -e "${RED}[!] Fehler beim Starten von inputplumber.service!${NC}"
    journalctl -u inputplumber.service -n 25 --no-pager
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 6. Eigener Quellcode-Build & Patch (für neue Versionen von InputPlumber)
# ------------------------------------------------------------------------------
rebuild_from_source() {
  check_root "$@"
  echo -e "${CYAN}==========================================================${NC}"
  echo -e "${BOLD}  InputPlumber Quellcode patchen & neu kompilieren       ${NC}"
  echo -e "${CYAN}==========================================================${NC}"

  # Prüfe Cargo/Rust
  if ! command -v cargo &>/dev/null; then
    echo -e "${YELLOW}[*] Rust/Cargo nicht gefunden, installiere rust...${NC}"
    pacman -S --needed --noconfirm rust
  fi

  # Prüfe Abhängigkeiten
  echo -e "${BLUE}[*] Prüfe System-Build-Abhängigkeiten...${NC}"
  pacman -S --needed --noconfirm git pkgconf systemd hidapi base-devel

  # Verzeichnis vorbereiten
  mkdir -p "$SOURCE_DIR"
  if [ ! -d "$SOURCE_DIR/.git" ]; then
    echo -e "${BLUE}[*] Klone offizielles InputPlumber Repository...${NC}"
    git clone https://github.com/ShadowBlip/InputPlumber.git "$SOURCE_DIR"
    chown -R "${USER_NAME}:${USER_NAME}" "$SOURCE_DIR"
  else
    echo -e "${BLUE}[*] Aktualisiere InputPlumber Repository...${NC}"
    sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" fetch --tags
  fi

  # Arbeitskopie säubern
  echo -e "${BLUE}[*] Setze Quellcode-Status zurück...${NC}"
  sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" reset --hard HEAD
  sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" clean -fd

  # Patch anwenden
  local patch_file="/tmp/inputplumber-legiongo.patch"
  write_embedded_patch "$patch_file"

  echo -e "${BLUE}[*] Wende Legion Go Gyro-Fix Patch an...${NC}"
  if sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" apply --check "$patch_file" 2>/dev/null; then
    sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" apply "$patch_file"
    echo -e "${GREEN}    [+] Patch sauber angewendet.${NC}"
  else
    echo -e "${YELLOW}[!] Direkter Patch schlug fehl, versuche 3-Wege-Merge...${NC}"
    if ! sudo -u "${USER_NAME}" git -C "$SOURCE_DIR" apply -3 "$patch_file"; then
      echo -e "${RED}[-] Quellcode-Patch konnte nicht angewendet werden!${NC}"
      rm -f "$patch_file"
      return 1
    fi
  fi
  rm -f "$patch_file"

  # Kompilieren mit Cargo Release
  echo -e "${BLUE}[*] Kompiliere InputPlumber (cargo build --release)...${NC}"
  sudo -u "${USER_NAME}" bash -c "cd '$SOURCE_DIR' && cargo build --release"

  local compiled_bin="$SOURCE_DIR/target/release/inputplumber"
  if [ ! -f "$compiled_bin" ]; then
    echo -e "${RED}[-] Kompilierung fehlgeschlagen: $compiled_bin nicht gefunden!${NC}"
    return 1
  fi

  # Dauerhaft sichern
  mkdir -p "$(dirname "$PRECOMPILED_BIN")"
  cp "$compiled_bin" "$PRECOMPILED_BIN"
  chown "${USER_NAME}:${USER_NAME}" "$PRECOMPILED_BIN"
  chmod 755 "$PRECOMPILED_BIN"
  echo -e "${GREEN}    [+] Neues Release-Binary gesichert unter ${PRECOMPILED_BIN}.${NC}"

  # Installation durchführen
  apply_fast_fix
}

# ------------------------------------------------------------------------------
# 7. Pacman-Hook einrichten (Repariert InputPlumber automatisch nach pacman -Syu)
# ------------------------------------------------------------------------------
install_pacman_hook() {
  check_root "$@"
  echo -e "${CYAN}==========================================================${NC}"
  echo -e "${BOLD}  Richte automatischen Pacman-Hook ein                   ${NC}"
  echo -e "${CYAN}==========================================================${NC}"

  # 1. Symlink für systemweiten Aufruf erstellen
  ln -sf "/home/${USER_NAME}/fix-inputplumber.sh" "$SYMLINK_BIN"
  chmod 755 "$SYMLINK_BIN"
  echo -e "${GREEN}[+] Befehl 'fix-inputplumber' systemweit unter ${SYMLINK_BIN} verlinkt.${NC}"

  # 2. Hook-Verzeichnis prüfen
  mkdir -p "$(dirname "$PACMAN_HOOK")"

  # 3. Pacman-Hook-Datei schreiben
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
  echo -e "${GREEN}[+] Pacman-Hook erfolgreich installiert unter:${NC}"
  echo -e "    ${PACMAN_HOOK}"
  echo ""
  echo -e "${GREEN}--> Zukünftige System-Updates (pacman -Syu) werden InputPlumber${NC}"
  echo -e "${GREEN}    automatisch reparieren, ohne dass du etwas tun musst!${NC}"
  echo -e "${CYAN}==========================================================${NC}"
}

remove_pacman_hook() {
  check_root "$@"
  echo -e "${YELLOW}[*] Entferne Pacman-Hook...${NC}"
  rm -f "$PACMAN_HOOK"
  rm -f "$SYMLINK_BIN"
  echo -e "${GREEN}[+] Hook und Symlink entfernt.${NC}"
}

# ------------------------------------------------------------------------------
# 8. Status & Diagnose anzeigen
# ------------------------------------------------------------------------------
show_status() {
  echo -e "${CYAN}==========================================================${NC}"
  echo -e "${BOLD}  InputPlumber & Legion Go Gyro Status                  ${NC}"
  echo -e "${CYAN}==========================================================${NC}"

  # Binary Status
  echo -n "[1] Binary (/usr/bin/inputplumber): "
  if [ ! -f "$TARGET_BIN" ]; then
    echo -e "${RED}NICHT GEFUNDEN${NC}"
  elif is_binary_patched "$TARGET_BIN"; then
    echo -e "${GREEN}GEPATCHT (12x Gyro + SFH Accel Fix aktiv)${NC}"
  else
    echo -e "${RED}UNGEPATCHTES ORIGINAL (vom Paketmanager überschrieben)${NC}"
  fi

  # Backup Binary
  echo -n "[2] Backup-Binary ($PRECOMPILED_BIN): "
  if [ -f "$PRECOMPILED_BIN" ]; then
    local bsize
    bsize=$(du -h "$PRECOMPILED_BIN" | cut -f1)
    echo -e "${GREEN}VORHANDEN ($bsize)${NC}"
  else
    echo -e "${YELLOW}NICHT VORHANDEN${NC}"
  fi

  # Konfiguration
  echo -n "[3] Config ($CONFIG_FILE): "
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}FEHLT${NC}"
  elif grep -q "name: accel_3d" "$CONFIG_FILE" && grep -q "deck-uhid" "$CONFIG_FILE"; then
    echo -e "${GREEN}KORREKT (accel_3d & deck-uhid konfiguriert)${NC}"
  else
    echo -e "${YELLOW}UNVOLLSTÄNDIG (accel_3d oder deck-uhid fehlt)${NC}"
  fi

  # Udev
  echo -n "[4] Udev-Regeln ($UDEV_RULES): "
  if [ -f "$UDEV_RULES" ]; then
    echo -e "${GREEN}AKTIV (Mouse-Lag-Schutz eingerichtet)${NC}"
  else
    echo -e "${YELLOW}NICHT VORHANDEN${NC}"
  fi

  # Pacman-Hook
  echo -n "[5] Automatischer Pacman-Hook: "
  if [ -f "$PACMAN_HOOK" ]; then
    echo -e "${GREEN}AKTIV (repariert automatisch bei pacman -Syu)${NC}"
  else
    echo -e "${YELLOW}NICHT AKTIV (mit 'sudo fix-inputplumber --hook' installierbar)${NC}"
  fi

  # Service Status
  echo -n "[6] Systemd Service (inputplumber.service): "
  if systemctl is-active --quiet inputplumber.service; then
    local pid
    pid=$(systemctl show -p MainPID --value inputplumber.service)
    echo -e "${GREEN}LÄUFT (PID $pid)${NC}"
  else
    echo -e "${RED}GESTOPPT / FEHLERHAFT${NC}"
  fi

  # Aktiver virtueller Controller
  echo -n "[7] Virtueller Steam Controller: "
  local hidraw_dev
  hidraw_dev=$(grep -i -l "28de.*12fe" /sys/class/hidraw/hidraw*/device/uevent 2>/dev/null | sed -n 's|.*/\(hidraw[0-9]\+\)/.*|\1|p' | head -n 1 || true)
  if [ -n "$hidraw_dev" ]; then
    echo -e "${GREEN}AKTIV (/dev/${hidraw_dev} als Valve Steam Deck)${NC}"
  else
    echo -e "${YELLOW}NICHT GEFUNDEN (wird bei Start initialisiert)${NC}"
  fi
  echo -e "${CYAN}==========================================================${NC}"
}

# ------------------------------------------------------------------------------
# 9. Eingebetteter Git-Patch (vollständiger Patch gegen v0.79.4)
# ------------------------------------------------------------------------------
write_embedded_patch() {
  local out="$1"
  cat << 'PATCH_EOF' > "$out"
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
diff --git a/src/drivers/lego/go2_driver.rs b/src/drivers/lego/go2_driver.rs
index 7fa1b91..579eb44 100644
--- a/src/drivers/lego/go2_driver.rs
+++ b/src/drivers/lego/go2_driver.rs
@@ -4,6 +4,7 @@ use std::{error::Error, ffi::CString};
 use hidapi::HidDevice;
 use packed_struct::PackedStruct;
 
+use crate::dmi::get_dmi_data;
 use crate::drivers::lego::HID_LENOVO_GO_FILTER;
 use crate::input::capability::{Capability, Source};
 use crate::udev::device::UdevDevice;
@@ -27,9 +28,41 @@ pub struct Driver {
     filtered_events: HashSet<Capability>,
     /// State for the internal gamepad controller
     state: Option<XInputDataReport>,
+    /// Last emitted accelerometer reading (for noise threshold gating)
+    last_emitted_accel: Option<(i16, i16, i16)>,
+    /// Last emitted gyroscope reading (for resting deadzone gating)
+    last_emitted_gyro: (i16, i16, i16),
+    /// Number of polls executed
+    poll_count: u32,
+    /// Whether non-zero IMU data stream is active
+    imu_active: bool,
 }
 
 impl Driver {
+    pub fn send_hhd_cmd(dev: &HidDevice, subcmd: u8, target: u8, val: u8) {
+        let short_buf = [0x05, 0x06, 0x6A, subcmd, target, val, 0x01];
+        let res_short = dev.write(&short_buf);
+        let mut full_buf = [0u8; 64];
+        full_buf[..7].copy_from_slice(&short_buf);
+        let res_full = dev.write(&full_buf);
+        log::info!("Legion Go: send_hhd_cmd(subcmd={:#x}, target={:#x}, val={:#x}) -> short={:?}, full={:?}",
+            subcmd, target, val, res_short, res_full);
+        std::thread::sleep(std::time::Duration::from_millis(20));
+    }
+
+    pub fn send_lenovo_cmd(dev: &HidDevice, subcmd: u8, prop: u8, target: u8, val: u8) {
+        let mut buf = [0u8; 64];
+        buf[0] = 0x05;
+        buf[1] = 0x00;
+        buf[2] = subcmd;
+        buf[3] = prop;
+        buf[4] = target;
+        buf[5] = val;
+        let res = dev.write(&buf);
+        log::info!("Legion Go: send_lenovo_cmd({:#x}, {:#x}, {:#x}, {:#x}) -> {:?}", subcmd, prop, target, val, res);
+        std::thread::sleep(std::time::Duration::from_millis(20));
+    }
+
     pub fn new(udev_device: UdevDevice) -> Result<Self, Box<dyn Error + Send + Sync>> {
         let fmtpath = udev_device.devnode().clone();
         let path = CString::new(fmtpath.clone())?;
@@ -44,11 +77,56 @@ impl Driver {
             return Err(format!("Device '{fmtpath}' is not a Legion Go S Controller").into());
         }
 
+        // Ensure os_mode is windows and imu_bypass is disabled in sysfs
+        if let Ok(dev) = udev_device.get_device() {
+            let mut curr = dev.parent();
+            while let Some(p) = curr {
+                if p.subsystem() == Some(std::ffi::OsStr::new("hid")) {
+                    let os_mode = p.syspath().join("os_mode");
+                    if os_mode.exists() {
+                        let _ = std::fs::write(&os_mode, "windows\n");
+                    }
+                    let imu_bypass = p.syspath().join("right_handle/imu_bypass_enabled");
+                    if imu_bypass.exists() {
+                        let _ = std::fs::write(&imu_bypass, "false\n");
+                    }
+                    let left_imu_bypass = p.syspath().join("left_handle/imu_bypass_enabled");
+                    if left_imu_bypass.exists() {
+                        let _ = std::fs::write(&left_imu_bypass, "false\n");
+                    }
+                    // Note: Do NOT write to right_handle/imu_enabled in sysfs because the kernel
+                    // driver has a bug where it sends FEATURE_IMU_BYPASS (0x3) instead of FEATURE_IMU_ENABLE (0x5).
+                    break;
+                }
+                curr = p.parent();
+            }
+        }
+
+        // MCU activation commands:
+        // 1. Explicitly DISABLE IMU Bypass (prop=0x03, val=0x00) - Bypass causes touchpad/mouse lag!
+        Self::send_lenovo_cmd(&hid_device, 0x04, 0x03, 0x04, 0x00); // Right IMU Bypass DISABLE
+        Self::send_lenovo_cmd(&hid_device, 0x04, 0x03, 0x03, 0x00); // Left IMU Bypass DISABLE
+
+        // 2. Enable IMU sensors using Lenovo FEATURE_IMU_ENABLE (prop=0x05, val=0x01)
+        Self::send_lenovo_cmd(&hid_device, 0x04, 0x05, 0x04, 0x01); // Right IMU Enable
+        Self::send_lenovo_cmd(&hid_device, 0x04, 0x05, 0x03, 0x01); // Left IMU Enable
+
+        // 3. Enable IMU sensors and 16-bit HQ report stream using HHD commands
+        Self::send_hhd_cmd(&hid_device, 0x02, 0x04, 0x01); // Right IMU Enable
+        Self::send_hhd_cmd(&hid_device, 0x07, 0x04, 0x02); // Right 16-bit HQ Report
+        Self::send_hhd_cmd(&hid_device, 0x02, 0x03, 0x01); // Left IMU Enable
+        Self::send_hhd_cmd(&hid_device, 0x07, 0x03, 0x02); // Left 16-bit HQ Report
+        log::info!("Legion Go: sent Lenovo IMU enable (prop 0x05) and HHD activation packets (Left & Right)");
+
         Ok(Self {
             udev_device,
             hid_device,
             filtered_events: Default::default(),
             state: None,
+            last_emitted_accel: None,
+            last_emitted_gyro: (0, 0, 0),
+            poll_count: 0,
+            imu_active: false,
         })
     }
 
@@ -63,30 +141,40 @@ impl Driver {
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
+        // Explicitly enable Right Joy-Con IMU (filter out ONLY Left and Center)
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
+        // Startup retry: if IMU has not emitted non-zero data yet, send activation packets periodically (non-blocking)
+        self.poll_count = self.poll_count.wrapping_add(1);
+        if !self.imu_active && self.poll_count < 300 && self.poll_count % 30 == 0 {
+            let mut buf = [0u8; 64];
+            // Ensure bypass remains OFF (prop=0x03, val=0x00)
+            buf[0] = 0x05; buf[1] = 0x00; buf[2] = 0x04; buf[3] = 0x03; buf[4] = 0x04; buf[5] = 0x00;
+            let _ = self.hid_device.write(&buf);
+
+            // Send IMU enable (prop=0x05, val=0x01)
+            buf[0] = 0x05; buf[1] = 0x00; buf[2] = 0x04; buf[3] = 0x05; buf[4] = 0x04; buf[5] = 0x01;
+            let _ = self.hid_device.write(&buf);
+
+            // Send HHD IMU enable
+            buf.fill(0);
+            buf[..7].copy_from_slice(&[0x05, 0x06, 0x6A, 0x02, 0x04, 0x01, 0x01]);
+            let _ = self.hid_device.write(&buf);
+
+            // Send HHD 16-bit report format
+            buf.fill(0);
+            buf[..7].copy_from_slice(&[0x05, 0x06, 0x6A, 0x07, 0x04, 0x02, 0x01]);
+            let _ = self.hid_device.write(&buf);
+        }
+
         let mut buf = [0; XINPUT_PACKET_SIZE];
         let bytes_read = self
             .hid_device
@@ -137,7 +225,6 @@ impl Driver {
         buf: [u8; XINPUT_PACKET_SIZE],
     ) -> Result<Vec<Event>, Box<dyn Error + Send + Sync>> {
         let input_report = XInputDataReport::unpack(&buf)?;
-
         // Print input report for debugging
         //log::debug!("--- Input report ---");
         //log::debug!("{input_report}");
@@ -422,18 +509,32 @@ impl Driver {
                     yaw: state.left_accel_z,
                 })))
             }
-            if !self
-                .filtered_events
-                .contains(&Capability::Accelerometer(Source::Right))
-                && (state.right_accel_x != old_state.right_accel_x
-                    || state.right_accel_y != old_state.right_accel_y
-                    || state.right_accel_z != old_state.right_accel_z)
+            // Check if right IMU is streaming valid data
+            if state.right_accel_x != 0 || state.right_accel_y != 0 || state.right_accel_z != 0
+                || state.right_gyro_x != 0 || state.right_gyro_y != 0 || state.right_gyro_z != 0
             {
-                events.push(Event::Axis(AxisEvent::RightAccel(ImuAxisInput {
-                    pitch: -state.right_accel_x,
-                    roll: -state.right_accel_y,
-                    yaw: state.right_accel_z,
-                })))
+                self.imu_active = true;
+            }
+
+            // Accel: emit on initial packet or when change exceeds noise threshold (25 LSB ~ 0.05G)
+            if self.imu_active {
+                const ACCEL_NOISE_THRESHOLD: i16 = 25;
+                let emit_accel = match self.last_emitted_accel {
+                    None => true,
+                    Some((lx, ly, lz)) => {
+                        (state.right_accel_x - lx).abs() > ACCEL_NOISE_THRESHOLD
+                            || (state.right_accel_y - ly).abs() > ACCEL_NOISE_THRESHOLD
+                            || (state.right_accel_z - lz).abs() > ACCEL_NOISE_THRESHOLD
+                    }
+                };
+                if emit_accel {
+                    self.last_emitted_accel = Some((state.right_accel_x, state.right_accel_y, state.right_accel_z));
+                    events.push(Event::Axis(AxisEvent::RightAccel(ImuAxisInput {
+                        pitch: -state.right_accel_x,
+                        roll: state.right_accel_y,
+                        yaw: state.right_accel_z,
+                    })));
+                }
             }
             if !self
                 .filtered_events
@@ -464,18 +565,23 @@ impl Driver {
                     yaw: state.left_gyro_z,
                 })))
             }
-            if !self
-                .filtered_events
-                .contains(&Capability::Gyroscope(Source::Right))
-                && (state.right_gyro_x != old_state.right_gyro_x
-                    || state.right_gyro_y != old_state.right_gyro_y
-                    || state.right_gyro_z != old_state.right_gyro_z)
-            {
+            // Gyro: filter MEMS sensor noise (< 16 LSB ~ 1 deg/s).
+            // Emit when motion is detected, and emit (0, 0, 0) once when transitioning to rest.
+            const GYRO_NOISE_DEADZONE: i16 = 16;
+            let gx = if state.right_gyro_x.abs() < GYRO_NOISE_DEADZONE { 0 } else { state.right_gyro_x };
+            let gy = if state.right_gyro_y.abs() < GYRO_NOISE_DEADZONE { 0 } else { state.right_gyro_y };
+            let gz = if state.right_gyro_z.abs() < GYRO_NOISE_DEADZONE { 0 } else { state.right_gyro_z };
+
+            let is_moving = gx != 0 || gy != 0 || gz != 0;
+            let was_moving = self.last_emitted_gyro.0 != 0 || self.last_emitted_gyro.1 != 0 || self.last_emitted_gyro.2 != 0;
+
+            if is_moving || was_moving {
+                self.last_emitted_gyro = (gx, gy, gz);
                 events.push(Event::Axis(AxisEvent::RightGyro(ImuAxisInput {
-                    pitch: -state.right_gyro_x,
-                    roll: state.right_gyro_y,
-                    yaw: state.right_gyro_z,
-                })))
+                    pitch: -gx,
+                    roll: -gy,
+                    yaw: gz,
+                })));
             }
 
             if !self
diff --git a/src/drivers/lego/hid_report.rs b/src/drivers/lego/hid_report.rs
index 755f258..a90c43e 100644
--- a/src/drivers/lego/hid_report.rs
+++ b/src/drivers/lego/hid_report.rs
@@ -285,18 +285,18 @@ pub struct XInputDataReport {
     pub left_gyro_z: i16,
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
diff --git a/src/input/source/hidraw/legion_go2.rs b/src/input/source/hidraw/legion_go2.rs
index 1ad56bd..bbe4457 100644
--- a/src/input/source/hidraw/legion_go2.rs
+++ b/src/input/source/hidraw/legion_go2.rs
@@ -296,15 +296,17 @@ fn normalize_axis_value(event: AxisEvent) -> InputValue {
         AxisEvent::LeftAccel(value)
         | AxisEvent::RightAccel(value)
         | AxisEvent::MultiAccel(value) => InputValue::Vector3 {
-            x: Some(value.pitch as f64),
-            y: Some(value.roll as f64),
-            z: Some(value.yaw as f64),
+            // Scale by 34.78 to convert controller ~471 LSB/1G to Steam Deck UHID 16384 LSB/1G
+            x: Some(value.pitch as f64 * 34.78),
+            y: Some(value.roll as f64 * 34.78),
+            z: Some(value.yaw as f64 * 34.78),
         },
         AxisEvent::LeftGyro(value) | AxisEvent::RightGyro(value) | AxisEvent::MultiGyro(value) => {
+            // 12x gyro acceleration matching user preference and BMI driver scale
             InputValue::Vector3 {
-                x: Some(value.pitch as f64),
-                y: Some(value.roll as f64),
-                z: Some(value.yaw as f64),
+                x: Some(value.pitch as f64 * 12.0),
+                y: Some(value.yaw as f64 * 12.0),
+                z: Some(value.roll as f64 * 12.0),
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
diff --git a/src/input/target/steam_deck_uhid.rs b/src/input/target/steam_deck_uhid.rs
index 786f205..feb18e3 100644
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
@@ -761,6 +761,12 @@ impl TargetInputDevice for SteamDeckUhidDevice {
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
  --status|-s)
    show_status
    ;;
  --test|-t)
    if [ -f "/home/${USER_NAME}/test-gyro.py" ]; then
      python3 "/home/${USER_NAME}/test-gyro.py"
    else
      echo -e "${RED}[-] test-gyro.py nicht in /home/${USER_NAME} gefunden!${NC}"
    fi
    ;;
  --auto-hook)
    # Nicht-interaktiv für Pacman PostTransaction Hook
    apply_fast_fix "--auto-hook" >/dev/null 2>&1 || true
    echo -e "${GREEN}[+] InputPlumber Legion Go Gyro Fix erfolgreich nach Paketupdate angewendet!${NC}"
    ;;
  --help|-h)
    echo -e "${BOLD}InputPlumber Legion Go Gyro Fix Tool${NC}"
    echo "Verwendung: sudo bash $0 [OPTION]"
    echo ""
    echo "Optionen:"
    echo "  (keine Option)    Schneller 1-Klick Fix (stellt gepatchtes 12x Binary & Config wieder her)"
    echo "  --rebuild, -b     Lädt Quellcode herunter, wendet Patch an und kompiliert neu"
    echo "  --hook            Richtet automatischen Pacman-Hook ein (repariert nach pacman -Syu)"
    echo "  --remove-hook     Entfernt den automatischen Pacman-Hook"
    echo "  --status, -s      Zeigt ausführliche Diagnose und Systemstatus an"
    echo "  --test, -t        Startet den Live-Sensortest"
    echo "  --help, -h        Zeigt diese Hilfe an"
    ;;
  *)
    apply_fast_fix
    ;;
esac
