#!/usr/bin/env python3
import glob
import os
import struct
import sys
import time

def find_deck_hidraws():
    nodes = []
    for dev in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        uevent_file = os.path.join(dev, "device/uevent")
        if os.path.exists(uevent_file):
            with open(uevent_file) as f:
                content = f.read()
                if "000028DE:000012FE" in content or "Legion Go Controller" in content:
                    nodes.append(f"/dev/{os.path.basename(dev)}")
    return nodes

deck_nodes = find_deck_hidraws()

if not deck_nodes:
    print("[-] Kein virtueller Controller gefunden! Läuft inputplumber.service?")
    sys.exit(1)

if len(deck_nodes) == 1:
    print(f"[+] Perfekt: Genau 1 virtueller Controller aktiv: {deck_nodes[0]}")
    dev_path = deck_nodes[0]
else:
    print(f"[!] Warnung: Mehrere virtuelle Controller gefunden: {deck_nodes}")
    dev_path = deck_nodes[0]
    print(f"[*] Teste primären Controller: {dev_path}")

print("[*] Hinweis: Gyro misst Drehung (P: Pitch/Nicken, Y: Yaw/Gieren, R: Roll/Rollen).")
print("[*] Accel misst Lage/Gravitation (Ruhezustand flach auf Tisch: Z ~ 16384).")
print("[*] Bitte nimm das Legion Go / den rechten Controller in die Hand und bewege ihn!\n")
print(f"{'Zeit':<8} | {'Accel (Gravitation/Lage)':<26} | {'Gyro (Drehung)':<26} | Status")
print("-" * 75)

try:
    with open(dev_path, "rb") as f:
        last_print = 0
        motion_count = 0
        max_p_pos = 0
        max_p_neg = 0
        total_p = 0
        sample_count = 0
        while True:
            data = f.read(64)
            if len(data) >= 36 and data[2] == 0x09:
                accel_x, accel_y, accel_z = struct.unpack("<hhh", data[24:30])
                pitch, yaw, roll = struct.unpack("<hhh", data[30:36])
                
                max_p_pos = max(max_p_pos, pitch)
                max_p_neg = min(max_p_neg, pitch)
                total_p += pitch
                sample_count += 1

                is_gyro_active = (abs(pitch) > 10 or abs(yaw) > 10 or abs(roll) > 10)
                now = time.time()
                
                if is_gyro_active and (now - last_print > 0.08):
                    motion_count += 1
                    direction = []
                    if pitch > 30: direction.append("Nicken Vor")
                    elif pitch < -30: direction.append("Nicken Zurück")
                    if yaw > 30: direction.append("Drehen Rechts")
                    elif yaw < -30: direction.append("Drehen Links")
                    if roll > 30: direction.append("Kippen Rechts")
                    elif roll < -30: direction.append("Kippen Links")
                    dir_str = f" [{', '.join(direction)}]" if direction else ""
                    status = f"\033[92m>>> DREHUNG (#{motion_count}){dir_str}\033[0m"
                    print(f"{time.strftime('%H:%M:%S'):<8} | {f'({accel_x:6d}, {accel_y:6d}, {accel_z:6d})':<26} | \033[92m{f'P:{pitch:6d} Y:{yaw:6d} R:{roll:6d}':<26}\033[0m | {status}")
                    last_print = now
                elif not is_gyro_active and (now - last_print > 0.4):
                    status = "Stillstand (Keine Bewegung)"
                    print(f"{time.strftime('%H:%M:%S'):<8} | {f'({accel_x:6d}, {accel_y:6d}, {accel_z:6d})':<26} | {f'P:{pitch:6d} Y:{yaw:6d} R:{roll:6d}':<26} | {status}")
                    last_print = now
                    
except KeyboardInterrupt:
    print("\n================ Symmetrie-Statistik ================")
    print(f"  Maximaler Ausschlag VOR/RUNTER: +{max_p_pos:6d}")
    print(f"  Maximaler Ausschlag ZURÜCK/HOCH: {max_p_neg:6d}")
    if sample_count > 0:
        print(f"  Durchschnitt / Drift:           {total_p / sample_count:+6.1f}")
    print("======================================================")
    print("[*] Beendet.")
except PermissionError:
    print(f"[-] Keine Leseberechtigung für {dev_path}. Führe das Skript mit sudo aus: sudo python3 ~/test-gyro.py")
