# InputPlumber Native Gyroscope & Controller Fix for Lenovo Legion Go (83E1)

Complete solution, native HID driver patch, configuration profiles, and auto-repair scripts to enable fully functional, smooth 200 Hz gyroscope and motion aiming on the **Lenovo Legion Go** using **InputPlumber**, with persistent **DualSense (DS5)** and **Steam Deck (`deck-uhid`)** support.

Includes a native reverse-engineered HID driver port (from HHD) to read the **detachable Right Controller IMU** directly via `hidraw`, bypassing tablet-only limitations.

Works seamlessly in both **Desktop Mode** and **Gamescope (Steam Game Mode)** on Arch Linux, CachyOS, Bazzite, ChimeraOS, and other Linux distributions.

---

## 🎯 What This Fix Solves

1. **Native Right-Controller IMU Driver (Ported from HHD):**
   * **Cause:** Upstream InputPlumber only supported the internal tablet IMU via Linux IIO/AMD SFH. The detachable right Joy-Con sensor remained dark due to Lenovo's proprietary HID protocol.
   * **Fix:** Implemented native HID handling in `go1_driver.rs` and `go2_driver.rs`. It communicates via `hidraw` on Interface 2, sending raw 7-byte initialization handshakes (`0x6A 0x02` / `0x07`) to unlock high-rate 16-bit motion streaming from the controller MCU.
2. **Dead/Disabled Gyro in Steam Input (Missing Gravitational Vector):**
   * **Cause:** Stock InputPlumber configuration omitted `accel_3d`. Steam Deck emulation (`deck-uhid`) reported `(0, 0, 0)` for gravity. Steam requires a 1G gravitational vector to calculate drift compensation and orientation; without it, Steam completely ignores the IMU.
   * **Fix:** Added `accel_3d` with proper orientation mapping and cyclical 120 ms keep-alive gravity broadcasts.
3. **Hotplug & Detach Resilience (MCU Reset Recovery):**
   * **Cause:** Docking or undocking the controller triggers an MCU power reset (`0x61eb` <-> `0x61ed`), dropping motion streaming and breaking `hidraw` polling loops.
   * **Fix:** Reconnect handling detects controller state changes, re-executes the unpadded 7-byte wake-up handshake, and cleanly rebinds the polling thread without crashing the daemon.
4. **Firmware Glitch Filter & Linear Calibration:**
   * **Cause:** Lenovo's firmware intermittently transmits spurious `0x00FE` / `0x00FF` gyro packets, causing micro-stutters and sudden view snaps. Furthermore, excessive artificial multipliers caused immediate 16-bit clipping in Steam.
   * **Fix:** Implemented an exact byte glitch filter (dropping invalid packets) and normalized scaling to a clean 1:1 ratio matching the HHD reference, allowing native Steam Input sliders to function properly.
5. **DualSense MAC Persistence (Lost Gyro Profiles on Reboot):**
   * **Cause:** Upstream `src/input/target/dualsense.rs` generated a random Bluetooth MAC address on every virtual device creation. Steam treated every reconnection as a brand new controller, resetting Gyro to "Disabled" and wiping layouts.
   * **Fix:** Hardcoded persistent MAC addresses (`e8:47:3a:d6:e7:74` for Normal, `e8:47:3a:d6:e7:ee` for Edge). Steam permanently remembers calibrations and per-game mappings.
6. **Dynamic Gyro Source Switching (Tablet vs. Detached Right Controller):**
   * **Feature:** Allows seamlessly switching between the internal Tablet IMU (`Source::Center`) and the Right Joy-Con Controller IMU (`Source::Right`, for detached/docked play) on-the-fly without restarting games or InputPlumber.
   * **Fix:** Added live polling of `/etc/inputplumber/gyro_source`.
7. **Touchpad / Mouse Lag Prevention:**
   * **Cause:** Enabling MCU IMU bypass (`0x03`) turns off internal hardware filtering on the optical trackpad in the controller firmware, causing cursor jumping and stutter.
   * **Fix:** Driver logic enforces `bypass=0x00`, keeping the optical sensor smooth while IMU streaming remains fully active.

---

## 📁 Repository Contents

| `enable-right-gyro-hhd.sh` | Main installer script: installs the patched native-IMU binary, configures udev/yaml, and restarts the service |
| `uninstall-gyro-fix.sh` | Complete uninstaller: restores stock binary, cleans udev/yaml overrides, resets MCU to defaults |
| `set-gyro-source.sh` | Helper script to switch active gyro source between tablet and controller on-the-fly |
| `set-ds5-gyro-speed.sh` | Dynamic real-time speed multiplier adjuster for DualSense gyro emulation |
| `fix-inputplumber.sh` | Comprehensive build & maintenance tool (source rebuild, pacman hook, uninstaller, health check) |
| `inputplumber-legiongo.patch` | Clean, standalone Git patch against upstream InputPlumber (`ShadowBlip/InputPlumber`) |
| `50-legion_go.yaml` | Corrected InputPlumber device configuration profile (`deck-uhid` default) |
| `99-inputplumber-device-setup.rules` | Udev rules to ensure permissions for `hidraw` controller nodes and eliminate mouse lag |
| `test-gyro.py` | Real-time terminal diagnostic tool verifying Pitch, Yaw, Roll, and 1G Accel |
| `test-dualsense-gyro.py` | Real-time terminal diagnostic tool for DualSense IMU data |
| `INPUTPLUMBER_GYRO_FIX.md` | In-depth technical architecture and protocol documentation |

