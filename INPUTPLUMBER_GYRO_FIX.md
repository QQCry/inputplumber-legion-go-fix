# InputPlumber Gyroscope & Accelerometer Dokumentation für Lenovo Legion Go

Dieses Dokument fasst die Implementierung, Firmware-Eigenheiten und Konfiguration des Gyroskops und Beschleunigungssensors in InputPlumber auf dem Lenovo Legion Go (Modell 1 `83E1` & Modell 2) zusammen.

InputPlumber unterstützt auf dem Legion Go **zwei vollwertige Bewegungsquellen (Motion Sources)**:
1. **Nativer Rechter Controller-Sensor:** Direkt über das HIDRAW-Interface der Controller-MCU (HHD-Portierung) – funktioniert sowohl **kabellos abgedockt** als auch **fest angedockt** im Handheld-Modus!
2. **Interner Tablet-/Display-Sensor:** Über den AMD Sensor Fusion Hub (`iio:device0` / `iio:device1`).

---

## 1. Nativer Rechter Controller-Sensor (HIDRAW-Treiber)

Im originalen InputPlumber-Upstream wurden die IMU-Daten der Joy-Cons standardmäßig ignoriert bzw. gefiltert (Upstream Issue #678 / PR #677). Die Logik des *Handheld Daemons (HHD)* wurde in Rust portiert und direkt in InputPlumbers `lego`-Treiber ([`go1_driver.rs`](file:///home/qqcry/Projekte/InputPlumber/src/drivers/lego/go1_driver.rs), [`go2_driver.rs`](file:///home/qqcry/Projekte/InputPlumber/src/drivers/lego/go2_driver.rs) und [`hidraw/legion_go2.rs`](file:///home/qqcry/Projekte/InputPlumber/src/input/source/hidraw/legion_go2.rs)) integriert.

### Funktionsweise & Protokoll-Details:

* **Geräte-Erkennung & Interfaces:**
  * **VID:** `0x17ef` (Lenovo)
  * **PIDs:**
    * Legion Go 1: `0x6182` (XInput), `0x6183` (DInput Attached), `0x6184` (DInput Detached), `0x6185` (FPS).
    * Legion Go 2: `0x61eb` (XInput), `0x61ec` (DInput Attached), `0x61ed` (DInput Detached), `0x61ee` (FPS).
  * **USB-Interfaces (wichtig für Node-Zuweisung):**
    * **Interface 1 (`TP_IID = 0x01` / meist `/dev/hidraw0`):** Touchpad & Tastatur. Wird exklusiv vom `go_touchpad_driver` verwaltet.
    * **Interface 2 (`GP_IID = 0x02` / meist `/dev/hidraw1`):** Gamepad-Eingaben, MCU-Kommandos und 16-Bit Motion-Reports. Der Treiber prüft strikt `info.interface_number() == GP_IID`.

* **MCU Wake-up, Heartbeat & Paketlängen (Kritisch!):**
  Die Lenovo-MCU verlangt unterschiedliche Paketformate:
  1. **Lenovo Feature-Reports (Padded auf 64 Bytes):**
     * Touchpad-Bypass deaktivieren: `05 00 04 03 04 00` (Rechts) und `05 00 04 03 03 00` (Links) $\rightarrow$ Verhindert Ruckeln/Mauslag des Touchpads.
     * IMU-Power aktivieren: `05 00 04 05 04 01` (Rechts) und `05 00 04 05 03 01` (Links).
  2. **HHD Streaming- & Wakeup-Befehle (EXAKT 7 BYTES, UNPADDED!):**
     * **Wichtig:** Die Lenovo-Firmware verwirft `0x6a`-Kommandos vollständig, wenn sie auf 64 Bytes gepaddet sind! Sie müssen mit exakter Länge (7 Bytes) gesendet werden:
     * IMU Sensor einschalten: `05 06 6a 02 04 01 01` (Rechts) bzw. `05 06 6a 02 03 01 01` (Links).
     * 16-Bit HQ-Stream aktivieren: `05 06 6a 07 04 02 01` (Rechts) bzw. `05 06 6a 07 03 02 01` (Links).
     * Legion-Swap deaktivieren: `05 06 69 04 01 01 01`.

* **Periodischer Heartbeat & Stream-Silence Re-Arm:**
  * Da die Controller-Firmware das 16-Bit-Streaming beendet, wenn der Controller ruht oder das Kommando nur einmalig gesendet wurde, implementiert der Treiber einen automatischen Keep-Alive:
    * **Regulärer Timer (alle 3 Sekunden):** Sendet non-blocking Keep-Alive-Pakete.
    * **Silence-Erkennung (nach 1,5 Sekunden ohne Daten):** Sendet sofort die 7-Byte Re-Arm-Pakete, um den Sensor aufzuwecken.
    * **Vollkommen non-blocking:** Keine `thread::sleep()`-Aufrufe im Polling-Pfad.

* **Robuster Polling-Loop & Fehlerresilienz:**
  * Transiente USB-Timeouts, Puffer-Zuschnitte oder Unpack-Fehler beenden nicht mehr den Treiber-Thread (`SourceDriver`).
  * Nur echte Hardware-Disconnects (`device disconnected` / `No such device`) werden nach oben gereicht, damit Udev das Device bei Re-Plug sauber neu bindet.
  * Jedes ankommende IMU-Paket wird im Log bestätigt:
    ```
    Received IMU report: len=64
    ```

* **HID-Report Parsing & Sensor-Orientierung:**
  * Report-ID: `0x04`, Command-ID: `0x74` an Byte 2.
  * Datenlänge: Mindestens 60 Bytes.
  * **Big-Endian (`i16` MSB):** Da die Platine des rechten Joy-Cons im Gehäuse um 90 Grad rotiert montiert ist, liegen die Daten ab Byte 47 wie folgt:
    * Byte 47: Timestamp (`u8`)
    * Bytes 48–49: `accel_z` (+0.00212 m/s²)
    * Bytes 50–51: `accel_x` (-0.00212 m/s²)
    * Bytes 52–53: `accel_y` (-0.00212 m/s²)
    * Bytes 54–55: `gyro_z` (+0.001065 rad/s)
    * Bytes 56–57: `gyro_x` (-0.001065 rad/s)
    * Bytes 58–59: `gyro_y` (-0.001065 rad/s)

* **Firmware-Glitch-Filter:**  
  Die Controller-Firmware leidet unter einem bekannten Bug, bei dem sporadisch exakt die Werte `abs(val) == 254` oder `abs(val) == 255` gesendet werden. Diese Störpakete werden vom Treiber verworfen.

* **Skalierung & Kalibrierung:**
  * **Beschleunigung (`Accel`):** Der Controller liefert ca. 4.625 LSB für 1G Erdbeschleunigung. InputPlumber skaliert diese mit dem Faktor **`3.542`**, um exakt den Standard von Steam Deck UHID (**16.384 LSB / 1G**) zu treffen. Dadurch erkennt Steam Input die Raumlage sofort stabil ohne Schiefstand.
  * **Gravitations-Vektor-Erhalt:** Sollte der Sensor kurz einschlafen, sendet der Treiber keine `(0, 0, 0)`-Nullwerte an das virtuelle Steam Deck UHID, sondern hält den letzten gültigen Gravitationsvektor aufrecht. Steam schaltet das Gyroskop dadurch niemals ab.
  * **Gyroskop (`Gyro`):** Wird mit einem Hardware-Multiplikator von **`12.0x`** verarbeitet, was für ein extrem reaktives, direktes Ansprechverhalten in Spielen sorgt.

---

## 2. Interner Tablet-Sensor (IIO-Treiber)

Alternativ kann der fest im Tablet verbaute Sensor genutzt werden (`gyro_3d` + `accel_3d` über AMD Sensor Fusion Hub IIO).

### Konfiguration (`/etc/inputplumber/devices.d/50-legion_go.yaml`):
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
*Hinweis:* Ohne `accel_3d` liefert InputPlumber dauerhaft `(0, 0, 0)` für die Gravitation, woraufhin Steam Input das Gyroskop aus Sicherheitsgründen komplett abschaltet. Mit der obigen Matrix arbeitet auch der Tablet-Sensor einwandfrei mit 200 Hz.

---

## 3. Sensor-Umschaltung zur Laufzeit (Live Switch)

In InputPlumbers virtueller Steam-Deck-Emulation (`steam_deck_uhid.rs`) ist ein atomarer Umschaltmechanismus integriert, der die Konfigurationsdatei `/etc/inputplumber/gyro_source` überwacht:

* **Aktuellen Status abfragen:**
  ```bash
  ~/set-gyro-source.sh status
  ```
* **Auf rechten Controller umschalten (Standard für abgedocktes & angedocktes Spielen):**
  ```bash
  ~/set-gyro-source.sh controller
  ```
* **Auf internen Tablet-Sensor umschalten:**
  ```bash
  ~/set-gyro-source.sh tablet
  ```

> [!NOTE]
> Die Umschaltung erfolgt **sofort im laufenden Betrieb** innerhalb von Millisekunden. Weder InputPlumber noch das laufende Spiel müssen neu gestartet werden.

---

## 4. Hilfsskripte & Aktivierung

* **`sudo bash ~/enable-right-gyro-hhd.sh`:**  
  Installiert das gepatchte Binary nach `/usr/bin/inputplumber`, setzt sysfs-Regeln, sendet die unpadded 7-Byte HID-Aktivierungsbefehle und startet den Dienst neu.
* **`python3 ~/test-gyro.py`:**  
  Liest die Live-Pakete des virtuellen Steam Deck Controllers (`28de:12fe`) aus und visualisiert Gravitation (`Accel`) und Drehung (`Gyro`) in Echtzeit im Terminal:
  ```bash
  python3 ~/test-gyro.py
  ```
* **`~/set-gyro-source.sh`:**  
  Wechselt die aktive Bewegungsquelle live zwischen `controller` und `tablet`.
* **`journalctl -u inputplumber.service -f`:**  
  Live-Log-Verfolgung inklusive `Received IMU report: len=64` und Controller-Node-Bestätigung.

---

## 5. Nutzung in Gamescope & Steam Input (Game Mode)

InputPlumber emuliert systemweit einen nativen Steam Deck Controller (`deck-uhid`). Gamescope und Steam erkennen diesen automatisch.

### Gyro im Spiel konfigurieren:
1. Im Spiel die **Steam-Taste** (Legion-L) drücken $\rightarrow$ Controller-Symbol $\rightarrow$ **Layout bearbeiten**.
2. Den Reiter **Gyroskop** öffnen.
3. **Gyroskop-Verhalten festlegen:**
   * **„Als Maus“** *(Beste Option für Shooter / präzises Zielen)*.
   * **„Als rechter Joystick“** *(Für Spiele mit exklusiver Gamepad-Steuerung wie No Man's Sky)*.
4. **Aktivierungstaste:**
   * z. B. *„Immer an“* oder *„Linker Trigger (LT / L2) voll durchdrücken“* (beim Zielen / ADS).
   * *Hinweis:* Die Option *„Rechten Stick berühren“* funktioniert beim Legion Go nicht, da die Sticks keine kapazitiven Touch-Kappen besitzen.

### Kalibrierung überprüfen:
In den Steam-Einstellungen unter **Controller** $\rightarrow$ **Kalibrierung & erweiterte Einstellungen** $\rightarrow$ **Gyroskop** kann der künstliche Horizont geprüft und das Gerät bei Bedarf für 5 Sekunden flach abgelegt kalibriert werden.

---

## 6. Binaries & Pfade

* **Installiertes System-Binary:** `/usr/bin/inputplumber`
* **Lokales Staging-Binary:** `/home/qqcry/.local/bin/inputplumber-right-controller-12x`
* **Projekt-Quellcode:** `/home/qqcry/Projekte/InputPlumber`
* **Konfigurationsdatei Sensor-Wahl:** `/etc/inputplumber/gyro_source` (`controller` oder `tablet`)
* **Geräte-Konfiguration:** `/etc/inputplumber/devices.d/50-legion_go.yaml`
