#!/bin/bash
# Jamf Pro Extension Attribute: Content Caching - Effectiveness
# Data type: String.  Runs at inventory time on a Mac running content caching. No network calls.
#
# Is this cache earning its keep? From the cache's own counters: of everything it delivered to devices, how much did
# NOT have to be downloaded from Apple. A cache that serves each file once saves nothing; a busy healthy one serves
# each file many times.
#   GOOD 87% from cache; served 1840.2 GB, fetched from Apple 239.1 GB, saved 1601.1 GB since 2026-06-01; holds iCloud 8.9 GB, iOS 0.7 GB, Mac 18.5 GB, other 47.3 GB; pressure 0.2
# First word is the contract for Smart Groups:  GOOD (70% or more)  FAIR (30 to 69%)  LOW (under 30%)
#   NEW = under 10 GB delivered since the counters started, too little to judge.
#   WIPED = the cache lost more than 90% of its content between two inventory updates. Content caching deletes
#     everything about two minutes after a failed registration with Apple (a VPN on the server, blocked egress, a changed
#     public IP), and then carries on looking healthy. Shown first for 3 days, with the date and how much was lost:
#       WIPED 2026-09-20 (held 499.4 GB); NEW 0% from cache; served ...
#     Remembered in /Library/Application Support/preheat/cache-state.json (this EA runs as root at inventory time).
# "since" is when the counters last reset (the cache restarts them when it is reset or flushed, and when the Mac restarts).
# "pressure" is the cache's own MaxCachePressureLast1Hour: near 1 means it is evicting content to make room.
# Values: "Not a content cache" | "Inactive" | the line above.
J=$(/usr/bin/AssetCacheManagerUtil -j status 2>/dev/null)
if [[ -z "$J" ]]; then echo "<result>Unknown (AssetCacheManagerUtil failed)</result>"; exit 0; fi
OUT=$(/usr/bin/python3 - "$J" <<'PY'
import json,sys,os,datetime
r=json.loads(sys.argv[1]).get("result",{})
if not r.get("Activated"): print("Not a content cache"); sys.exit()
STATE="/Library/Application Support/preheat/cache-state.json"; WIPED_DAYS=3
try: st=json.load(open(STATE))
except Exception: st={}
used_now=r.get("ActualCacheUsed", r.get("CacheUsed")) or 0; today=datetime.date.today()
prev=st.get("used") or 0
if prev>=5e9 and used_now<prev*0.1: st["wiped"]={"on":today.isoformat(),"lost":prev}      # eviction never takes 90% at once
st["used"]=used_now; st["since"]=r.get("TotalBytesAreSince")
try:
    os.makedirs(os.path.dirname(STATE),exist_ok=True); json.dump(st,open(STATE,"w"))
except Exception: pass
w=st.get("wiped") or {}
wiped=""
try:
    if w and (today-datetime.date.fromisoformat(w["on"])).days<=WIPED_DAYS: wiped=f"WIPED {w['on']} (held {w['lost']/1e9:.1f} GB); "
except Exception: pass
if not r.get("Active"): print(f"{wiped}Inactive"); sys.exit()
gb=lambda b: f"{(b or 0)/1e9:.1f} GB"
served=sum(r.get(k) or 0 for k in ("TotalBytesReturnedToClients","TotalBytesReturnedToChildren","TotalBytesReturnedToPeers"))
fetched=r.get("TotalBytesStoredFromOrigin") or 0
since=(r.get("TotalBytesAreSince") or "?")[:10]
try: since=datetime.datetime.strptime(r["TotalBytesAreSince"],"%Y-%m-%d %H:%M:%S %z").astimezone().date().isoformat()   # the cache reports UTC; WIPED uses the local date
except Exception: pass
pct=max(0,round(100*(1-fetched/served))) if served else 0
grade="NEW" if served<10e9 else "GOOD" if pct>=70 else "FAIR" if pct>=30 else "LOW"
d=r.get("CacheDetails") or {}
known={"iCloud":"iCloud","iOS Software":"iOS","Mac Software":"Mac"}
holds=", ".join(f"{lbl} {gb(d.get(k))}" for k,lbl in known.items() if d.get(k))
other=sum(v for k,v in d.items() if k not in known)
if other: holds=(holds+", " if holds else "")+f"other {gb(other)}"
print(f"{wiped}{grade} {pct}% from cache; served {gb(served)}, fetched from Apple {gb(fetched)}, saved {gb(max(0,served-fetched))} since {since}; holds {holds or 'nothing'}; pressure {r.get('MaxCachePressureLast1Hour','?')}")
PY
)
echo "<result>${OUT:-Unknown}</result>"
