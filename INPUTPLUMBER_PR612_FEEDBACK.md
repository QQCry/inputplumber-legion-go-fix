# InputPlumber PR #612 Validation & Upstream Feedback

Documentation and message templates for discussing [PR #612 (*feat: Normalize IMU data and refactor IMU paths*)](https://github.com/ShadowBlip/InputPlumber/pull/612) with InputPlumber developer **pastaq**.

---

## 1. Summary of Test Results on Lenovo Legion Go (Model `83E1` / PID `17ef:61eb`)

* **Tablet Sensor (`iio:device0` / `iio:device1` - AMD Sensor Fusion Hub):**
  * **Result:** **Working flawlessly!**
  * Direct filesystem buffer reads (replacing the flawed `industrial-io` crate) visibly reduce jitter and CPU usage.
  * `accel_3d` and `gyro_3d` report smoothly in `inputplumber device 0 test`.
* **Right Controller Sensor (Joy-Con HIDRAW):**
  * **Result:** **Dead / No data (`Left` and `Right` channels report `0`).**
  * The hardware IMU in the controller is never powered on or instructed to stream.
* **TUI Device Tester (`inputplumber device 0 test`):**
  * Displays all 6 axis groups properly (`Accelerometer: Left/Center/Right` and `Gyroscope: Left/Center/Right`).

---

## 2. Bug in Upstream PR #612: Udev Typo

In `rootfs/usr/lib/udev/rules.d/99-inputplumber-device-setup.rules`:
```udev
ACTION=="add|change|bind", ATTRS{idVendor}=="17ef", ATTRS{idProduct}=="61e[bcde]", SUBSYSTEM=="hid", DRIVER=="hid-lenovo-go", ATTR{os_mode}="linux", ATTR{left_handle/imu_bypass_enable}="true", ATTR{right_handle/imu_bypass_enable}="true", ATTR{touchpad/vibration_enable}="false", GOTO="inputplumber_setup_end"
```

### Problem:
The sysfs attribute in the kernel driver (`hid-lenovo-go`) is named with a trailing **`d`**:
* `/sys/.../left_handle/imu_bypass_enabled`
* `/sys/.../right_handle/imu_bypass_enabled`

Because `imu_bypass_enable` (without `d`) does not exist, udev fails silently to set the attribute.

---

## 3. Controller MCU Sleep & Keep-Alive Requirements

Why setting `imu_bypass_enabled` in the kernel driver alone is not sufficient:
1. **Unpadded 7-Byte Activation:** The Lenovo controller MCU firmware requires explicit, unpadded 7-byte vendor packets (`0x6a 0x02` and `0x6a 0x07`) sent to Interface 2 (`GP_IID = 0x02`). Padded 64-byte packets are discarded by the MCU.
2. **Sleep / Idle Behavior:** The controller **does not** retain its IMU streaming state permanently:
   * When detached or reattached, the connection resets.
   * After brief periods of inactivity/idle, the firmware puts the sensor to sleep.
   * A periodic heartbeat (every 3 seconds) or silence-detection re-arm is required for reliable gameplay.

---

## 4. English Message Templates for Discord / GitHub

### Message 1: Bug Report (Udev Typo)
```markdown
Hey @pastaq, while testing PR #612 I noticed a small typo in the udev rules that prevents the controller IMU bypass from being set:

In `rootfs/usr/lib/udev/rules.d/99-inputplumber-device-setup.rules`:
ATTR{left_handle/imu_bypass_enable}="true", ATTR{right_handle/imu_bypass_enable}="true"

The sysfs attribute exposed by the `hid-lenovo-go` kernel driver actually ends with a "d":
/sys/.../left_handle/imu_bypass_enabled
/sys/.../right_handle/imu_bypass_enabled

Because of the missing "d" (enable instead of enabled), udev fails to find the sysfs attribute and cannot set it to true.

It should be:
ATTR{left_handle/imu_bypass_enabled}="true", ATTR{right_handle/imu_bypass_enabled}="true"

(Note: The driver also exposes imu_enabled if you ever need that as well).
```

### Message 2: Test Results & Controller Activation
```markdown
Hey @pastaq, I tested PR #612 with `inputplumber device 0 test`. Here are the test results:

1. Tablet Sensor (Center): Works great!
The IIO refactor with the direct filesystem buffer is reading properly. accel_3d and gyro_3d are reporting smoothly and jitter is visibly reduced compared to the old industrial-io crate implementation.

2. Controller Sensors (Left / Right): Dead / No data incoming.
Only the tablet sensor (Center) emits data. The controllers (Left / Right) remain at 0.

Why the controller gyros don't work yet:
The Legion Go Joy-Con MCU does not stream IMU data by default even with imu_bypass_enabled set on hid-lenovo-go. The controller firmware strictly requires explicit, unpadded 7-byte vendor commands sent to the gamepad interface (GP_IID = 0x02) to wake up the sensor and start 16-bit HQ streaming:
- 05 06 6a 02 04 01 01 (Enable IMU sensor)
- 05 06 6a 07 04 02 01 (Enable 16-bit stream)

(Note: The firmware completely ignores these 0x6a commands if they are padded to 64 bytes — they must be exactly 7 bytes).
```

### Message 3: Controller Idle / Sleep Behavior Reply
```markdown
Regarding the controller remembering its state: I've already tested that extensively. 

Unfortunately, in practice the controller terminates the stream and goes back to sleep whenever it gets disconnected/detached, or after sitting idle for a short period without input. 

That's why having a periodic keep-alive heartbeat (or a silence-detection re-arm) is necessary in real-world use — otherwise the gyro stream unexpectedly dies and doesn't recover on its own.
```

---

## 5. Local Scripts Reference

* `sudo bash ~/switch-to-pr612.sh` — Installs PR #612 binary and profile for testing.
* `sudo bash ~/switch-to-my-mod.sh` — Instantly restores the customized working mod (with ~350 Hz controller IMU, heartbeat, and FSR ±2000 dps fix).
