#!/usr/bin/env bash
# omarchy-location uninstaller - everything install.sh created.
set -uo pipefail

systemctl --user disable --now omarchy-location-daemon 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/omarchy-location-daemon.service"
systemctl --user daemon-reload 2>/dev/null || true

rm -f "$HOME/.config/omarchy-location/config.json"
rmdir "$HOME/.config/omarchy-location" 2>/dev/null || true
rm -rf "$HOME/.local/state/omarchy-location"

# remove Firefox prefs (user.js lines between markers)
PROFILE_DIR="$(ls -d "$HOME"/.config/mozilla/firefox/*.default-release 2>/dev/null | head -1 || true)"
if [ -n "$PROFILE_DIR" ] && [ -f "$PROFILE_DIR/user.js" ]; then
  python3 - "$PROFILE_DIR/user.js" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'\n// omarchy-location: local geolocation provider \(added by install\.sh\)\n(?:user_pref\("geo\.provider\.[^;]+;\n)+', '\n', s)
open(p, "w").write(s2)
print("Firefox prefs reverted" if s2 != s else "no Firefox prefs edits found")
PYEOF
fi

echo "omarchy-location removed (plugin dir itself untouched; remove also 'omarchy plugin remove io.github.taisau.location')"
