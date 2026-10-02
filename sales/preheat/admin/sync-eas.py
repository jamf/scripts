#!/usr/bin/env python3
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
"""
Push the EA scripts in ea/ into their Jamf Pro computer extension attribute definitions.
Jamf runs the script text stored in the EA, so after editing a file here, run this.
Needs the API client privilege "Update Computer Extension Attributes" (and "Create ..." to add missing ones).
Credentials: login keychain (readiness-check.py --store-credentials) or env JAMF_URL, JAMF_CLIENT_ID, JAMF_CLIENT_SECRET.   Usage: python3 admin/sync-eas.py [--create]
"""
import os, sys, json, urllib.error, argparse
sys.path.insert(0, os.path.dirname(__file__)); rc = __import__("readiness-check")
FILES = {  # EA name in Jamf -> script file
    rc.EA_STATUS: "ea-content-cache-status.sh",
    rc.EA_FOUND:  "ea-content-cache-servers-found.sh", rc.EA_ASSETS: "ea-content-cache-macos-assets.sh",
    rc.EA_DECODED: "ea-content-cache-decoded.sh", rc.EA_EFFECT: "ea-content-cache-effectiveness.sh"}
def main():
    ap = argparse.ArgumentParser(description=__doc__); ap.add_argument("--create", action="store_true", help="create EAs that do not exist yet")
    args = ap.parse_args()
    j = rc.jamf_from_credentials()
    existing = {e["name"]: e for e in j.call("/api/v1/computer-extension-attributes?page=0&page-size=500").get("results", [])}
    eadir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ea")
    for name, fn in FILES.items():
        local = open(os.path.join(eadir, fn)).read()
        hit = existing.get(name)
        if hit:
            if (hit.get("scriptContents") or "").replace("\r\n", "\n").strip() == local.strip():
                print(f"{hit['name']}: up to date"); continue
            body = {k: hit[k] for k in ("name", "description", "dataType", "enabled", "inventoryDisplayType", "inputType") if k in hit}
            body["scriptContents"] = local; body["inputType"] = "SCRIPT"     # also converts a text-field EA to a script EA
            try: j.call(f"/api/v1/computer-extension-attributes/{hit['id']}", "PUT", body); print(f"{hit['name']}: updated from {fn}")
            except urllib.error.HTTPError as e: print(f"{hit['name']}: refused HTTP {e.code} (needs Update Computer Extension Attributes); paste ea/{fn} by hand")
        elif args.create:
            body = {"name": name, "description": f"See README, {fn}", "dataType": "STRING", "enabled": True,
                    "inventoryDisplayType": "EXTENSION_ATTRIBUTES", "inputType": "SCRIPT", "scriptContents": local}
            try: j.call("/api/v1/computer-extension-attributes", "POST", body); print(f"{name}: created")
            except urllib.error.HTTPError as e: print(f"{name}: create refused HTTP {e.code}")
        else: print(f"{name}: not in Jamf (use --create)")
if __name__ == "__main__": main()
