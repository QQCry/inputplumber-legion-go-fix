# InputPlumber Gyroscope & Accelerometer Documentation for Lenovo Legion Go

This document details the implementation, firmware architecture, protocol quirks, and configuration of the gyroscope and accelerometer in InputPlumber for the Lenovo Legion Go (Model 1 `83E1` & Model 2).

InputPlumber supports **two independent motion sources** on the Legion Go:
1. **Native Right Controller Sensor:** Directly accessed via the HIDRAW interface of the controller MCU (reverse-engineered from Handheld Daemon / HHD) – works both **wirelessly detached** and **firmly attached** in handheld mode!
2. **Internal Tablet / Display Sensor:** Accessed via the AMD Sensor Fusion Hub (`iio:device0` / `iio:device1`).

---

## 1. Native Right Controller Sensor (HIDRAW Driver)

In the original upstream InputPlumber codebase, IMU data from the Legion Go Joy-Cons was ignored or blacklisted by default (Upstream Issue #678 / PR #677). The low-level logic from the *Handheld Daemon (HHD)* was ported to Rust and integrated directly into InputPlumber's `lego` driver subsystem ([`go1_driver.rs`](file:///home/qqcry/Projekte/InputPlumber/src/drivers/lego/go1_driver.rs), [`go2_driver.rs`](file:///home/qqcry/Projekte/InputPlumber/src/drivers/lego/go2_driver.rs), and [`hidraw/legion_go2.rs`](file:///home/qqcry/Projekte/InputPlumber/src/input/source/hidraw/legion_go2.rs)).

### Architecture & Protocol Details:

* **Device Identification & Interfaces:**
  * **VID:** `0x17ef` (Lenovo)
  * **PIDs:**
    * Legion Go 1: `0x6182` (XInput), `0x6183` (DInput Attached), `0x6184` (DInput Detached), `0x6185` (FPS).
    * Legion Go 2: `0x61eb` (XInput), `0x61ec` (DInput Attached), `0x61ed` (DInput Detached), `0x61ee` (FPS).
  * **USB Interfaces (Node Mapping):**
    * **Interface 1 (`TP_IID = 0x01` / typically `/dev/hidraw0`):** Touchpad & Keyboard. Exclusively managed by `go_touchpad_driver`.
    * **Interface 2 (`GP_IID = 0x02` / typically `/dev/hidraw1`):** Gamepad inputs, MCU commands, and 16-bit motion reports. The driver strictly verifies `info.interface_number() == GP_IID`.

* **MCU Wake-up, Heartbeat & Packet Lengths (Critical!):**
  The Lenovo MCU requires two distinct packet formats:
  1. **Lenovo Feature Reports (Padded to 64 Bytes):**
     * Disable Touchpad Bypass: `05 00 04 03 04 00` (Right) and `05 00 04 03 03 00` (Left) $\rightarrow$ Prevents mouse lag and cursor stutter.
     * Enable IMU Power: `05 00 04 05 04 01` (Right) and `05 00 04 05 03 01` (Left).
  2. **HHD Streaming & Wakeup Commands (EXACTLY 7 BYTES, UNPADDED!):**
     * **Important:** The Lenovo firmware completely discards `0x6a` commands if they are padded to 64 bytes! They must be sent with exact length (7 bytes):
     * Enable IMU Sensor: `05 06 6a 02 04 01 01` (Right) and `05 06 6a 02 03 01 01` (Left).
     * Enable 16-Bit Stream: `05 06 6a 07 04 02 01` (Right) and `05 06 6a 07 03 02 01` (Left).
     * Disable Legion Swap: `05 06 69 04 01 01 01`.

* **Periodic Heartbeat & Stream-Silence Re-Arm:**
  * Because controller firmware terminates 16-bit streaming when the controller is idle or commands were sent only once, the driver implements an automated keep-alive:
    * **Regular Timer (every 3 seconds):** Sends non-blocking keep-alive packets.
    * **Silence Detection (after 1.5 seconds without incoming data):** Automatically re-sends the 7-byte re-arm packets to wake up the sensor.
    * **Completely Non-Blocking:** No `thread::sleep()` calls in the polling thread.

* **Robust Polling Loop & Fault Resilience:**
  * Transient USB timeouts, buffer clipping, or unpack glitches no longer terminate the driver thread (`SourceDriver`).
  * Only genuine hardware disconnects (`device disconnected` / `No such device`) bubble up, allowing udev to cleanly rebind upon reconnection.
  * Every incoming IMU packet is confirmed in debug logs:
    ```text
    Received IMU report: len=64
    ```

* **HID Report Parsing & Sensor Orientation:**
  * Report ID: `0x04`, Command ID: `0x74` at Byte 2.
  * Data Length: Minimum 60 bytes.
  * **Big-Endian (`i16` MSB):** Because the right Joy-Con PCB is mounted rotated by 90 degrees inside the shell, data fields starting at Byte 47 are mapped as follows:
    * Byte 47: Timestamp (`u8`)
    * Bytes 48–49: `accel_z` (+0.00212 m/s²)
    * Bytes 50–51: `accel_x` (-0.00212 m/s²)
    * Bytes 52–53: `accel_y` (-0.00212 m/s²)
    * Bytes 54–55: `gyro_z` (+0.001065 rad/s)
    * Bytes 56–57: `gyro_x` (-0.001065 rad/s)
    * Bytes 58–59: `gyro_y` (-0.001065 rad/s)

* **Firmware Glitch Filter:**  
  The controller firmware has a known bug intermittently sending glitch packets of `abs(val) == 254` or `abs(val) == 255`. These aberrant packets are discarded by the driver.

* **Scaling & Calibration:**
  * **Acceleration (`Accel`):** The controller outputs ~4,625 LSB for 1G earth gravity. InputPlumber scales this by **`3.542`** to match the Steam Deck UHID standard (**16,384 LSB / 1G**). Steam Input detects orientation immediately without tilting.
  * **Gravity Vector Persistence:** If the sensor temporarily idles, the driver avoids sending `(0, 0, 0)` null vectors to the virtual Steam Deck UHID, maintaining the last known valid gravity vector. Steam never turns off the gyro.
  * **Gyroscope (`Gyro`):** Normalized with linear scaling for responsive, zero-delay aiming in games.

---

## 2. Internal Tablet Sensor (IIO Driver)

Alternatively, the internal sensor built into the tablet display housing can be used (`gyro_3d` + `accel_3d` via AMD Sensor Fusion Hub IIO).

### Configuration (`/etc/inputplumber/devices.d/50-legion_go.yaml`):
```yaml
  # IMU
  - group: imu
    iio:
      name: gyro_3d
      mount_matrix:
        x: [0, 1, 0]
        y: [1, 0, 0]
        z: [0, 0, 1]
  - group: imu
    iio:
      name: accel_3d
      mount_matrix:
        x: [0, 1, 0]
        y: [-1, 0, 0]
        z: [0, 0, 1]
```
> [!IMPORTANT]
> Without `accel_3d`, InputPlumber reports `(0, 0, 0)` for gravity. Steam Input interprets zero gravity as an invalid or disconnected sensor and shuts down gyro completely. With the mount matrix above, the internal tablet sensor operates smoothly at 200 Hz.

---

## 3. Runtime Sensor Switching (Live Switch)

In InputPlumber's virtual Steam Deck emulation layer (`steam_deck_uhid.rs`), an atomic switching mechanism monitors `/etc/inputplumber/gyro_source`:

* **Query current sensor status:**
  ```bash
  ~/set-gyro-source.sh status
  ```
* **Switch to right controller sensor (Default for detached & attached play):**
  ```bash
  ~/set-gyro-source.sh controller
  ```
* **Switch to internal tablet sensor:**
  ```bash
  ~/set-gyro-source.sh tablet
  ```

> [!NOTE]
> Switching occurs **instantly at runtime** within milliseconds. Neither InputPlumber nor running games need to be restarted.

---

## 4. Helper Scripts & Diagnostics

* **`sudo bash ~/enable-right-gyro-hhd.sh`:**  
  Installs the patched binary to `/usr/bin/inputplumber`, configures udev rules, sends unpadded 7-byte MCU activation packets, and restarts the service.
* **`python3 ~/test-gyro.py`:**  
  Reads real-time packets from the virtual Steam Deck controller (`28de:12fe`) and visualizes gravity (`Accel`), angular rate (`Gyro`), and direction in the terminal:
  ```bash
  python3 ~/test-gyro.py
  ```
* **`~/set-controller-gyro-speed.sh <multiplier>`:**  
  Adjusts the hardware gyro speed multiplier live without restarting (default: `0.70`). Setting to `0.17` allows using standard Steam Sensitivity `2.5`. Persisted in `/etc/inputplumber/controller_gyro_speed`.
* **`~/set-gyro-source.sh`:**  
  Switches active motion source live between `controller` and `tablet`.
* **`~/set-ds5-gyro-speed.sh`:**  
  Adjusts gyro speed multiplier on-the-fly when emulating DualSense controllers.
* **`python3 ~/test-dualsense-gyro.py`:**  
  Diagnostic tool for DualSense IMU emulation.
* **`sudo bash ~/uninstall-gyro-fix.sh`:**  
  Complete uninstaller and factory reset script.
* **`journalctl -u inputplumber.service -f`:**  
  Live log stream including `Received IMU report: len=64` confirmations.

---

## 5. In-Game Configuration (Steam Input / Game Mode)

InputPlumber emulates a native Steam Deck Controller (`deck-uhid`) system-wide. Gamescope and Steam recognize it automatically.

### Configuring Gyro In-Game:
1. In-game, press the **Steam button** (Legion-L) $\rightarrow$ Controller Settings $\rightarrow$ **Edit Layout**.
2. Open the **Gyroscope** tab.
3. **Select Gyro Behavior:**
   * **"As Mouse"** *(Best option for shooters & precision aiming)*.
   * **"As Right Joystick"** *(For games requiring exclusive gamepad input)*.
4. **Gyro Enable Button:**
   * e.g., *"Always On"* or *"Left Trigger (LT / L2) Full Pull"* (when aiming down sights).
   * *Note:* The option *"Touch Right Stick"* is not supported by Legion Go hardware because the analog sticks lack capacitive touch caps.

### Verifying Calibration:
In Steam Settings under **Controller** $\rightarrow$ **Calibration & Advanced Settings** $\rightarrow$ **Gyroscope**, observe the artificial horizon and calibrate if necessary by laying the device flat for 5 seconds.

---

## 6. Binaries & File Paths

* **Installed System Binary:** `/usr/bin/inputplumber`
* **Local Staging Binary:** `/home/qqcry/.local/bin/inputplumber-right-controller-12x`
* **Source Code Repository:** `/home/qqcry/Projekte/InputPlumber`
* **Active Gyro Source Config:** `/etc/inputplumber/gyro_source` (`controller` or `tablet`)
* **Device Configuration:** `/etc/inputplumber/devices.d/50-legion_go.yaml`
* **Udev Rule:** `/etc/udev/rules.d/99-inputplumber-device-setup.rules`

---

## 7. Gyro Clipping / Saturation on Fast Flicks & FSR Adjustment

### Problem: Saturation & View Freezing
During high-velocity flicks, the controller's raw 16-bit readings can saturate at **`32767`** or **`-32768`** if the hardware Full-Scale Range (FSR) is set too low.

### Solution: Full-Scale Range (FSR) at ±2000 °/s
To eliminate clipping during rapid turns, FSR is set to **`±2000 dps`** (`°/s`), keeping calibration and streaming intact:

1. **Hardware Init (HID Feature Report):**
   * During initialization, a configuration byte sets the IMU config register to **±2000 dps**.

2. **Scaling Factor:**
   * Because `32768` LSB maps to `2000 °/s`, sensitivity is **16.384 LSB/dps** (`2000.0 / 32768.0`).
   * Scaling in Rust:
     ```rust
     const GYRO_FSR_DPS: f32 = 2000.0;
     const GYRO_SCALE_DPS: f32 = GYRO_FSR_DPS / 32768.0;
     const GYRO_SCALE_RAD: f32 = GYRO_SCALE_DPS * (std::f32::consts::PI / 180.0);
     ```

3. **Anti-Drift & In-Flight Zero-Rate Auto-Bias Calibration:**
   * Static zero-rate offsets are subtracted on the signed `i16` level before float conversion:
     ```rust
     let calibrated_raw = raw_val.saturating_sub(offset);
     let final_value = calibrated_raw as f32 * GYRO_SCALE_RAD;
     ```
   * **In-Flight Stationary Detection:** When the controller is kept stationary for $\ge 0.6$ seconds ($< 6$ LSB delta across 200 samples at ~350 Hz), the driver automatically re-calibrates zero-rate DC biases in the background. This completely prevents crosshair drift and ensures 100% directional symmetry without requiring manual calibration.

4. **Continuous Soft Deadzone (18.0 LSB):**
   * Eliminates the hard jump cliff (previously values $< 24$ dropped to 0, while $\ge 24$ jumped instantly to 24+).
   * Crosshair movements start continuously and smoothly from 1 LSB:
     ```rust
     const SOFT_DEADZONE: f32 = 18.0;
     let sign = val.signum();
     let abs = val.abs();
     if abs <= SOFT_DEADZONE {
         0.0
     } else {
         sign * (abs - SOFT_DEADZONE)
     }
     ```

5. **Adaptive EMA Low-Pass Filter (Anti-Jitter):**
   * Raw MEMS noise and micro hand tremors are smoothed with an adaptive smoothing factor:
     - $\alpha = 0.35$ for micro-aiming: Eliminates sensor jitter and pixel hopping during fine adjustments.
     - Dynamically ramps up to $\alpha = 0.95$ during fast flicks: Zero input latency for rapid turns.

---

## 8. Polling Rates & Latencies

| Motion Source / Interface | Polling Rate (Hz) | Packet Interval | Technical Notes |
| :--- | :--- | :--- | :--- |
| **Native Right Controller (Default)** | **~315 – 375 Hz** | **~2.7 – 3.2 ms** | Hardware USB endpoint (`EP 2 IN`) runs with `bInterval = 2` (2 ms grid). The 16-bit stream (`0x6a`) delivers unthrottled packets directly to InputPlumber. |
| **Virtual Steam Deck Controller (`deck-uhid`)** | **~315 – 375 Hz** | **~2.7 – 3.2 ms** | Fully event-driven; InputPlumber immediately forwards every incoming IMU report to Steam and Gamescope without delay. |
| **Internal Tablet Sensor (AMD SFH IIO)** | **200 Hz** | **5.0 ms** | Fixed hardware/driver sampling rate of AMD Sensor Fusion Hub in the Linux kernel (`gyro_3d` / `accel_3d`). |
| *Lenovo Stock Standard (without IMU)* | *40 – 100 Hz* | *10 – 25 ms* | Default Lenovo XInput report prior to the fix ran at only 40–100 Hz. |

---

## 9. Complete Uninstall Protocol & Factory Reset

If you ever wish to revert your system to the 100% unmodified, official upstream stock state of InputPlumber, the uninstaller script provides an automated factory reset:

```bash
sudo bash ~/uninstall-gyro-fix.sh
```
*(Alternatively: `sudo bash ~/fix-inputplumber.sh --uninstall`)*

### Step-by-Step Uninstall Actions:

1. **Stop Active Service:**  
   Terminates `inputplumber.service` to prevent race conditions while binaries and configuration files are being replaced.
2. **Remove Automated Pacman Hooks:**  
   Deletes `/etc/pacman.d/hooks/99-inputplumber-fix.hook` and `/usr/local/bin/fix-inputplumber` so future package manager updates (`pacman -Syu`) stay on vanilla stock without reapplying patches.
3. **Restore Official Upstream Binary:**  
   Extracts and installs the clean, unmodified binary from the local Pacman cache (`/var/cache/pacman/pkg/inputplumber-*.pkg.tar.zst`) or stock backup (`/usr/bin/inputplumber.stock-backup`). Cleans up all backup binaries in `/usr/bin`.
4. **Remove Configuration Overrides:**  
   Removes `/etc/inputplumber/gyro_source`, `/etc/inputplumber/ds5_gyro_multiplier`, and `/etc/inputplumber/devices.d/50-legion_go.yaml*`. InputPlumber reverts to reading vanilla configuration from `/usr/share/inputplumber/`.
5. **Reset Udev Rules & System Policies:**  
   Removes `/etc/udev/rules.d/99-inputplumber-device-setup.rules` and reloads system udev rules.
6. **Reset Controller MCU & sysfs Hardware State:**  
   - Sends explicit HID commands to stop 16-bit motion streaming and disable MCU IMU power.
   - Restores optical touchpad bypass (`bypass=0x01`).
   - Sets sysfs hardware attributes back to Linux stock (`os_mode=linux`, `imu_bypass_enabled=true`).
7. **Clean Systemd Overrides:**  
   Removes drop-ins in `/etc/systemd/system/inputplumber.service.d/` and reloads the systemd daemon.
8. **Package Integrity Verification:**  
   Starts the clean service and executes `pacman -Qkk inputplumber` to verify that all system files match the official package with 100% integrity.
