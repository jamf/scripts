#!/bin/bash
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
# preheat.sh: pull the OS update assets a cache server is missing THROUGH that cache, so it is
# warm for hardware families nobody on site owns. Reads a plan written by
#   python3 admin/readiness-check.py --preheat-plan plan.json
#
# Run ON the cache server (default: talks to the local cache, finds its own GUID and port):
#   sudo bash preheat.sh plan.json
#   bash preheat.sh https://your.host/plan.json        # plan can be a URL (e.g. a Jamf policy parameter)
# Or from any Mac on the server's network:
#   bash preheat.sh plan.json --server 10.0.0.2:49152 --guid <server GUID>
# Options: --dry-run (list only)   --max-gb N (stop after N GB)   --platform mac|ios|ipados|tvos|visionos|xcode|installer|aerial
#
# Jamf policy use: script parameter 4 = plan URL, 5 = extra options; scope to the "Content Caching - Servers" Smart Group.
set -u
case "${1:-}" in -h|--help) /usr/bin/sed -n '2,/^set -u/p' "$0" | /usr/bin/sed -e '/^set -u/d' -e 's/^# \{0,1\}//'; exit 0;; esac
PLAN="${1:-${4:-}}"; shift || true
[[ "$PLAN" == "" ]] && { echo "usage: preheat.sh <plan.json or URL> [--server host:port --guid GUID] [--dry-run] [--max-gb N] [--platform p]"; exit 1; }
SERVER=""; GUID=""; DRY=0; MAXGB=0; PLAT=""
ARGS=("$@"); [[ -n "${5:-}" && "${1:-}" == "" ]] && read -ra ARGS <<< "$5"
i=0; while [[ $i -lt ${#ARGS[@]} ]]; do
  case "${ARGS[$i]}" in
    --server) SERVER="${ARGS[$((i+1))]}"; i=$((i+2));; --guid) GUID="${ARGS[$((i+1))]}"; i=$((i+2));;
    --dry-run) DRY=1; i=$((i+1));; --max-gb) MAXGB="${ARGS[$((i+1))]}"; i=$((i+2));; --platform) PLAT="${ARGS[$((i+1))]}"; i=$((i+2));;
    *) i=$((i+1));;
  esac
done
if [[ -z "$SERVER" ]]; then   # running on the cache server itself
  ST=$(/usr/bin/AssetCacheManagerUtil -j status 2>/dev/null)
  PORT=$(/usr/bin/python3 -c 'import json,sys; r=json.loads(sys.argv[1])["result"]; print(r.get("Port") or 0)' "$ST")
  [[ -z "$GUID" ]] && GUID=$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.argv[1])["result"].get("ServerGUID",""))' "$ST")
  [[ "$PORT" == "0" || -z "$GUID" ]] && { echo "content caching is not active here and no --server/--guid given"; exit 1; }
  SERVER="localhost:$PORT"
fi
W=$(/usr/bin/mktemp -d /tmp/preheat.XXXXXX); trap 'rm -rf "$W"' EXIT
if [[ "$PLAN" == http* ]]; then /usr/bin/curl -sf -m 60 -o "$W/plan.json" "$PLAN" || { echo "cannot fetch plan $PLAN"; exit 1; }; PLAN="$W/plan.json"; fi
/usr/bin/python3 - "$PLAN" "$GUID" "$PLAT" > "$W/list" <<'PY'
import json,sys,urllib.parse
plan=json.load(open(sys.argv[1])); guid=sys.argv[2].upper(); plat=sys.argv[3]
seen=set()
for a in plan.get("assets",[]):
    if a.get("server_guid","").upper()!=guid: continue
    if plat and a.get("platform")!=plat: continue
    u=urllib.parse.urlparse(a["url"])
    if a["url"] in seen: continue
    seen.add(a["url"])
    print(f"{a['size']}\t{u.hostname}\t{u.path}\t{a['platform']} {a['model']} {a['from_version']}->{a['to_version']}")
PY
N=$(wc -l < "$W/list" | tr -d ' '); TOTAL=$(awk -F'\t' '{s+=$1} END{printf "%.1f", s/1e9}' "$W/list")
echo "server $SERVER guid $GUID: $N asset(s), $TOTAL GB to pull"
[[ "$N" == "0" ]] && exit 0
DONE_GB=0; FAILED=0
while IFS=$'\t' read -r SIZE HOST PATHP LABEL; do
  GB=$(awk -v b="$SIZE" 'BEGIN{printf "%.1f", b/1e9}')
  if [[ "$MAXGB" != "0" ]] && awk -v d="$DONE_GB" -v g="$GB" -v m="$MAXGB" 'BEGIN{exit !(d+g>m)}'; then echo "skip  $LABEL ($GB GB): --max-gb $MAXGB reached"; continue; fi
  if [[ $DRY == 1 ]]; then echo "would pull  $LABEL ($GB GB)  $HOST$PATHP"; continue; fi
  printf 'pull  %s (%s GB) ... ' "$LABEL" "$GB"
  # "HTTP 200" only says the download started. curl's own exit status says whether every byte arrived
  # (18 = the connection closed early), and a second request picks up where the cache left off.
  TRY=0; OK=0
  while [[ $TRY -lt 3 ]]; do
    TRY=$((TRY+1))
    OUT=$(/usr/bin/curl -s -m 14400 -o /dev/null -w '%{http_code} %{size_download}' "http://$SERVER$PATHP?source=$HOST&sourceScheme=https"); RC=$?
    CODE=${OUT%% *}; GOT=${OUT##* }
    if [[ $RC -eq 0 && "$CODE" == "200" ]]; then OK=1; break; fi
    [[ "$CODE" != "200" && "$CODE" != "000" ]] && break      # the cache answered with an error: asking again will not help
    sleep 5
  done
  if [[ $OK == 1 ]]; then
    echo "HTTP 200$([[ $TRY -gt 1 ]] && echo " (complete on attempt $TRY)")"
    DONE_GB=$(awk -v d="$DONE_GB" -v g="$GB" 'BEGIN{printf "%.1f", d+g}')
  else
    echo "INCOMPLETE: HTTP $CODE, curl error $RC, $(awk -v b="${GOT:-0}" 'BEGIN{printf "%.1f", b/1e9}') GB received after $TRY attempt(s)"
    FAILED=$((FAILED+1))
  fi
done < "$W/list"
echo "pulled $DONE_GB GB through $SERVER; run a Jamf inventory update on the server to refresh its assets EA"
if [[ $FAILED -gt 0 ]]; then echo "$FAILED file(s) did not arrive whole. Run the same plan again: the cache keeps what it has and fetches the rest."; exit 1; fi
