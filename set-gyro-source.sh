#!/usr/bin/env bash
# set-gyro-source.sh - Umschalten zwischen Tablet-Sensor und Controller-Sensor (Live ohne Neustart)

TARGET_FILE="/etc/inputplumber/gyro_source"

function show_help() {
  echo "Verwendung: $0 [tablet|controller|status]"
  echo ""
  echo "Optionen:"
  echo "  tablet       Schaltet auf den internen Tablet/Display-Sensor um (Standard)"
  echo "  controller   Schaltet auf den rechten Controller-Sensor um (abgedockt oder angedockt)"
  echo "  status       Zeigt den aktuell eingestellten Gyro-Sensor an"
  echo ""
}

MODE="$1"

if [ -z "$MODE" ] || [ "$MODE" = "status" ]; then
  if [ -f "$TARGET_FILE" ]; then
    CUR=$(cat "$TARGET_FILE" | tr -d '[:space:]')
  else
    CUR="tablet (Standard - Datei existiert noch nicht)"
  fi
  echo "=========================================================="
  echo "  Aktueller Gyro-Sensor: $CUR"
  echo "=========================================================="
  if [[ "$CUR" =~ controller|right ]]; then
    echo "-> Motion/Gyro stammt aktuell vom RECHTEN CONTROLLER."
  else
    echo "-> Motion/Gyro stammt aktuell vom TABLET / DISPLAY."
  fi
  echo ""
  echo "Zum Wechseln:"
  echo "  $0 tablet       (Tablet / Display Sensor)"
  echo "  $0 controller   (Rechter Controller Sensor)"
  echo "=========================================================="
  exit 0
fi

case "$MODE" in
  tablet|center|display|handheld)
    VALUE="tablet"
    DISPLAY_NAME="Tablet / Display-Sensor"
    ;;
  controller|right|docked|joycon)
    VALUE="controller"
    DISPLAY_NAME="Rechter Controller-Sensor"
    ;;
  help|-h|--help)
    show_help
    exit 0
    ;;
  *)
    echo "[-] Unbekannter Modus: $MODE"
    show_help
    exit 1
    ;;
esac

# Schreiben nach /etc/inputplumber/gyro_source
if [ -w "$TARGET_FILE" ] || [ -w "$(dirname "$TARGET_FILE")" ]; then
  echo "$VALUE" > "$TARGET_FILE"
  chmod 666 "$TARGET_FILE" 2>/dev/null || true
else
  if command -v sudo >/dev/null 2>&1; then
    echo "$VALUE" | sudo tee "$TARGET_FILE" >/dev/null
    sudo chmod 666 "$TARGET_FILE" 2>/dev/null || true
  else
    echo "[-] Keine Schreibrechte für $TARGET_FILE. Bitte mit sudo ausführen:"
    echo "    sudo $0 $MODE"
    exit 1
  fi
fi

echo "=========================================================="
echo "  [+] Gyro-Quelle umgestellt auf: $DISPLAY_NAME ($VALUE)"
echo "=========================================================="
echo "InputPlumber übernimmt die Änderung automatisch live im Hintergrund."
echo "Es ist kein Neustart von InputPlumber oder Spielen nötig!"
echo "=========================================================="
