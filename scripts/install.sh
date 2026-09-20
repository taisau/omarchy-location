#!/usr/bin/env bash
# omarchy-location installer.
#
# Usage:
#   scripts/install.sh [--ha-url URL] [--ha-token TOKEN] [--entities E1,E2]
#                      [--interval SEC] [--port PORT] [--no-firefox] [--no-units]
#
# - writes ~/.config/omarchy-location/config.json (0600)
# - installs ~/.config/systemd/user/omarchy-location-daemon.service
# - enables + starts the unit (unless --no-units)
# - appends Firefox geo.provider prefs to the active profile user.js
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$HOME/.config/omarchy-location"
CONFIG_FILE="$CONFIG_DIR/config.json"
UNIT_FILE="$HOME/.config/systemd/user/omarchy-location-daemon.service"
UNIT_SRC="$(dirname "$0")/../systemd/omarchy-location-daemon.service"

HA_URL="http://100.75.37.107"
HA_TOKEN=""
HA_ENTITIES="device_tracker.pixel_9_pro"
INTERVAL="300"
PORT="9438"
DO_FIREFOX=1
DO_UNITS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --ha-url)     HA_URL="$2"; shift 2 ;;
    --ha-token)   HA_TOKEN="$2"; shift 2 ;;
    --entity)     HA_ENTITIES="$HA_ENTITIES,$2"; shift 2 ;;
    --entities)   HA_ENTITIES="$2"; shift 2 ;;
    --interval)   INTERVAL="$2"; shift 2 ;;
    --port)       PORT="$2"; shift 2 ;;
    --no-firefox) DO_FIREFOX=0; shift ;;
    --no-units)   DO_UNITS=0; shift ;;
    -h|--help)    grep '^#' "$0" | head -12; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

mkdir -p "$CONFIG_DIR" "$HOME/.config/systemd/user"

if [ "$HA_TOKEN" = "" ]; then
  echo -n "Home Assistant long-lived access token: "
  read -r -s HA_TOKEN
  echo
fi

export HA_TOKEN HA_URL HA_ENTITIES_PORTED
unset HA_ENTITIES_PORTED
export HA_ENTITIES_LIST="$HA_ENTITIES"
export HA_URL PORT INTERVAL

python3 - "$CONFIG_FILE" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
entities = [e.strip() for e in os.environ.get("HA_ENTITIES_LIST", "").split(",") if e.strip()]
token = os.environ["HA_TOKEN"]
url = os.environ["HA_URL"]
port = int(os.environ["PORT"])
interval = int(os.environ["INTERVAL"])
sources = [
    {"type": "wifi", "name": "wifi", "enabled": True,
     "interval": max(120, interval), "priority": 90}
]
for i, e in enumerate(entities):
    if "pixel" in e or "phone" in e:
        label = "Phone GPS"
    elif "pepwave" in e or "vehicle" in e or "router" in e:
        label = "Vehicle GPS"
    else:
        label = e
    sources.append({"type": "ha", "name": label, "label": label,
                    "url": url, "token": token, "entity": e,
                    "enabled": True, "interval": interval, "priority": 10 + i*10})
cfg = {"port": port, "sources": sources}
with open(path, "w") as f:
    f.write(json.dumps(cfg, indent=2))
os.chmod(path, 0o600)
print("wrote", path)
PYEOF

install -m 644 "$UNIT_SRC" "$UNIT_FILE"
echo "installed $UNIT_FILE"

if [ "$DO_UNITS" = "1" ]; then
  systemctl --user daemon-reload
  systemctl --user enable --now omarchy-location-daemon.service
  echo "daemon enabled + started"
fi

if [ "$DO_FIREFOX" = "1" ]; then
  PROFILE_DIR="$(ls -d "$HOME"/.config/mozilla/firefox/*.default-release 2>/dev/null | head -1 || true)"
  if [ -n "$PROFILE_DIR" ] && [ -f "$PROFILE_DIR/user.js" ] && grep -q "omarchy-location" "$PROFILE_DIR/user.js"; then
    echo "Firefox prefs already wired in $PROFILE_DIR/user.js (skipping)"
  elif [ -n "$PROFILE_DIR" ]; then
    cat >> "$PROFILE_DIR/user.js" <<JS

// omarchy-location: local geolocation provider (added by install.sh)
user_pref("geo.provider.network.url", "http://127.0.0.1:${PORT}/geolocate");
user_pref("geo.provider.network.timeout", 5000);
user_pref("geo.provider.use_geoclue", false);
JS
    echo "appended Firefox prefs to $PROFILE_DIR/user.js (restart Firefox to apply)"
  else
    echo "! no default-release Firefox profile found; wire geo prefs manually."
  fi
fi

echo "done. verify with:"
echo "  \$HOME/.config/omarchy/plugins/io.github.taisau.location/bin/omarchy-location status"
