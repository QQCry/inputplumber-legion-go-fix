#!/usr/bin/env bash
# =diff --git a/Cargo.toml b/Cargo.toml
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
diff --git a/src/drivers/lego/go2_driver.rs b/src/drivers/lego/go2_driver.rs
index 7fa1b91..091288e 100644
--- a/src/drivers/lego/go2_driver.rs
+++ b/src/drivers/lego/go2_driver.rs
@@ -4,6 +4,7 @@ use std::{error::Error, ffi::CString};
 use hidapi::HidDevice;
 use packed_struct::PackedStruct;
 
+use crate::dmi::get_dmi_data;
 use crate::drivers::lego::HID_LENOVO_GO_FILTER;
 use crate::input::capability::{Capability, Source};
 use crate::udev::device::UdevDevice;
@@ -27,9 +28,37 @@ pub struct Driver {
     filtered_events: HashSet<Capability>,
     /// State for the internal gamepad controller
     state: Option<XInputDataReport>,
+    /// Last emitted accelerometer reading (for noise threshold gating)
+    last_emitted_accel: Option<(i16, i16, i16)>,
+    /// Last emitted gyroscope reading (for resting deadzone gating)
+    last_emitted_gyro: (i16, i16, i16),
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
+        std::thread::sleep(std::time::Duration::from_millis(30));
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
+        std::thread::sleep(std::time::Duration::from_millis(30));
+    }
+
     pub fn new(udev_device: UdevDevice) -> Result<Self, Box<dyn Error + Send + Sync>> {
         let fmtpath = udev_device.devnode().clone();
         let path = CString::new(fmtpath.clone())?;
@@ -44,11 +73,48 @@ impl Driver {
             return Err(format!("Device '{fmtpath}' is not a Legion Go S Controller").into());
         }
 
+        // Ensure os_mode is windows, imu_bypass is disabled, and imu is enabled in sysfs
+        if let Ok(dev) = udev_device.get_device() {
+            if let Some(parent) = dev.parent() {
+                let os_mode = parent.syspath().join("os_mode");
+                if os_mode.exists() {
+                    let _ = std::fs::write(&os_mode, "windows\n");
+                }
+                let imu_bypass = parent.syspath().join("right_handle/imu_bypass_enabled");
+                if imu_bypass.exists() {
+                    let _ = std::fs::write(&imu_bypass, "false\n");
+                }
+                let left_imu_bypass = parent.syspath().join("left_handle/imu_bypass_enabled");
+                if left_imu_bypass.exists() {
+                    let _ = std::fs::write(&left_imu_bypass, "false\n");
+                }
+                let imu_en = parent.syspath().join("right_handle/imu_enabled");
+                if imu_en.exists() {
+                    let _ = std::fs::write(&imu_en, "true\n");
+                }
+                let left_imu_en = parent.syspath().join("left_handle/imu_enabled");
+                if left_imu_en.exists() {
+                    let _ = std::fs::write(&left_imu_en, "true\n");
+                }
+            }
+        }
+
+        // Send MCU activation commands (both Lenovo driver format & HHD formats)
+        Self::send_lenovo_cmd(&hid_device, 0x04, 0x03, 0x04, 0x01); // Right IMU Enable
+        Self::send_lenovo_cmd(&hid_device, 0x04, 0x05, 0x03, 0x01); // Left IMU Enable
+        Self::send_hhd_cmd(&hid_device, 0x02, 0x04, 0x01); // Right IMU Enable
+        Self::send_hhd_cmd(&hid_device, 0x07, 0x04, 0x02); // Right 16-bit HQ Report
+        Self::send_hhd_cmd(&hid_device, 0x02, 0x03, 0x01); // Left IMU Enable
+        Self::send_hhd_cmd(&hid_device, 0x07, 0x03, 0x02); // Left 16-bit HQ Report
+        log::info!("Legion Go: sent Lenovo and HHD IMU activation packets (Left & Right)");
+
         Ok(Self {
             udev_device,
             hid_device,
             filtered_events: Default::default(),
             state: None,
+            last_emitted_accel: None,
+            last_emitted_gyro: (0, 0, 0),
         })
     }
 
