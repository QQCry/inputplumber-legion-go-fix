# InputPlumber Native Gyroscope & Controller Fix for Lenovo Legion Go (83E1)

Complete solution, native HID driver patch, configuration profiles, and auto-repair scripts to enable fully functional, smooth 200 Hz gyroscope and motion aiming on the **Lenovo Legion Go** using **InputPlumber**, with persistent **DualSense (DS5)** and **Steam Deck (`deck-uhid`)** support.

Includes a native reverse-engineered HID driver port to read the **detachable Right Controller IMU** directly via `hidraw`, bypassing tablet-only limitations.

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

| File | Description |
| :--- | :--- |
| `enable-right-gyro-hhd.sh` | Main installer script: installs the patched native-IMU binary and restarts the service |
| `set-gyro-source.sh` | Helper script to switch active gyro source between tablet and controller on-the-fly |
| `inputplumber-legiongo.patch` | Clean, standalone Git patch against upstream InputPlumber (`ShadowBlip/InputPlumber`) |
| `50-legion_go.yaml` | Corrected InputPlumber device configuration profile (`deck-uhid` default) |
| `99-inputplumber-device-setup.rules` | Udev rules to ensure permissions for `hidraw` controller nodes |
| `test-gyro.py` | Real-time terminal diagnostic tool verifying Pitch, Yaw, Roll, and 1G Accel |

---

## 🚀 Quick Start

### 1. Apply Fix / Install Patched Binary
```bash
sudo bash enable-right-gyro-hhd.sh
