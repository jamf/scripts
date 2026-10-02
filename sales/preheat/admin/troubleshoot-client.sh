#!/bin/bash
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
# troubleshoot-client.sh: why does this Mac not see the content cache? Read-only; no root needed.
#
#   bash admin/troubleshoot-client.sh [server LAN address] [port]
#
# Prints this Mac's public address, what Apple's locator returns for it, whether the
# server's port answers (when the address and port are given), and any tunnel that could
# change the route. Pair it with troubleshoot-server.sh on the caching Mac.
#
# Read the public address first: if it differs from the server's, nothing else matters until
# the two leave for the internet from the same place. "Found 0 content caches" with a matching
# address means Apple has no registration for it (check the server). "Found 1" with the port
# BLOCKED means a firewall, an ACL between VLANs or client isolation on the Wi-Fi network.
# A client remembers a located result for about an hour; this script always asks afresh.
set -u
case "${1:-}" in -h|--help) /usr/bin/sed -n '2,/^set -u/p' "$0" | /usr/bin/sed -e '/^set -u/d' -e 's/^# \{0,1\}//'; exit 0;; esac

SERVER="${1:-}"; PORT="${2:-}"

echo "== Public address (must match the server's)"
/usr/bin/curl -s --max-time 5 https://api.ipify.org; echo

echo "== What Apple's locator returns for this Mac (fresh answer, shared caching)"
/usr/bin/AssetCacheLocatorUtil 2>&1 | awk '
  /public IP address is/ {print; next}
  /^--- Information for/ {print; next}
  /Finding refreshed content caches supporting shared caching/ {want=1; next}
  want && /Found [0-9]+ content cache/ {print "  " $0; want=0; grab=1; next}
  grab && /rank/ {print "  " $0; next}
  {grab=0}'

echo "== Can this Mac reach the server's port?"
if [[ -n "$SERVER" && -n "$PORT" ]]; then
  if /usr/bin/nc -z -w 3 "$SERVER" "$PORT" 2>/dev/null; then
    echo "port $PORT on $SERVER: open"
  else
    echo "port $PORT on $SERVER: BLOCKED or wrong"
  fi
  /usr/bin/curl -s -o /dev/null -w "HTTP %{http_code} from http://$SERVER:$PORT/ (any code means the cache answered; 400 is normal here)\n" --max-time 5 "http://$SERVER:$PORT/"
else
  echo "(pass the server's address and port to test reachability)"
fi

echo "== Tunnels, VPN and filters on this Mac"
/usr/bin/scutil --nc list 2>/dev/null | grep -i "connected" || echo "no VPN configuration is connected"
/sbin/ifconfig | awk '/^(utun|ipsec|ppp)/ {ifc=$1} /inet / && ifc {print "  " ifc " has an address: " $2; ifc=""}'
echo "(a connected VPN or a ZTNA agent can change the public address or the route to the server)"
