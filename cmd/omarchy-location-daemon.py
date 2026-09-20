#!/usr/bin/env python3
"""omarchy-location daemon.

Multi-source location resolver:
  - "ha"   sources : Home Assistant REST device_tracker entities (phone GPS, vehicle GPS, ...)
  - "wifi" source  : nmcli WiFi scan + beaconDB geolocation (Ichnaea API)

Polls each enabled source on its own interval, merges one best fix
(freshest -> most accurate -> lowest priority) into:

  ~/.local/state/omarchy-location/fix.json      best fix (error object when none)
  ~/.local/state/omarchy-location/status.json   full per-source status

HTTP shim (loopback only):
  GET  :9438/geolocate  -> Ichnaea-format {"location":{"lat","lng"},"accuracy"} for Firefox
  GET  :9438/status     -> full status JSON
  POST :9438/refresh    -> poll all enabled sources now

Config: ~/.config/omarchy-location/config.json (0600), reloaded on mtime change.
Python 3 stdlib only.
"""

import copy
import http.server
import json
import os
import pathlib
import subprocess
import threading
import time
import urllib.error
import urllib.request

HOME = pathlib.Path.home()
STATE_DIR = HOME / ".local/state/omarchy-location"
STATE_DIR.mkdir(parents=True, exist_ok=True)
FIX_FILE = STATE_DIR / "fix.json"
STATUS_FILE = STATE_DIR / "status.json"
CONFIG_FILE = HOME / ".config/omarchy-location/config.json"

TIE_WINDOW = 30          # seconds within which "freshest" counts as a tie for accuracy decision
HTTP_PORT_DEFAULT = 9438

lock = threading.Lock()          # guards state
state = {}                       # key -> per-source runtime dict
config = {"port": HTTP_PORT_DEFAULT, "sources": []}
config_mtime = 0.0
current_sources = []
stop_event = threading.Event()


def log(*args):
    print("[omarchy-location]", *args, flush=True)


# ---------------------------------------------------------------- config ----

def load_config():
    global config, config_mtime
    try:
        mtime = CONFIG_FILE.stat().st_mtime
    except FileNotFoundError:
        return False
    if config_mtime and mtime == config_mtime:
        return False
    try:
        raw = json.loads(CONFIG_FILE.read_text())
    except Exception as e:
        log("config parse error:", e)
        return False
    srcs = []
    for s in raw.get("sources", []):
        if not isinstance(s, dict):
            continue
        stype = s.get("type")
        if stype not in ("ha", "wifi"):
            continue
        src = {
            "type": stype,
            "name": str(s.get("name") or stype),
            "enabled": bool(s.get("enabled", True)),
            "interval": max(10, int(s.get("interval") or 300)),
            "priority": int(s.get("priority") or 100),
        }
        if stype == "ha":
            src["url"] = str(s.get("url") or "").rstrip("/")
            src["token"] = str(s.get("token") or "")
            src["entity"] = str(s.get("entity") or "")
        srcs.append(src)
    config = {"port": int(raw.get("port") or HTTP_PORT_DEFAULT), "sources": srcs}
    config_mtime = mtime
    return True


def key_for(src):
    return src["type"] + ":" + src["name"]


def ensure_state(src):
    key = key_for(src)
    st = state.get(key)
    if st is None or st.get("label") != src["name"] or st.get("type") != src["type"]:
        old = st or {}
        st = {
            "label": src["name"],
            "type": src["type"],
            "enabled": src["enabled"],
            "priority": src["priority"],
            "interval": src["interval"],
            "last_fix": old.get("last_fix"),
            "last_poll": old.get("last_poll"),
            "last_error": None,
        }
        state[key] = st
    else:
        st["enabled"] = src["enabled"]
        st["priority"] = src["priority"]
        st["interval"] = src["interval"]
    return st


def rebuild_sources():
    global current_sources
    # drop state for removed/renamed sources
    alive = {key_for(s) for s in config["sources"]}
    for key in list(state):
        if key not in alive:
            state.pop(key)
    for src in config["sources"]:
        ensure_state(src)
    current_sources = list(config["sources"])


# ---------------------------------------------------------------- pollers ---

