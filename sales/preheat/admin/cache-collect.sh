#!/bin/bash
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
# cache-collect.sh  --  READ-ONLY inspection of an Apple content caching server.
#
# Purpose: gather everything needed to design a Jamf Pro Extension Attribute that
# reports which macOS updates are cached. Makes NO changes: the cache database is
# copied to a temp folder before it is queried, and the service is never touched.
#
# Run on the caching Mac:   sudo bash admin/cache-collect.sh
# Output: /Users/Shared/cache-report-<date>.txt  (plus a .json of macOS-update rows)

set -u
case "${1:-}" in -h|--help) /usr/bin/sed -n '2,/^set -u/p' "$0" | /usr/bin/sed -e '/^set -u/d' -e 's/^# \{0,1\}//'; exit 0;; esac
if [[ $EUID -ne 0 ]]; then echo "Run with sudo: sudo bash $0"; exit 1; fi

STAMP=$(date +%Y%m%d-%H%M%S)
REPORT="/Users/Shared/cache-report-$STAMP.txt"
JSON="/Users/Shared/cache-macos-assets-$STAMP.json"
WORK=$(mktemp -d /tmp/cache-collect.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

exec > >(tee "$REPORT") 2>&1
section(){ printf '\n\n===== %s =====\n' "$1"; }

section "SYSTEM"
sw_vers
echo "model:     $(sysctl -n hw.model)"
echo "board id:  $(sysctl -n hw.target)"
echo "uptime:    $(uptime)"
echo "hostname:  $(scutil --get LocalHostName 2>/dev/null)"

section "CONTENT CACHE STATUS (AssetCacheManagerUtil status)"
AssetCacheManagerUtil status 2>&1

section "CONTENT CACHE STATUS JSON"
AssetCacheManagerUtil -j status 2>&1

section "CONTENT CACHE SETTINGS JSON"
SETTINGS_JSON=$(AssetCacheManagerUtil -j settings 2>&1)
echo "$SETTINGS_JSON"

section "LAUNCHD SERVICE STATE"
launchctl print system/com.apple.AssetCache 2>&1 | head -40
echo "--- processes ---"
pgrep -lf AssetCache 2>&1

# ---- locate the data folder (default or custom DataPath) ----
DATA_PATH=$(echo "$SETTINGS_JSON" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); r=d.get("result",d)
    print(r.get("DataPath") or "")
except Exception: print("")' 2>/dev/null)
[[ -z "$DATA_PATH" ]] && DATA_PATH="/Library/Application Support/Apple/AssetCache/Data"
DB="$DATA_PATH/AssetInfo.db"

section "DATA FOLDER: $DATA_PATH"
ls -la "$DATA_PATH" 2>&1 | head -40
echo "--- disk usage of data folder ---"
du -sh "$DATA_PATH" 2>&1
echo "--- largest 25 files under data folder ---"
find "$DATA_PATH" -type f -size +100M -exec ls -l {} \; 2>/dev/null | sort -k5 -n -r | head -25

if [[ ! -f "$DB" ]]; then
  echo "AssetInfo.db not found at $DB -- stopping database section."
else
  # ---- copy DB (and WAL/SHM if present) so we never touch the live file ----
  cp "$DB" "$WORK/AssetInfo.db"
  [[ -f "$DB-wal" ]] && cp "$DB-wal" "$WORK/AssetInfo.db-wal"
  [[ -f "$DB-shm" ]] && cp "$DB-shm" "$WORK/AssetInfo.db-shm"
  Q(){ sqlite3 -readonly "$WORK/AssetInfo.db" "$@"; }

  section "DATABASE SCHEMA"
  Q ".schema"

  section "ZASSET COLUMNS"
  Q -header -column "PRAGMA table_info(ZASSET);"

  section "ROW COUNTS PER TABLE"
  for t in $(Q "select name from sqlite_master where type='table';"); do
    printf '%-20s %s\n' "$t" "$(Q "select count(*) from $t;")"
  done

  section "ASSET SUMMARY BY URI PREFIX (first 2 path components)"
  Q -header -column "
    select substr(ZURI,1,instr(substr(ZURI,2),'/')+1) as prefix,
           count(*) as n,
           round(sum(ZTOTALBYTES)/1073741824.0,2) as GB
    from ZASSET group by prefix order by GB desc limit 40;"

  section "ASSET SUMMARY BY FILE EXTENSION"
  Q -header -column "
    select case when instr(ZURI,'.')=0 then '(none)' else lower(replace(ZURI, rtrim(ZURI, replace(ZURI,'.','')), '')) end as ext,
           count(*) as n, round(sum(ZTOTALBYTES)/1073741824.0,2) as GB
    from ZASSET group by ext order by GB desc limit 30;"

  section "SAMPLE OF 15 URIS (to see exact format)"
  Q "select ZURI from ZASSET order by ZTOTALBYTES desc limit 15;"

  section "macOS UPDATE CANDIDATES (all columns, line mode)"
  MATCH="ZURI like '%MacSoftwareUpdate%' or ZURI like '%InstallAssistant%' or ZURI like '%.ipsw%' or ZURI like '%macOSUpd%' or ZURI like '%SoftwareUpdate%' or ZURI like '%.aea%' or ZURI like '%FCS/%'"
  Q -header -line "select *,
        datetime(ZCREATIONDATE + 978307200,'unixepoch') as created_utc,
        datetime(ZLASTACCESSED + 978307200,'unixepoch') as last_accessed_utc
      from ZASSET where $MATCH order by ZTOTALBYTES desc;"

  section "macOS UPDATE CANDIDATES (compact)"
  Q -header -column "select round(ZTOTALBYTES/1073741824.0,2) as GB,
        datetime(ZCREATIONDATE + 978307200,'unixepoch') as created_utc,
        ZURI
      from ZASSET where $MATCH order by ZTOTALBYTES desc;"

  section "ON-DISK SIZE CHECK FOR CANDIDATES (is the file fully present?)"
  # Try to relate DB rows to files on disk by GUID / checksum-looking columns.
  Q -json "select * from ZASSET where $MATCH;" > "$JSON"
  [[ -s "$JSON" ]] || echo "[]" > "$JSON"
  echo "JSON written to $JSON ($(python3 -c "import json;print(len(json.load(open('$JSON'))))") rows)"
  python3 - "$JSON" "$DATA_PATH" <<'PY'
import json,sys,os
rows=json.load(open(sys.argv[1])); data=sys.argv[2]
# Layout learned 2026-09-17: each asset's bytes live in  <DataPath>/<ZGUID>/<chunk files>
for r in rows:
    uri=r.get("ZURI",""); total=r.get("ZTOTALBYTES") or 0; guid=r.get("ZGUID") or ""
    d=os.path.join(data,guid); ondisk=0; files=0
    if guid and os.path.isdir(d):
        for root,_,fs in os.walk(d):
            for f in fs:
                try: ondisk+=os.path.getsize(os.path.join(root,f)); files+=1
                except OSError: pass
    pct=(100.0*ondisk/total) if total else 0
    state="COMPLETE" if total and ondisk>=total else ("PARTIAL" if ondisk else "NO DATA ON DISK")
    print(f"\n{uri}\n  guid={guid} files={files} ondisk={ondisk} total={total} ({pct:.1f}%) -> {state}")
    print(f"  ZMD5OFFSET={r.get('ZMD5OFFSET')} ZCHECKSUM={r.get('ZCHECKSUM')!r}")
PY

  section "OTHER TABLES (first 20 rows each, may explain completeness/state)"
  for t in $(Q "select name from sqlite_master where type='table' and name not in ('ZASSET');"); do
    echo "--- $t ---"; Q -header -column "select * from $t limit 20;"
  done
fi

section "RECENT CONTENT CACHE LOG (last 30 min, errors/faults + status summaries)"
log show --last 30m --predicate 'subsystem == "com.apple.AssetCache"' --style compact 2>/dev/null \
  | grep -Ei 'error|fault|fail|shut|deactivat|activat|start|stopp|status|registration' | tail -80

section "RECENT MACOS UPDATE REQUESTS SEEN BY THE CACHE (last 24h, if any)"
log show --last 24h --predicate 'subsystem == "com.apple.AssetCache"' --style compact 2>/dev/null \
  | grep -Ei 'MacSoftwareUpdate|InstallAssistant|ipsw|\.zip|\.aea|FCS' | tail -40

section "DONE"
echo "Report: $REPORT"
echo "JSON:   $JSON"
