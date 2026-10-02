#!/usr/bin/env python3
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
"""
Put admin/preheat-labels.py into Jamf Pro as a script, and create the policy that runs it on cache servers:
  General: trigger Recurring Check-in, frequency Ongoing     Scripts: preheat-labels.py
  Maintenance: Update Inventory                              Scope: Smart Group "Content Caching - Servers"
So at every check-in a cache server names any new files it holds, then sends inventory, and the decoded EA
(ea-content-cache-decoded.sh) is current without anyone running the admin script. Disable the policy to stop.
Run again after editing preheat-labels.py: the script in Jamf is updated, the policy is left alone.
Needs API privileges: Create/Read/Update Scripts, Create/Read Policies, Read Smart Computer Groups.
Usage: python3 admin/create-labels-policy.py [--group "Content Caching - Servers"] [--disabled]
"""
import os, sys, argparse, urllib.error, urllib.request
from xml.sax.saxutils import escape
sys.path.insert(0, os.path.dirname(__file__)); rc = __import__("readiness-check")
SCRIPT_NAME = "preheat-labels.py"; POLICY_NAME = "Preheat - Refresh cache labels"

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--group", default="Content Caching - Servers"); ap.add_argument("--disabled", action="store_true", help="create the policy switched off")
    args = ap.parse_args()
    j = rc.jamf_from_credentials()
    local = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), SCRIPT_NAME)).read()
    scripts = j.call("/api/v1/scripts?page=0&page-size=500").get("results", [])
    hit = next((s for s in scripts if s["name"] == SCRIPT_NAME), None)
    body = {"name": SCRIPT_NAME, "info": "Names the OS update files a content cache holds. No Jamf credentials. See the preheat README.",
            "notes": "Managed by admin/create-labels-policy.py", "priority": "AFTER", "scriptContents": local}
    if hit:
        sid = hit["id"]
        if (hit.get("scriptContents") or "").replace("\r\n", "\n").strip() == local.strip(): print(f"script {SCRIPT_NAME}: up to date (id {sid})")
        else: j.call(f"/api/v1/scripts/{sid}", "PUT", {**hit, **body}); print(f"script {SCRIPT_NAME}: updated (id {sid})")
    else:
        sid = j.call("/api/v1/scripts", "POST", body)["id"]; print(f"script {SCRIPT_NAME}: created (id {sid})")
    if any(p["name"] == POLICY_NAME for p in j.call("/JSSResource/policies")["policies"]):
        print(f"policy '{POLICY_NAME}': already exists, left alone"); return
    groups = j.call("/api/v2/computer-groups/smart-groups?page=0&page-size=500").get("results", [])
    gid = next((g["id"] for g in groups if g["name"] == args.group), None)
    if not gid: sys.exit(f"Smart Group '{args.group}' not found; run admin/create-smart-groups.py first")
    xml = f"""<policy><general><name>{escape(POLICY_NAME)}</name><enabled>{str(not args.disabled).lower()}</enabled>
<trigger>CHECKIN</trigger><trigger_checkin>true</trigger_checkin><frequency>Ongoing</frequency></general>
<scope><computer_groups><computer_group><id>{gid}</id></computer_group></computer_groups></scope>
<scripts><size>1</size><script><id>{sid}</id><priority>After</priority></script></scripts>
<maintenance><recon>true</recon></maintenance></policy>"""
    req = urllib.request.Request(j.base + "/JSSResource/policies/id/0", data=xml.encode(), method="POST",
                                 headers={"Authorization": "Bearer " + j.token, "Content-Type": "application/xml"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: print(f"policy '{POLICY_NAME}': created, scoped to '{args.group}'", r.read().decode()[-40:])
    except urllib.error.HTTPError as e: sys.exit(f"policy create refused HTTP {e.code}: {e.read().decode()[:300]}")

if __name__ == "__main__": main()
