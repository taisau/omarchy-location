# omarchy-location — Plugin Project Memory

**Plugin**: `io.github.taisau.location` (manifest id), repo `github.com/taisau/omarchy-location`, public, MIT, v1.1.1.
**Framework symlink**: `~/.config/omarchy/plugins/io.github.taisau.location` → `~/sync/5 computadors/53 devices/53.01 framework/omarchy-location` (bottom-launcher pattern).
**Marketplace submission**: [omacom/omarchy-plugin-marketplace#7847](https://github.com/omacom/omarchy-plugin-marketplace/issues/7847) (2026-09-20).

## What it is

Multi-source location resolver for Omarchy:

- Daemon `cmd/omarchy-location-daemon.py` (python3 stdlib only, systemd user unit `omarchy-location-daemon.service`): polls sources, merges one best fix, writes `~/.local/state/omarchy-location/{fix.json,status.json}`, serves:
  - `GET 127.0.0.1:9438/geolocate` — Ichnaea format for Firefox geolocation (`geo.provider.network.url` points here via profile user.js)
  - `GET /status`, `POST /refresh`
- Sources (each: enabled flag, interval, priority):
  - `ha` — Home Assistant REST device_tracker entities (Pixel phone GPS + Pepwave vehicle GPS on the a-ha instance, token from [[52.01 secrets]], url `http://100.75.37.107`)
  - `wifi` — nmcli scan + BeaconDB geolocation (no geoclue needed; rural = IP fallback only)
- Merge: accuracy-first inside `max_age_minutes` (default 15) window, else freshest. No hard staleness cutoff at consumers.
- Config: `~/.config/omarchy-location/config.json` (0600; token inside; daemon + QML both read; QML writes via b64→`printf|base64 -d|cmd/omarchy-location config-write` to avoid shell injection).
- CLI `cmd/omarchy-location` (symlinked from plugin dir): `status|sources|fix [--plain]|refresh|config-write` (subcommands read state files; `refresh` POSTs the daemon).
- Bar chip: **indicator-style** (`qs.Ui BarIndicator`, Material Symbols `location_searching` `\ue1b7`), defaultSection `center` — sits right of the omarchy.indicators cluster (DND/nightlight/stay-awake look). Left-click panel; middle refresh; right = journal follow.
- Panel (Panel.qml, modeled on espanso plugin): fix + per-source status rows + editable source list (name/url/token/entity/interval/priority/enabled + add/remove rows + wifi toggle) + Save → writes config 0600 (daemon reloads on mtime).

## Hard-won gotchas

- **Syncthing central ignore**: `/opt/syncthing/sync/5 computadors/54 services/54.02 syncthing/.common_stignore.txt` contains `(?d)(?i)bin` (any dir named bin) + `__pycache__` — hence `cmd/` not `bin/`.
- **Sync/exec-bit races**: Syncthing may deliver cmd/* without +x; `chmod +x` on framework after sync churn if "Permission denied". Also restarting the shell BEFORE the newest BarWidget.qml syncs = QML parse error on OLD content ("Plugin widget failed: Expected token ':'") which then sticks until next restart — Paulwait for sync or `omarchy restart shell` twice.
- **Plugin updates don't hot-reload via symlink**: localPluginWatcher inotify only watches the plugins dir itself (symlink fires, target file changes don't); always `omarchy restart shell` after synced QML edits.
- **QML top-level statements are syntax errors** (top-level `console.warn` line → "Expected token ':'" and the whole widget fails silently-ish with plugin load warn). Debug prints go inside Component.onCompleted.
- **BarIndicator opaque behaviors**: `indicatorHost: null` (we're not inside the omarchy.indicators host) means `revealInactiveIndicators` is false → opacity 0 when INACTIVE unless active. Keep it always-visible-ish: our `active` = fix fresh; the chip appears hidden (opacity 0) only when stale/unhealthy by polluted effects... (accepted look; stale = dimmed via `dimmed` when active=false → actually 0.45 only if host reveals; keep `active` semantics honest).
- Firefox: prefs go in `~/.config/mozilla/firefox/p0m88tyj.default-release/user.js` (`geo.provider.network.url`, `.timeout`, `use_geoclue=false`); install.sh appends + dedupes by "omarchy-location" marker comment; uninstall.sh strips them.
- HA time parsing MUST use `calendar.timegm` (strptime `%z` + `mktime` = broken epoch, ages were negative).
- nmcli `-t` escapes `:` as `\:` INSIDE fields — BSSID parsing must unescape first (regex `replace("\\:", "\x1f").split(":")`).
- Panel edit rows mutate `root.editSources[index]` in Repeater delegates; `index` from required property is reliable; model reset via `srcRepeater.model = root.editSources.slice()`.
- Ubuntu-style `nmmcli dev wifi rescan` + 2s settle before reading the list.

## Uninstall

`~/.config/omarchy/plugins/io.github.taisau.location/scripts/uninstall.sh` then `omarchy plugin remove io.github.taisau.location`.

## Firefox geolocation test

1. Restart Firefox (prefs load from user.js at start).
2. Visit a location site and allow permission — should return the HA merged fix (check `curl 127.0.0.1:9438/geolocate` for expected coords).
