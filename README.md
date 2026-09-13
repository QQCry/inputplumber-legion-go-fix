# InputPlumber Gyroscope & DualSense Fix for Lenovo Legion Go (83E1)

Complete solution, source patch, configuration profiles, and auto-repair scripts to enable fully functional, smooth 200 Hz gyroscope and motion aiming on the **Lenovo Legion Go** using **InputPlumber**, with persistent **DualSense (DS5)** and **Steam Deck (`deck-uhid`)** support.

Works seamlessly in both **Desktop Mode** and **Gamescope (Steam Game Mode)** on Arch Linux, CachyOS, Bazzite, ChimeraOS, and other Linux distributions.

---

## 🎯 What This Fix Solves

1. **Dead/Disabled Gyro in Steam Input:**
   * **Cause:** Stock InputPlumber configuration only defined `gyro_3d` in `50-legion_go.yaml`, omitting `accel_3d`. Steam Deck emulation (`deck-uhid`) reported `(0, 0, 0)` for gravity. Steam requires a 1G gravitational vector to calculate drift compensation and orientation; without it, Steam completely disables the IMU.
   * **Fix:** Added `accel_3d` with the proper orientation matrix.
2. **Internal IMU Filter Bug in InputPlumber Driver:**
   * **Cause:** Upstream `src/drivers/iio_imu/driver.rs` actively disabled the internal AMD SFH tablet IMU whenever the `hid_lenovo_go` kernel driver was detected in `/proc/modules`.
   * **Fix:** Removed this artificial event filter to keep the internal 200 Hz AMD Sensor Fusion Hub IMU active.
3. **DualSense MAC Persistence (Lost Gyro Profiles on Reboot / Reconnection):**
   * **Cause:** Upstream `src/input/target/dualsense.rs` generated a random Bluetooth MAC address (`rand::rng()`) on every virtual device creation. Steam treated every reconnection as a brand new device, resetting Gyro to "Disabled" and dropping user layouts and calibration.
   * **Fix:** Hardcoded persistent MAC addresses (`e8:47:3a:d6:e7:74` for Normal, `e8:47:3a:d6:e7:ee` for Edge). Steam permanently remembers calibrations and layouts.
4. **Dynamic Gyro Source Switching (Tablet vs. Docked Right Controller):**
   * **Feature:** Allows seamlessly switching between the internal Tablet IMU (`Source::Center`) and the Right Joy-Con Controller IMU (`Source::Right`, tuned for docked mode) live without restarting games or InputPlumber.
   * **Fix:** Added polling of `/etc/inputplumber/gyro_source` in `src/input/target/mod.rs` and filtered inputs in both `steam_deck_uhid` and `dualsense`.
5. **AMD Sensor Fusion Hub (SFH) Scale Correction:**
   * **Cause:** Linux AMD SFH driver scaling attributes produced only ~1,527 LSB at 1G instead of the ~16,384 LSB expected by Steam Deck UHID (factor of 10.73x off).
   * **Fix:** Calibrated `ACCEL_SCALE_FACTOR` by 10.73x to match the exact 1G = 16384 UHID standard.
6. **Ergonomic Handheld Gyro Sensitivity & 200 Hz Sampling:**
   * **Cause:** The Legion Go's 8.8" display makes large hand tilts awkward. Stock gyro scaling felt very sluggish.
   * **Fix:** Increased angular velocity scaling to 12.0x and boosted the IIO driver polling rate to 5ms (200 Hz), matching Handheld Daemon (HHD) performance.
7. **Touchpad / Mouse Lag Prevention:**
   * **Cause:** Enabling MCU IMU bypass (`0x03`) turns off internal hardware filtering on the optical trackpad in the controller firmware, causing cursor jumping and stutter.
   * **Fix:** Udev rules and driver logic ensure bypass remains disabled (`0x00`), keeping the touchpad smooth.
8. **Steam Gyro Drift Zero-Out:**
   * Prevents corrupted Steam auto-calibration drift values from pulling the camera down.

---

## 📁 Repository Contents

| File | Description |
| :--- | :--- |
| `fix-inputplumber.sh` | All-in-one script: restores patched binary, updates configs, sets udev rules, and can rebuild from source |
| `install-dualsense-12x.sh` | Fast installer script for the patched DualSense 12x binary |
| `set-gyro-source.sh` | Helper script to switch active gyro source between tablet and controller on-the-fly |
| `inputplumber-legiongo.patch` | Clean, standalone Git patch against upstream InputPlumber (`ShadowBlip/InputPlumber`) |
| `50-legion_go.yaml` | Corrected InputPlumber device configuration profile (`deck-uhid` default) |
| `99-inputplumber-device-setup.rules` | Udev rules to prevent mouse lag and configure controller mode |
| `test-gyro.py` | Real-time terminal diagnostic tool for Steam Deck UHID IMU data |
| `test-dualsense-gyro.py` | Real-time terminal diagnostic tool for DualSense IMU data |

---

## 🚀 Quick Start

### 1. Apply Fix / Install Patched Binary
```bash
sudo bash fix-inputplumber.sh
# or
sudo bash install-dualsense-12x.sh
```
This installs the optimized binary, verifies configuration, sets udev rules, cleans Steam drift, and restarts `inputplumber.service`.

### 2. Switch Gyro Source On-the-Fly
Switch motion sensors anytime without restarting InputPlumber or games:
```bash
# Switch to right controller sensor (docked mode)
~/set-gyro-source.sh controller

# Switch back to internal tablet sensor (handheld mode)
~/set-gyro-source.sh tablet

# Check active sensor status
~/set-gyro-source.sh status
```

### 3. Auto-Repair on Package Updates (Pacman Hook)
On Arch Linux / CachyOS, package updates (`pacman -Syu`) overwrite `/usr/bin/inputplumber`. To automatically re-apply the fix on every system update:
```bash
sudo bash fix-inputplumber.sh --hook
```

### 4. Build & Patch Fresh from Upstream Source
```bash
sudo bash fix-inputplumber.sh --rebuild
```
Clones upstream InputPlumber, applies `inputplumber-legiongo.patch`, compiles release binary with Cargo, and installs it.

### 5. Live Sensor Test
Verify motion controls in real-time:
```bash
# For Steam Deck (deck-uhid)
python3 test-gyro.py

# For DualSense (ds5)
python3 test-dualsense-gyro.py
```

---

## 🎮 In-Game Gyro Setup (Steam Input)

1. Open Steam (Desktop or Gamescope Game Mode).
2. Go to **Controller Settings** $\rightarrow$ **Edit Layout** $\rightarrow$ **Gyro**.
3. Set Gyro Behavior to **As Mouse** (recommended for FPS) or **As Right Joystick**.
4. Set Gyro Enable Button to **Always On** or **Left Trigger Full Pull** (Aim Down Sights).
5. In **Steam Settings $\rightarrow$ Controller $\rightarrow$ Calibration $\rightarrow$ Gyroscope**, verify that the artificial horizon is level and responsive.

---

## 📜 License
MIT License
