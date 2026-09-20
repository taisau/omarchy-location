# omarchy-location

Multi-source location resolver for [Omarchy](https://omarchy.org/): a bar
widget + background daemon that merges fixes from pluggable sources and
exposes them to apps.

```
Sources                    Daemon                        Consumers
─────────                  ──────                        ─────────
WiFi pos (beaconDB)   ─┐
HA device_tracker     ─┼─→ omarchy-location-daemon ─┬─ fix.json / status.json
 (phone GPS, vehicle) ─┘   (systemd user service)    ├─ GET 127.0.0.1:<port>/geolocate
                                                     │   (Ichnaea/Mozilla format)
                                                     └─ per-source status JSON
```

Merge policy (fixed): **freshest fix wins**; within a 30 s tie window the
more accurate fix wins; remaining ties go to the lowest priority number.
Each source can be disabled individually and has its own poll interval.
No staleness cutoff — readers display the fix age themselves.

## Sources

| Type | Gets position from | Notes |
|---|---|---|
| `ha` | Home Assistant REST `device_tracker.*` entities | phone GPS (HA Companion), vehicle GPS, anything position-capable. URL + token + entity are per-source settings; several entities = several sources |
| `wifi` | `nmcli` WiFi scan + [beaconDB](https://beacondb.net) | No geoclue needed. Sends nearby AP MAC addresses to beaconDB when it runs — disable it if you don't want that |

## What install.sh does

- Writes `~/.config/omarchy-location/config.json` (mode 0600, holds HA tokens)
- Installs `~/.config/systemd/user/omarchy-location-daemon.service`
- `systemctl --user enable --now omarchy-location-daemon`
- Appends `geo.provider.network.*` prefs to the active Firefox profile's
  `user.js` so Firefox geolocation prompts return the merged fix
  (pointing at `http://127.0.0.1:9438/geolocate`)

Nothing is written outside `$HOME`, no sudo required.

## CLI

```
omarchy-location status    # coords + daemon state
omarchy-location sources   # per-source table (age, errors)
omarchy-location fix       # raw JSON fix (also --plain "lat,lon")
omarchy-location refresh   # ask daemon to poll all sources now
```

## Bar widget

- Icon fresh (foreground) / stale (dimmed) / daemon down (urgent + slashed)
- Left-click panel: current fix, per-source age + errors, Settings (editable
  source list), Refresh, Map, Logs
- Middle-click: force a poll of all sources now
- Right-click: open journal follow

## Manual install

```bash
git clone https://github.com/taisau/omarchy-location ~/.config/omarchy/plugins/io.github.taisau.location
omarchy restart shell                      # bar widget appears
~/.config/omarchy/plugins/io.github.taisau.location/scripts/install.sh
```

## Uninstall

```bash
~/.config/omarchy/plugins/io.github.taisau.location/scripts/uninstall.sh
omarchy plugin remove io.github.taisau.location
```

## Config

`~/.config/omarchy-location/config.json`:

```json
{
  "port": 9438,
  "sources": [
    { "type": "wifi", "name": "wifi", "enabled": true, "interval": 300, "priority": 90 },
    { "type": "ha", "name": "Phone GPS", "label": "Phone GPS",
      "url": "http://HA-IP:8123", "token": "…", "entity": "device_tracker.pixel_9_pro",
      "enabled": true, "interval": 300, "priority": 10 },
    { "type": "ha", "name": "Vehicle GPS", "label": "Vehicle GPS",
      "url": "http://HA", "token": "…", "entity": "device_tracker.pepwave_vehicle",
      "enabled": true, "interval": 300, "priority": 20 }
  ]
}
```

Merge policy and the Firefox endpoint are built in; everything else is
per-source. The daemon reloads on config-file change; the bar plugin edits
the same file from the Settings panel.

## Trust model / privacy

- The daemon holds your HA tokens in `~/.config/omarchy-location/config.json`
  (0600, your user only). Mode 0600 is forced by `config-write` and install.
- The HTTP shim listens on **127.0.0.1 only**.
- Every site you grant geolocation permission to learns the merged position;
  that permission prompt is Firefox's normal flow.
- WiFi positioning (if enabled) broadcasts nearby AP MACs to beaconDB.

## License

MIT — see LICENSE.
