#!/bin/bash
# Jamf Pro Extension Attribute: Content Caching - Cached Updates (decoded)
# Data type: String.  Runs as root at inventory time on a Mac running content caching.
#
# The human-readable twin of ea-content-cache-macos-assets.sh: the same lines, with Apple's opaque path
# replaced by what the file is, e.g.
#   COMPLETE 9.1GB 2026-09-20 iOS 27.0 (24A437) full for iPhone17,3
#   PARTIAL 40% 12.0GB 2026-09-20 macOS 27.0 (26A428) delta from 26.7 (25G229) for all Macs (55 models)
# Labels come from /Library/Application Support/preheat/labels.json, written by admin/preheat-labels.py
# (run it on the cache server from a recurring Jamf policy). This EA makes no network calls; a file the
# labels script has not seen yet shows as "unidentified ... (labels refresh pending)".
# The raw-path EA stays the machine key; never build Smart Groups on this one.
set -u
if [[ $EUID -ne 0 ]]; then echo "<result>Must run as root</result>"; exit 0; fi
SETTINGS=$(/usr/bin/AssetCacheManagerUtil -j settings 2>/dev/null)
ACTIVATED=$(/usr/bin/AssetCacheManagerUtil isActivated 2>&1)
if [[ "$ACTIVATED" != *"is activated"* ]]; then echo "<result>Not a content cache</result>"; exit 0; fi
DATA=$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("result",{}).get("DataPath") or "")' "$SETTINGS" 2>/dev/null)
[[ -z "$DATA" ]] && DATA="/Library/Application Support/Apple/AssetCache/Data"
DB="$DATA/AssetInfo.db"
if [[ ! -f "$DB" ]]; then echo "<result>No database at $DB</result>"; exit 0; fi
W=$(/usr/bin/mktemp -d /tmp/ea-decoded.XXXXXX); trap 'rm -rf "$W"' EXIT
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
try: labels=json.load(open("/Library/Application Support/preheat/labels.json")).get("labels",{})
except Exception: labels={}
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
    uri=r.get("ZURI","")
    kind="macOS update" if "MacSoftwareUpdate" in uri else "full installer" if uri.endswith(".pkg") else "Xcode component" if ("SimulatorRuntime" in uri or "MetalToolchain" in uri) else "Aerial screen saver" if uri.startswith("/itunes-assets/Aerials") else "OS update"
    lines.append(f"{state} {total/1e9:.1f}GB {created} "+labels.get(uri, f"unidentified {kind} {os.path.basename(uri)[:12]}... (labels refresh pending)"))
print("\n".join(lines) if lines else "No OS update assets cached")
PY
)
echo "<result>${OUT}</result>"
