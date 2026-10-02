#!/bin/bash
# troubleshoot-server.sh: is this content cache registered, scoped and reachable? Read-only.
#
#   sudo bash admin/troubleshoot-server.sh
#
# Prints the server's public address, the status fields that decide whether clients can find
# it, the settings that decide which clients it serves, whether it is listening, and the
# last two hours of registration, refusal and request lines from its log. Pair it with
# troubleshoot-client.sh on a Mac that does not see the cache.
#
# What to look for:
#   Activated or Active false     the service is off (System Settings, General, Sharing, Content Caching)
#   RegistrationStatus 0          cannot reach Apple's registration service: needs outbound HTTPS to
#                                 Apple (17.0.0.0/8) with no proxy or TLS inspection in the path
#   LocalSubnetsOnly true         the default; only the server's own subnet is served. Set Clients to
#                                 "all networks" or add ranges when clients sit on other VLANs or Wi-Fi
#   Port                          random by default; fix it if a firewall or ACL is in the way
#   PublicAddress                 must equal the clients' public address
#   no "Received GET" lines       no client has asked: they never found it, or the port is blocked
set -u
case "${1:-}" in -h|--help) /usr/bin/sed -n '2,/^set -u/p' "$0" | /usr/bin/sed -e '/^set -u/d' -e 's/^# \{0,1\}//'; exit 0;; esac
if [[ $EUID -ne 0 ]]; then echo "Run with sudo for the log section: sudo bash $0"; echo; fi

echo "== Public address (must match the clients')"
/usr/bin/curl -s --max-time 5 https://api.ipify.org; echo

echo "== Status (want Activated: true, Active: true, RegistrationStatus: 1, CacheStatus: OK)"
/usr/bin/AssetCacheManagerUtil status 2>&1 | grep -E "Activated|Active:|RegistrationStatus|RegistrationError|CacheStatus|Port|PublicAddress|PrivateAddresses|StartupStatus|TotalBytes"

echo "== Settings that decide which clients it serves"
/usr/bin/AssetCacheManagerUtil settings 2>&1 | grep -E "LocalSubnetsOnly|ListenRanges|ListenRangesOnly|ListenWithPeersAndParents|Port|DataPath|PeerLocalSubnetsOnly|AllowPersonalCaching|AllowSharedCaching"

echo "== Listening?"
PORT=$(/usr/bin/AssetCacheManagerUtil status 2>&1 | awk -F': ' '/^ *Port:/{print $2}')
if [[ -n "$PORT" && "$PORT" != "0" ]]; then
  /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -3 | grep . || echo "nothing is listening on port $PORT"
else
  echo "(no port: the service is not active)"
fi

echo "== Last 2 hours of the cache log: registration, refusals, client requests"
/usr/bin/log show --last 2h --info --predicate 'subsystem == "com.apple.AssetCache"' 2>/dev/null \
  | grep -iE "regist|refus|deny|denied|public|Received GET|error" | tail -40