def _http_json(url, token=None, method="GET", body=None, timeout=10):
    req = urllib.request.Request(url, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data=data, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def poll_ha(src):
    if not src.get("url") or not src.get("token") or not src.get("entity"):
        raise ValueError("incomplete HA source config (url/token/entity)")
    url = src["url"].rstrip("/") + "/api/states/" + src["entity"]
    data = _http_json(url, token=src["token"])
    attrs = data.get("attributes") or {}
    lat, lon = attrs.get("latitude"), attrs.get("longitude")
    if lat is None or lon is None:
        raise ValueError(src["entity"] + " has no position attributes")
    fix_time_raw = data.get("last_reported") or data.get("last_updated")
    fix_time = _parse_ha_time(fix_time_raw)
    if fix_time is None:
        fix_time = time.time()
    return {
        "lat": float(lat), "lon": float(lon),
        "accuracy": attrs.get("gps_accuracy"),
        "altitude": attrs.get("altitude"),
        "speed": attrs.get("speed"),
        "fix_time": fix_time,
        "zone": data.get("state"),
        "source": key_for(src),
    }


def _parse_ha_time(raw):
    import calendar
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return calendar.timegm(time.strptime(raw, fmt))  # RFC3339 is UTC-anchored
        except (ValueError, TypeError):
            pass
    return None


def read_wifi_aps():
    """Force an active WiFi rescan, then read AP list. Robust to escaped SSIDs.

    nmcli -t emits hex:hex:hex:hex:hex:hex:<ssid>:<signal>:<freq...> rows; an
    SSID containing a literal ":" is "\\:"-escaped, so we split defensively.
    """
    subprocess.run(
        ["nmcli", "dev", "wifi", "rescan"], capture_output=True, text=True, timeout=20
    )
    time.sleep(2)
    out = subprocess.run(
        ["nmcli", "-t", "-f", "BSSID,SSID,SIGNAL", "dev", "wifi"],
        capture_output=True, text=True, timeout=45,
    )
    aps = []
    for line in out.stdout.splitlines():
        if not line.strip():
            continue
        fields = line.split(":")
        if len(fields) < 9:
            continue
        bssid = ":".join(fields[:6])          # BSSID = first 6 hex groups
        if any(len(f) != 2 for f in fields[:6]):
            continue
        sig, freq = fields[-2], fields[-1]
        try:
            sigpct = int(sig)
            int(freq)
        except ValueError:
            continue
        mac = bssid.lower()
        if mac.count(":") != 5 or ".:" in mac[5]:
            continue
        aps.append({"macAddress": mac, "pct": max(0, min(100, sigpct))})
    return aps


def poll_wifi(src):
    aps = read_wifi_aps()
    if len(aps) < 2:
        raise ValueError("not enough wifi access points (need >= 2)")
    for ap in aps:
        ap["signalStrength"] = -100 + ap.pop("pct") // 2      # %% -> dBm approx
    body = {"wifiAccessPoints": aps[:12], "fallbacks": {"lacf": False}}
    data = _http_json("https://beacondb.net/v1/geolocate", method="POST", body=body, timeout=12)
    loc = data.get("location") or {}
    lat, lon = loc.get("lat"), loc.get("lng")
    if lat is None or lon is None:
        raise ValueError("beacondb returned no position")
    return {
        "lat": float(lat), "lon": float(lon),
        "accuracy": data.get("accuracy"),
        "altitude": None, "speed": None,
        "fix_time": time.time(),
        "zone": None,
        "source": "wifi:beacondb",
    }


POLLERS = {"ha": poll_ha, "wifi": poll_wifi}


def run_poll(src):
    key = key_for(src)
    try:
        fix = POLLERS[src["type"]](src)
        with lock:
            st = ensure_state(src)
            st["last_fix"] = fix
            st["last_poll"] = time.time()
            st["last_error"] = None
            st["last_ok"] = time.time()
        write_snapshot()
    except Exception as e:
        with lock:
            st = ensure_state(src)
            st["last_poll"] = time.time()
            st["last_error"] = type(e).__name__ + ": " + str(e)
        write_snapshot()
        log("poll error", key, "-", e)


# ---------------------------------------------------------------- snapshot --

def pick_best():
    """freshest fix wins; inside TIE_WINDOW better accuracy wins; then priority."""
    cands = []
    for key, st in state.items():
        fx = st.get("last_fix")
        if fx and st.get("enabled"):
            cands.append((fx, st))
    if not cands:
        return None
    def ordering(c):
        fx, st = c
        acc = fx.get("accuracy") or 10**9
        return (-fx["fix_time"], 0)
    cands.sort(key=ordering)
    best_fx, best_st = cands[0]
    best_t = best_fx["fix_time"]
    for fx, st in cands[1:]:
        dt = abs(fx["fix_time"] - best_t)
        if dt <= TIE_WINDOW:
            fx_acc = fx.get("accuracy") if fx.get("accuracy") else 10**9
            b_acc = best_fx.get("accuracy") if best_fx.get("accuracy") else 10**9
            if fx_acc < b_acc or (fx_acc == b_acc and st["priority"] < best_st["priority"]):
                best_fx, best_st = fx, st
    return best_fx


def write_snapshot():
    with lock:
        sources = []
        for key, st in state.items():
            sources.append({
                "key": key,
                "label": st.get("label", key),
                "type": st.get("type"),
                "enabled": st.get("enabled"),
                "priority": st.get("priority"),
                "interval": st.get("interval"),
                "last_poll": st.get("last_poll"),
                "last_error": st.get("last_error"),
                "fix": st.get("last_fix"),
            })
        best = pick_best()
    status = {
        "sources": sources,
        "best": {
            "lat": best["lat"], "lon": best["lon"],
            "accuracy": best.get("accuracy"),
            "source": best.get("source"),
            "fix_time": best["fix_time"],
            "zone": best.get("zone"),
        } if best else None,
        "port": config.get("port", HTTP_PORT_DEFAULT),
        "updated": time.time(),
    }
    _atomic_write(STATUS_FILE, json.dumps(status, indent=2))
    _atomic_write(FIX_FILE, json.dumps(status["best"] or {"error": "no fix"}, indent=2))


def _atomic_write(path, text):
    tmp = path.with_suffix(path.suffix + ".tmp")
    try:
        tmp.write_text(text)
        tmp.rename(path)
    except OSError as e:
        log("write error", path.name, "-", e)
        tmp.unlink(missing_ok=True)


# ---------------------------------------------------------------- server ----

class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/geolocate":
            try:
                fix = json.loads(FIX_FILE.read_text())
            except Exception:
                fix = {"error": "no fix"}
            if "lat" not in fix:
                self._send(404, {"error": "no fix"})
            else:
                self._send(200, {
                    "location": {"lat": fix["lat"], "lng": fix["lon"]},
                    "accuracy": fix.get("accuracy"),
                })
        elif self.path == "/status":
            try:
                self._send(200, json.loads(STATUS_FILE.read_text()))
            except Exception as e:
                self._send(500, {"error": str(e)})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/refresh":
            with lock:
                for st in state.values():
                    if st.get("enabled"):
                        st["last_poll"] = 0
            self._send(202, {"queued": True})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        log("http", fmt % args)


# ---------------------------------------------------------------- scheduler -

def scheduler_loop():
    while not stop_event.is_set():
        try:
            if load_config():
                rebuild_sources()
                log("config reloaded")
        except Exception as e:
            log("config reload error:", e)
        refresh_all = False  # reserved
        for src in current_sources:
            if not src["enabled"]:
                continue
            key = key_for(src)
            with lock:
                st = ensure_state(src)
                last_poll = st.get("last_poll") or 0
            if (time.time() - last_poll) < src["interval"]:
                continue
            run_poll(src)
        time.sleep(5)


def main():
    if not CONFIG_FILE.exists():
        raise SystemExit("config missing: " + str(CONFIG_FILE) + " (run scripts/install.sh first)")
    load_config()
    rebuild_sources()
    write_snapshot()
    threading.Thread(target=scheduler_loop, daemon=True).start()
    port = int(config.get("port", HTTP_PORT_DEFAULT))
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    log("listening on 127.0.0.1:" + str(port))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
