#!/bin/bash
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
# Jamf Pro Extension Attribute: Content Caching - Status
# Data type: String.  Runs as root at inventory time.
# Values:  "Not a content cache"
#        | "Active; guid <GUID>; ip 10.0.0.2; port 49152; public 203.0.113.5; free 511 GB; used 18.4 GB; status OK"
#        | "Inactive (<reason>); guid <GUID>"      caching is on and not serving: not registered, suspended, LOWSPACE
#        | "Inactive (LOWSPACE; caching switched itself off); guid <GUID>"      its storage volume is missing, renamed or full
# First word is the contract for Smart Groups: Active, Inactive, Not.
# Jamf collects the same facts on its own (the Content Caching section of the inventory record), but with a command it
# sends just after inventory, so a Smart Group on Jamf's criteria is one inventory behind. This EA is worked out during
# inventory: the groups that raise alerts are built on it. The admin scripts read Jamf's section and DDM as well.
# The guid is what client Macs report in "Content Caching - Servers Found", so the two can be joined.
J=$(/usr/bin/AssetCacheManagerUtil -j status 2>/dev/null)
if [[ -z "$J" ]]; then echo "<result>Unknown (AssetCacheManagerUtil failed)</result>"; exit 0; fi
OUT=$(/usr/bin/python3 - "$J" <<'PY'
import json,sys
r=json.loads(sys.argv[1]).get("result",{})
gb=lambda b: f"{(b or 0)/1e9:.1f} GB"
guid=r.get("ServerGUID") or "?"
if not r.get("Activated"):
    # A Mac that never was a cache reports status OK. One whose storage vanished switches itself off and reports a problem.
    st=r.get("CacheStatus") or "OK"
    print("Not a content cache" if st=="OK" else f"Inactive ({st}; caching switched itself off); guid {guid}"); sys.exit()
if not r.get("Active"):
    why="; ".join(x for x in (r.get("CacheStatus") or "?", r.get("RegistrationError") or r.get("StartupStatus") or "") if x and x!="OK") or "not running"
    print(f"Inactive ({why}); guid {guid}"); sys.exit()
ips=",".join(r.get("PrivateAddresses") or []) or "?"
print(f"Active; guid {r.get('ServerGUID','?')}; ip {ips}; port {r.get('Port') or '?'}; public {r.get('PublicAddress') or '?'}; free {gb(r.get('CacheFree'))}; used {gb(r.get('ActualCacheUsed', r.get('CacheUsed')))}; status {r.get('CacheStatus')}")
PY
)
echo "<result>${OUT:-Unknown}</result>"
