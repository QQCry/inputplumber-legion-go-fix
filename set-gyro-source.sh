#!/usr/bin/env bash
# set-gyro-source.sh - Switch between Tablet Sensor and Right Controller Sensor (Live without restart)

TARGET_FILE="/etc/inputplumber/gyro_source"

function show_help() {
  echo "Usage: $0 [tablet|controller|status]"
  echo ""
  echo "Options:"
  echo "  tablet       Switch to internal tablet/display sensor (default)"
  echo "  controller   Switch to right controller sensor (detached or attached)"
  echo "  status       Display currently configured gyro source"
  echo ""
}

MODE="$1"

if [ -z "$MODE" ] || [ "$MODE" = "status" ]; then
  if [ -f "$TARGET_FILE" ]; then
    CUR=$(cat "$TARGET_FILE" | tr -d '[:space:]')
  else
    CUR="tablet (Default - config file does not exist yet)"
  fi
  echo "=========================================================="
  echo "  Current Gyro Source: $CUR"
  echo "=========================================================="
  if [[ "$CUR" =~ controller|right ]]; then
    echo "-> Motion/Gyro is currently sourced from the RIGHT CONTROLLER."
  else
    echo "-> Motion/Gyro is currently sourced from the TABLET / DISPLAY."
  fi
  echo ""
  echo "To switch:"
  echo "  $0 tablet       (Tablet / Display Sensor)"
  echo "  $0 controller   (Right Controller Sensor)"
  echo "=========================================================="
  exit 0
fi

case "$MODE" in
  tablet|center|display|handheld)
    VALUE="tablet"
    DISPLAY_NAME="Tablet / Display Sensor"
    ;;
  controller|right|docked|joycon)
    VALUE="controller"
    DISPLAY_NAME="Right Controller Sensor"
    ;;
  help|-h|--help)
    show_help
    exit 0
    ;;
  *)
    echo "[-] Unknown mode: $MODE"
    show_help
    exit 1
    ;;
esac

# Write to /etc/inputplumber/gyro_source
if [ -w "$TARGET_FILE" ] || [ -w "$(dirname "$TARGET_FILE")" ]; then
  echo "$VALUE" > "$TARGET_FILE"
  chmod 666 "$TARGET_FILE" 2>/dev/null || true
else
  if command -v sudo >/dev/null 2>&1; then
    echo "$VALUE" | sudo tee "$TARGET_FILE" >/dev/null
    sudo chmod 666 "$TARGET_FILE" 2>/dev/null || true
  else
    echo "[-] No write permissions for $TARGET_FILE. Please run with sudo:"
    echo "    sudo $0 $MODE"
    exit 1
  fi
fi

echo "=========================================================="
echo "  [+] Gyro source switched to: $DISPLAY_NAME ($VALUE)"
echo "=========================================================="
echo "InputPlumber applies the change live in the background."
echo "No restart of InputPlumber or running games is required!"
echo "=========================================================="
