#!/usr/bin/env python3
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
"""
Create the Smart Computer Groups this project recommends, skipping any that already exist.
Needs API client privileges: Read / Create Smart Computer Groups.
Credentials: login keychain (readiness-check.py --store-credentials) or env JAMF_URL, JAMF_CLIENT_ID, JAMF_CLIENT_SECRET.
Usage: python3 admin/create-smart-groups.py [--dry-run] [--update]
       python3 admin/create-smart-groups.py --served-by "Office X" <server GUID>   # add a per-office group
"""
import os, sys, json, urllib.error, argparse
sys.path.insert(0, os.path.dirname(__file__)); rc = __import__("readiness-check")


def crit(name, search, value, and_or="and", prio=0):
    return {"name": name, "searchType": search, "value": value, "andOr": and_or, "priority": prio,
            "openingParen": False, "closingParen": False}

GROUPS = [
    ("Content Caching - Servers", "Macs running Apple content caching, serving or not (status EA starts with Active or Inactive).",
     [crit(rc.EA_STATUS, "like", "Active")]),
    ("Content Caching - Ready for OS push", "Cache servers whose local devices' next OS update is fully cached (readiness EA READY).",
     [crit(rc.EA_READY, "like", "READY"), crit(rc.EA_READY, "not like", "NOT READY", "and", 1)]),
    ("Content Caching - Partially ready", "Cache servers with some, not all, needed OS assets cached.",
     [crit(rc.EA_READY, "like", "PARTIAL")]),
    ("Content Caching - Not ready", "Cache servers missing every needed OS asset.",
     [crit(rc.EA_READY, "like", "NOT READY")]),
    ("Content Caching - Inactive or broken", "Caching turned on but not serving (registration failed, low space, data path missing).",
     [crit(rc.EA_STATUS, "like", "Inactive")]),
    ("Content Caching - Low on space", "Caches that report LOWSPACE: the cache volume is nearly full, missing or renamed. A cache that loses its volume switches itself off, and still shows here.",
     [crit(rc.EA_STATUS, "like", "LOWSPACE")]),
    ("Content Caching - Low benefit", "Cache servers that re-serve under 30% of what they download: few devices use them, or devices cannot reach them (VPN, wrong network).",
     [crit(rc.EA_EFFECT, "like", "LOW ")]),
    ("Content Caching - Wiped recently", "Cache servers that lost more than 90% of their content in the last 3 days: almost always a failed registration with Apple (VPN on the server, blocked egress, changed public IP).",
     [crit(rc.EA_EFFECT, "like", "WIPED ")]),
    ("Macs with no content cache", "Macs that will download OS updates straight from Apple (locator found no cache).",
     [crit(rc.EA_FOUND, "is", "None found")]),
]

MOBILE_GROUPS = [
    ("Mobile devices with no content cache", "iPads, iPhones and Apple TVs that will download OS updates straight from Apple.",
     [crit(rc.EA_MOBILE_SERVER, "is", "None found")]),
]

def create_mobile(j, groups, dry):
    try:
        existing = {g["groupName"] for g in j.call("/api/v2/mobile-device-groups/smart-groups?page=0&page-size=1000").get("results", [])}
    except urllib.error.HTTPError as e:
        print(f"mobile groups skipped (HTTP {e.code}; needs Read Smart Mobile Device Groups)"); return
    for name, desc, criteria in groups:
        if name in existing: print(f"exists:  {name}"); continue
        body = {"groupName": name, "groupDescription": desc, "criteria": criteria, "siteId": "-1"}
        if dry: print(f"would create (mobile): {name}"); continue
        for path in ("/api/v2/mobile-device-groups/smart-groups", "/api/v1/mobile-device-groups/smart-groups"):
            try: j.call(path, "POST", body); print(f"created: {name} (mobile)"); break
            except urllib.error.HTTPError as e:
                if path.endswith("v1/mobile-device-groups/smart-groups") or e.code != 404:
                    print(f"FAILED:  {name}: HTTP {e.code} {e.read().decode()[:200]}"); break

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="print what would be created or updated")
    ap.add_argument("--update", action="store_true", help="also bring existing groups of these names to the rules in this script (for installations made before a rule changed)")
    ap.add_argument("--served-by", nargs=2, metavar=("LABEL", "GUID"), help="also create 'Macs served by <LABEL> cache' for that server GUID")
    args = ap.parse_args()
    groups = list(GROUPS)
    mobile_groups = list(MOBILE_GROUPS)
    if args.served_by:
        label, guid = args.served_by
        groups.append((f"Macs served by {label} cache", f"Macs whose locator reports cache server {guid}.",
                       [crit(rc.EA_FOUND, "like", guid)]))
        mobile_groups.append((f"Mobile devices served by {label} cache", f"Mobile devices matched (by public IP) to cache server {guid}.",
                              [crit(rc.EA_MOBILE_SERVER, "like", guid)]))
    j = rc.jamf_from_credentials()
    try:
        existing = {g["name"]: g["id"] for g in j.call("/api/v2/computer-groups/smart-groups?page=0&page-size=1000").get("results", [])}
    except urllib.error.HTTPError as e:
        sys.exit(f"cannot list smart groups (HTTP {e.code}); the API client needs Read Smart Computer Groups")
    rule = lambda cs: [(c["name"], c["searchType"], (c["value"] or "").strip(), (c.get("andOr") or "and").lower()) for c in cs]      # Jamf trims values when a group is saved by hand
    for name, desc, criteria in groups:
        if name in existing:
            if not args.update: print(f"exists:  {name}"); continue
            try:
                cur = j.call(f"/api/v2/computer-groups/smart-groups/{existing[name]}")
                if rule(cur.get("criteria") or []) == rule(criteria): print(f"exists:  {name} (rule is current)"); continue
                if args.dry_run: print(f"would update: {name}\n   from {json.dumps(rule(cur.get('criteria') or []))}\n   to   {json.dumps(rule(criteria))}"); continue
                j.call(f"/api/v2/computer-groups/smart-groups/{existing[name]}", "PUT", {"name": name, "description": desc, "criteria": criteria, "siteId": str(cur.get("siteId") or "-1")})
                print(f"updated: {name}")
            except urllib.error.HTTPError as e: print(f"FAILED:  {name}: HTTP {e.code} {e.read().decode()[:200]} (updating needs Update Smart Computer Groups)")
            continue
        body = {"name": name, "description": desc, "criteria": criteria, "siteId": "-1"}
        if args.dry_run: print(f"would create: {name}\n   {json.dumps(criteria)}"); continue
        try: j.call("/api/v2/computer-groups/smart-groups", "POST", body); print(f"created: {name}")
        except urllib.error.HTTPError as e: print(f"FAILED:  {name}: HTTP {e.code} {e.read().decode()[:200]}")
    create_mobile(j, mobile_groups, args.dry_run)

if __name__ == "__main__": main()
