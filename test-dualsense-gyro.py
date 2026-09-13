#!/usr/bin/env python3
import glob
import os
import sys
import time

try:
    import evdev
except ImportError:
    print("[-] Das Python-Modul 'evdev' ist nicht installiert.")
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
    print("[-] Kein DualSense Motion Sensors Event-Gerät gefunden!")
    print("    Läuft inputplumber.service mit Ziel ds5?")
    sys.exit(1)

print("=" * 70)
print(f"  DualSense 12x Gyroskop & Accelerometer Live-Test")
print(f"  Gerät: {dev.name} ({dev.path})")
print("=" * 70)
print("[*] Gyro misst Drehgeschwindigkeit (RX=Pitch/Nicken, RY=Yaw/Gieren, RZ=Roll/Rollen).")
print("[*] Accel misst Lage & Schwerkraft (ABS_X, ABS_Y, ABS_Z).")
print("[*] Bewege oder drehe das Legion Go jetzt in den Händen!\n")
print(f"{'Zeit':<8} | {'Accel (X, Y, Z)':<24} | {'Gyro (Pitch, Yaw, Roll)':<26} | Status")
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
            if gyro[0] > 100: direction.append("Nicken Vor")
            elif gyro[0] < -100: direction.append("Nicken Zurück")
            if gyro[1] > 100: direction.append("Drehen Rechts")
            elif gyro[1] < -100: direction.append("Drehen Links")
            if gyro[2] > 100: direction.append("Kippen Rechts")
            elif gyro[2] < -100: direction.append("Kippen Links")
            dir_str = f" [{', '.join(direction)}]" if direction else ""
            status = f"\033[92m>>> BEWEGUNG (#{motion_count}){dir_str}\033[0m"
            print(f"{time.strftime('%H:%M:%S'):<8} | {f'({accel[0]:6d}, {accel[1]:6d}, {accel[2]:6d})':<24} | \033[92m{f'P:{gyro[0]:6d} Y:{gyro[1]:6d} R:{gyro[2]:6d}':<26}\033[0m | {status}")
            last_print = now
        elif not is_moving and (now - last_print > 0.5):
            status = "Stillstand (Keine Drehung)"
            print(f"{time.strftime('%H:%M:%S'):<8} | {f'({accel[0]:6d}, {accel[1]:6d}, {accel[2]:6d})':<24} | {f'P:{gyro[0]:6d} Y:{gyro[1]:6d} R:{gyro[2]:6d}':<26} | {status}")
            last_print = now

except KeyboardInterrupt:
    print("\n[*] Live-Test beendet.")
except PermissionError:
    print(f"[-] Keine Leseberechtigung für {dev.path}. Bitte mit 'sudo python3 ~/test-dualsense-gyro.py' ausführen.")
