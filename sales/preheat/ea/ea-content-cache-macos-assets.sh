#!/bin/bash
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
# Jamf Pro Extension Attribute: Content Caching - macOS Assets
# Data type: String.  Runs as root at inventory time on a Mac running content caching.
#
# One line per cached OS update / installer asset (macOS, and iOS/iPadOS/tvOS/visionOS/watchOS OTA), plus Xcode
# simulator runtimes and Metal toolchains:
#   <COMPLETE|PARTIAL nn%> <size GB> <created yyyy-mm-dd> <path>
# Path is the origin URL path with no host, exactly as the cache stores it, e.g.
#   /content/downloads/52/44/142-16670-A_.../InstallAssistant.pkg           (full installer, Intel + Apple silicon)
#   /2026FallFCS/<uuid>/com_apple_MobileAsset_MacSoftwareUpdate/<sha1>.zip    (Apple silicon macOS OTA update)
#   /2026FallFCS/<uuid>/com_apple_MobileAsset_SoftwareUpdate/<sha1>.zip|.aea   (iOS/iPadOS/tvOS/visionOS/watchOS OTA)
# Values: "Not a content cache" | "No macOS assets cached" | the list above.
set -u
if [[ $EUID -ne 0 ]]; then echo "<result>Must run as root</result>"; exit 0; fi
SETTINGS=$(/usr/bin/AssetCacheManagerUtil -j settings 2>/dev/null)
ACTIVATED=$(/usr/bin/AssetCacheManagerUtil isActivated 2>&1)
if [[ "$ACTIVATED" != *"is activated"* ]]; then echo "<result>Not a content cache</result>"; exit 0; fi
DATA=$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("result",{}).get("DataPath") or "")' "$SETTINGS" 2>/dev/null)
[[ -z "$DATA" ]] && DATA="/Library/Application Support/Apple/AssetCache/Data"
DB="$DATA/AssetInfo.db"
if [[ ! -f "$DB" ]]; then echo "<result>No database at $DB</result>"; exit 0; fi
W=$(/usr/bin/mktemp -d /tmp/ea-cache.XXXXXX); trap 'rm -rf "$W"' EXIT
/bin/cp "$DB" "$W/db"; [[ -f "$DB-wal" ]] && /bin/cp "$DB-wal" "$W/db-wal"; [[ -f "$DB-shm" ]] && /bin/cp "$DB-shm" "$W/db-shm"
ROWS=$(/usr/bin/sqlite3 -readonly -json "$W/db" "
  select ZGUID, ZTOTALBYTES, ZCREATIONDATE, ZURI from ZASSET
  where ZURI like '%/InstallAssistant.pkg'
     or ZURI like '%com_apple_MobileAsset_MacSoftwareUpdate/%'
     or ZURI like '%com_apple_MobileAsset_SoftwareUpdate/%'
     or ZURI like '%SimulatorRuntime/%'
     or ZURI like '%com_apple_MobileAsset_MetalToolchain/%'
     or ZURI like '/itunes-assets/Aerials%'
     or ZURI like '%.ipsw'
     or ZURI like '%macOSUpd%.pkg'
  order by ZCREATIONDATE desc;" 2>/dev/null)
OUT=$(/usr/bin/python3 - "$DATA" "${ROWS:-[]}" <<'PY'
import json,sys,os,datetime
data=sys.argv[1]; rows=json.loads(sys.argv[2] or "[]")
lines=[]
for r in rows:
    total=r.get("ZTOTALBYTES") or 0; guid=r.get("ZGUID") or ""
    ondisk=0; d=os.path.join(data,guid)
    if guid and os.path.isdir(d):
        for root,_,fs in os.walk(d):
            for f in fs:
                try: ondisk+=os.path.getsize(os.path.join(root,f))
                except OSError: pass
    if total and ondisk>=total: state="COMPLETE"
    else: state=f"PARTIAL {100*ondisk/total:.0f}%" if total else "PARTIAL"
    created=datetime.datetime.fromtimestamp((r.get("ZCREATIONDATE") or 0)+978307200, datetime.timezone.utc).strftime("%Y-%m-%d")
    lines.append(f"{state} {total/1e9:.1f}GB {created} {r.get('ZURI','')}")
print("\n".join(lines) if lines else "No OS update assets cached")
PY
)
echo "<result>${OUT}</result>"