@@ -63,30 +129,17 @@ impl Driver {
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
         let mut buf = [0; XINPUT_PACKET_SIZE];
         let bytes_read = self
             .hid_device
@@ -137,7 +190,6 @@ impl Driver {
         buf: [u8; XINPUT_PACKET_SIZE],
     ) -> Result<Vec<Event>, Box<dyn Error + Send + Sync>> {
         let input_report = XInputDataReport::unpack(&buf)?;
-
         // Print input report for debugging
         //log::debug!("--- Input report ---");
         //log::debug!("{input_report}");
@@ -422,18 +474,23 @@ impl Driver {
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
+            // Accel: emit on initial packet or when change exceeds noise threshold (25 LSB ~ 0.05G)
+            const ACCEL_NOISE_THRESHOLD: i16 = 25;
+            let emit_accel = match self.last_emitted_accel {
+                None => true,
+                Some((lx, ly, lz)) => {
+                    (state.right_accel_x - lx).abs() > ACCEL_NOISE_THRESHOLD
+                        || (state.right_accel_y - ly).abs() > ACCEL_NOISE_THRESHOLD
+                        || (state.right_accel_z - lz).abs() > ACCEL_NOISE_THRESHOLD
+                }
+            };
+            if emit_accel {
+                self.last_emitted_accel = Some((state.right_accel_x, state.right_accel_y, state.right_accel_z));
                 events.push(Event::Axis(AxisEvent::RightAccel(ImuAxisInput {
                     pitch: -state.right_accel_x,
-                    roll: -state.right_accel_y,
+                    roll: state.right_accel_y,
                     yaw: state.right_accel_z,
-                })))
+                })));
             }
             if !self
                 .filtered_events
@@ -464,18 +521,23 @@ impl Driver {
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
diff --git a/src/input/target/dualsense.rs b/src/input/target/dualsense.rs
index dbbc87e..cdd22d7 100644
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
@@ -71,19 +71,14 @@ pub struct DualSenseHardware {
 
 impl DualSenseHardware {
     pub fn new(model: ModelType, bus_type: BusType) -> Self {
-        // "e8:47:3a:d6:e7:74"
-        //let mac_addr = [0x74, 0xe7, 0xd6, 0x3a, 0x47, 0xe8];
-        let mut rng = rand::rng();
-        let mac_addr: [u8; 6] = [
-            rng.random(),
-            rng.random(),
-            rng.random(),
-            rng.random(),
-            rng.random(),
-            rng.random(),
-        ];
+        // Fixed persistent MAC address so Steam and games retain controller ID,
+        // layout configurations, and gyro calibrations across restarts.
+        let mac_addr: [u8; 6] = match model {
+            ModelType::Edge => [0x74, 0xe7, 0xd6, 0x3a, 0x47, 0xee],
+            ModelType::Normal => [0x74, 0xe7, 0xd6, 0x3a, 0x47, 0xe8],
+        };
         log::debug!(
-            "Creating new DualSense Edge device using MAC Address: {:?}",
+            "Creating new DualSense device using persistent MAC Address: {:?}",
             mac_addr
         );
 
@@ -97,15 +92,7 @@ impl DualSenseHardware {
 
 impl Default for DualSenseHardware {
     fn default() -> Self {
-        let mut rng = rand::rng();
-        let mac_addr: [u8; 6] = [
-            rng.random(),
-            rng.random(),
-            rng.random(),
-            rng.random(),
-            rng.random(),
-            rng.random(),
-        ];
+        let mac_addr: [u8; 6] = [0x74, 0xe7, 0xd6, 0x3a, 0x47, 0xe8];
         Self {
             model: ModelType::Normal,
             bus_type: BusType::Usb,
@@ -636,29 +623,41 @@ impl DualSenseDevice {
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
@@ -1006,6 +1005,12 @@ impl TargetInputDevice for DualSenseDevice {
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
@@ -1201,9 +1206,33 @@ fn denormalize_accel_value(value_meters_sec: f64) -> i16 {
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
+            s.trim().parse::<f64>().unwrap_or(2.5)
+        } else {
+            2.5
+        };
+        MULTIPLIER_BITS.store(mult.to_bits(), std::sync::atomic::Ordering::Relaxed);
+    }
+
+    let bits = MULTIPLIER_BITS.load(std::sync::atomic::Ordering::Relaxed);
+    if bits == 0 {
+        2.5
+    } else {
+        f64::from_bits(bits)
+    }
+}
+
 /// DualSense gyro values are measured in units of degrees per second.
-/// InputPlumber gyro values are also measured in degrees per second.
+/// Applies dynamic gyro multiplier (default 2.5x) and clamps safely to i16 bounds.
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
