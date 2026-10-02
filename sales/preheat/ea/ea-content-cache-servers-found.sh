#!/bin/bash
# Jamf Pro Extension Attribute: Content Caching - Servers Found
# Data type: String.  Runs on every Mac.
# Asks macOS which content caches THIS Mac would use for shared content (OS updates, apps),
# and remembers every server seen in the last STICKY_DAYS so a Mac that goes home for a week
# still counts as served by its office's cache.
# One line per server:
#   <server GUID> <host:port> healthy|unhealthy reachable|unreachable [favored]   (found right now)
#   <server GUID> <host:port> last-seen YYYY-MM-DD                                 (seen within STICKY_DAYS)
# "favored" = this network's DNS names that cache as one to prefer (Apple's fss TXT record): while it is up, this Mac uses no other.
# Where the network's DNS has Apple's content caching TXT records (_aaplcache._tcp), one more line, last:
#   dns: public <ranges>; favored <ranges>
# "public" is every public address the site reaches the internet from; the admin script uses it to match
# iPhones and iPads, which cannot run this, to the site's caches.
# Values: exactly "None found" when nothing has been seen within the window.
# The GUID matches the Server GUID in the Content Caching section of the cache server's inventory record.
STICKY_DAYS=90
STATE_DIR="/Library/Application Support/preheat"
[[ -w "/Library/Application Support" || -d "$STATE_DIR" ]] || STATE_DIR="${TMPDIR:-/tmp}/preheat"   # non-root test runs
/bin/mkdir -p "$STATE_DIR" 2>/dev/null
J=$(/usr/bin/AssetCacheLocatorUtil -j 2>/dev/null)
OUT=$(/usr/bin/python3 - "$J" "$STATE_DIR/servers-seen.json" "$STICKY_DAYS" <<'PY'
import json, sys, datetime, os, re
raw, state_path, days = sys.argv[1], sys.argv[2], int(sys.argv[3])
today = datetime.date.today()
try: state = json.load(open(state_path))
except Exception: state = {}
try: d = json.loads(raw)
except Exception: d = {}
res = d.get("results", {}); sysr = res.get("system", {})
servers = (sysr.get("refreshed servers") or sysr.get("saved servers") or {}).get("shared caching") or []
reach = set(res.get("reachability") or [])
now = {}
for s in servers:
    g = s.get("guid") or "?"; hp = s.get("hostport", "")
    now[g] = f"{g} {hp} {'healthy' if s.get('healthy') else 'unhealthy'} {'reachable' if hp in reach else 'unreachable'}" + (" favored" if s.get("favored") else "")
    state[g] = {"hostport": hp, "last_seen": today.isoformat()}
lines = list(now.values())
for g, e in sorted(state.items()):
    try: seen = datetime.date.fromisoformat(e.get("last_seen", ""))
    except ValueError: continue
    if (today - seen).days > days: continue
    if g not in now: lines.append(f"{g} {e.get('hostport','')} last-seen {seen.isoformat()}")
state = {g: e for g, e in state.items() if e.get("last_seen", "") >= (today - datetime.timedelta(days=days)).isoformat()}
try: json.dump(state, open(state_path, "w"))
except Exception: pass
def ranges(v):
    """The tool's range lists, whatever their nesting, as 'a-b,c'."""
    ip = lambda x: isinstance(x, str) and re.fullmatch(r"[0-9A-Fa-f.:]+(-[0-9A-Fa-f.:]+)?(/\d+)?", x.strip())
    out = []
    def walk(x):
        if ip(x): out.append(x.strip())
        elif isinstance(x, dict):
            first = next((x[k] for k in ("first", "start", "low", "begin", "from") if ip(x.get(k))), None)
            last = next((x[k] for k in ("last", "end", "high", "to") if ip(x.get(k))), None)
            if first: out.append(first if not last or last == first else f"{first}-{last}")
            else:
                for val in x.values(): walk(val)
        elif isinstance(x, (list, tuple)):
            if len(x) == 2 and all(ip(i) and "-" not in i for i in x): out.append(f"{x[0]}-{x[1]}" if x[0] != x[1] else x[0])
            else:
                for i in x: walk(i)
    walk(v)
    return ",".join(dict.fromkeys(out))
pub = ranges(sysr.get("refreshed public IP address ranges")) or ranges(sysr.get("saved public IP address ranges"))
fav = ranges(sysr.get("refreshed favored server ranges")) or ranges(sysr.get("saved favored server ranges"))
if lines and (pub or fav):
    lines.append("dns: " + "; ".join(x for x in (f"public {pub}" if pub else "", f"favored {fav}" if fav else "") if x))
print("\n".join(lines) if lines else "None found")
PY
)
echo "<result>${OUT:-Unknown}</result>"
