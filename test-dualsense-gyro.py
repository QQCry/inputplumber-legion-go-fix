#!/usr/bin/env python3
import glob
import os
import sys
import time

try:
    import evdev
except ImportError:
    print("[-] The Python module 'evdev' is not installed.")
    sys.exit(1)

def find_motion_sensor_device():
    for path in glob.glob("/dev/input/event*"):
        try:
            dev = evdev.InputDevice(path)
            if "DualSense" in dev.name and "Motion Sensors" in dev.name:
                return dev
        except Exception:
            continue
    return None

dev = find_motion_sensor_device()

if not dev:
    print("[-] No DualSense Motion Sensors event device found!")
    print("    Is inputplumber.service running with target ds5?")
    sys.exit(1)

print("=" * 70)
print(f"  DualSense 12x Gyroscope & Accelerometer Live Test")
print(f"  Device: {dev.name} ({dev.path})")
print("=" * 70)
print("[*] Gyro measures angular velocity (RX=Pitch, RY=Yaw, RZ=Roll).")
print("[*] Accel measures orientation & gravity (ABS_X, ABS_Y, ABS_Z).")
print("[*] Rotate or move the Legion Go now!\n")
print(f"{'Time':<8} | {'Accel (X, Y, Z)':<24} | {'Gyro (Pitch, Yaw, Roll)':<26} | Status")
print("-" * 75)

# Initial state
accel = [0, 0, 0]
gyro = [0, 0, 0]
last_print = 0
motion_count = 0

try:
    for event in dev.read_loop():
        if event.type == evdev.ecodes.EV_ABS:
            # Accelerometer
            if event.code == evdev.ecodes.ABS_X:
                accel[0] = event.value
            elif event.code == evdev.ecodes.ABS_Y:
                accel[1] = event.value
            elif event.code == evdev.ecodes.ABS_Z:
                accel[2] = event.value
            # Gyroscope
            elif event.code == evdev.ecodes.ABS_RX:
                gyro[0] = event.value
            elif event.code == evdev.ecodes.ABS_RY:
                gyro[1] = event.value
            elif event.code == evdev.ecodes.ABS_RZ:
                gyro[2] = event.value

        now = time.time()
        is_moving = any(abs(v) > 50 for v in gyro)

        if is_moving and (now - last_print > 0.08):
            motion_count += 1
            direction = []
            if gyro[0] > 100: direction.append("Pitch Down")
            elif gyro[0] < -100: direction.append("Pitch Up")
            if gyro[1] > 100: direction.append("Turn Right")
            elif gyro[1] < -100: direction.append("Turn Left")
            if gyro[2] > 100: direction.append("Tilt Right")
            elif gyro[2] < -100: direction.append("Tilt Left")
            dir_str = f" [{', '.join(direction)}]" if direction else ""
            status = f"\033[92m>>> MOTION (#{motion_count}){dir_str}\033[0m"
            print(f"{time.strftime('%H:%M:%S'):<8} | {f'({accel[0]:6d}, {accel[1]:6d}, {accel[2]:6d})':<24} | \033[92m{f'P:{gyro[0]:6d} Y:{gyro[1]:6d} R:{gyro[2]:6d}':<26}\033[0m | {status}")
            last_print = now
        elif not is_moving and (now - last_print > 0.5):
            status = "Stationary (Rest)"
            print(f"{time.strftime('%H:%M:%S'):<8} | {f'({accel[0]:6d}, {accel[1]:6d}, {accel[2]:6d})':<24} | {f'P:{gyro[0]:6d} Y:{gyro[1]:6d} R:{gyro[2]:6d}':<26} | {status}")
            last_print = now

except KeyboardInterrupt:
    print("\n[*] Live test stopped.")
except PermissionError:
    print(f"[-] No read permission for {dev.path}. Run with: sudo python3 ~/test-dualsense-gyro.py")