---

## 🚀 Quick Start

### 1. Apply Fix / Install Patched Binary
```bash
sudo bash ~/fix-inputplumber.sh
```
This script installs the patched InputPlumber binary with native Right Joy-Con IMU support, configures `50-legion_go.yaml`, configures udev rules, sends MCU activation packets, and restarts `inputplumber.service`.

### 2. Switch Gyro Source On-the-Fly
Switch motion sensors anytime without restarting InputPlumber or games:
```bash
# Switch to right controller sensor (detached / docked play)
~/set-gyro-source.sh controller

# Switch back to internal tablet sensor (handheld mode)
~/set-gyro-source.sh tablet

# Check active sensor status
~/set-gyro-source.sh status
```

### 3. Adjust DualSense Gyro Speed (Optional)
If using DualSense emulation, change sensitivity live without restarting:
```bash
# Set factor (e.g. 1.0 for 1:1 raw, 1.5, 2.0)
~/set-ds5-gyro-speed.sh 1.0
```

### 4. Live Sensor Testing
Verify motion controls in real-time from the terminal:
```bash
# For Steam Deck (deck-uhid)
python3 test-gyro.py

# For DualSense (ds5)
python3 test-dualsense-gyro.py
```

### 5. Build & Patch Fresh from Upstream Source
To compile directly from source using the included patch:

```bash
sudo bash fix-inputplumber.sh --rebuild
```

### 6. Auto-Repair on Package Updates (Pacman Hook)
To automatically re-apply the patched binary whenever `pacman -Syu` updates `inputplumber`:
```bash
sudo bash fix-inputplumber.sh --hook
```

### 7. Complete Uninstall & Factory Reset
To cleanly revert all changes, restore the official upstream pacman binary, remove all overrides, and reset MCU firmware:
```bash
sudo bash uninstall-gyro-fix.sh
# or: sudo bash fix-inputplumber.sh --uninstall
```

See the [Complete Uninstall Protocol](#-complete-uninstall-protocol--factory-reset) section below for technical details.

---

## 🧹 Complete Uninstall Protocol & Factory Reset

The uninstaller (`uninstall-gyro-fix.sh` / `fix-inputplumber.sh --uninstall`) performs a thorough, 8-step factory reset to ensure the system is completely restored to its original upstream state:

1. **Stop Active Daemon:**
   * Stops `inputplumber.service` to avoid file locks and race conditions while binaries and configuration files are manipulated.
2. **Remove Automated Package Hooks:**
   * Deletes `/etc/pacman.d/hooks/99-inputplumber-fix.hook` and `/usr/local/bin/fix-inputplumber`. This ensures future system upgrades (`pacman -Syu`) stay on standard upstream packages without reapplying patches.
3. **Restore Official Stock Binary:**
   * Reinstalls the official, unmodified InputPlumber binary directly from the local Pacman cache (`/var/cache/pacman/pkg/inputplumber-*.pkg.tar.zst`) or backed-up stock binary (`/usr/bin/inputplumber.stock-backup`).
   * Cleans up all backup binaries in `/usr/bin/`.
4. **Remove Configuration Overrides:**
   * Removes `/etc/inputplumber/gyro_source`, `/etc/inputplumber/ds5_gyro_multiplier`, and `/etc/inputplumber/devices.d/50-legion_go.yaml*`.
   * InputPlumber cleanly reverts to using the default, unmodified profiles in `/usr/share/inputplumber/`.
5. **Reset Udev Rules & System Policies:**
   * Removes `/etc/udev/rules.d/99-inputplumber-device-setup.rules` and reloads udev rules to restore standard Linux device permissions.
6. **Reset Controller MCU & sysfs Hardware State:**
   * Sends explicit HID commands to stop 16-bit HQ motion streaming and power down the controller IMU.
   * Restores touchpad bypass (`0x01`), returning the controller MCU to its stock Lenovo firmware state.
   * Reverts sysfs attributes back to Linux defaults (`os_mode=linux`, `imu_bypass_enabled=true`).
7. **Clean Systemd Overrides:**
   * Removes any service overrides in `/etc/systemd/system/inputplumber.service.d/` and executes `systemctl daemon-reload`.
8. **Package Integrity Verification:**
   * Starts the clean upstream service and runs `pacman -Qkk inputplumber` to verify that every installed file matches the official Arch/CachyOS package checksums with 100% integrity.

## 🎮 In-Game Gyro Setup (Steam Input)

1. Open Steam (Desktop Mode or Gamescope Game Mode).
2. Open your game, press **Steam button / Legion-L** $\rightarrow$ Controller Settings $\rightarrow$ **Edit Layout** $\rightarrow$ **Gyro**.
3. Set **Gyro Behavior** to:
   * **As Mouse** *(Recommended for FPS and precise aiming)*
   * **As Right Joystick** *(For games without simultaneous mouse + gamepad support)*
4. Set **Gyro Enable Button**:
   * E.g. **Always On** or **Left Trigger Full Pull** (ADS / Aim Down Sights).
   * *Note:* Capacitive stick touch is not supported by Legion Go hardware.
5. In **Steam Settings $\rightarrow$ Controller $\rightarrow$ Calibration $\rightarrow$ Gyroscope**, verify that the horizon is level and responsive.

---

## 📜 License
MIT License

