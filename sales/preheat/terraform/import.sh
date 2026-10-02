#!/bin/bash
# import.sh: bring a Jamf Pro tenant that already has Preheat's objects (created by hand or by the
# admin/*.py scripts) under Terraform, so the first apply changes nothing instead of failing on
# duplicate names. Read-only against Jamf; writes only Terraform state.
#   cd terraform && terraform init && bash import.sh
# Needs the same Jamf Pro API client the admin scripts use (keychain or JAMF_* env vars), with the
# Read privileges the doctor checks, plus the Platform API credentials Terraform itself needs.
set -u
cd "$(dirname "$0")"
python3 - <<'PY'
import os, sys, subprocess, json, urllib.parse
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(".")), "admin")); rc = __import__("readiness-check")
j = rc.jamf_from_credentials()
def imp(addr, id_):
    if not id_: print(f"skip   {addr}: not in Jamf"); return
    r = subprocess.run(["terraform", "import", addr, str(id_)], capture_output=True, text=True)
    print(("import " if r.returncode == 0 else "FAILED ") + f"{addr} <- {id_}" + ("" if r.returncode == 0 else "\n" + r.stderr[-300:]))
eas = {e["name"]: e["id"] for e in j.call("/api/v1/computer-extension-attributes?page=0&page-size=500")["results"]}
for k, name in (("content-cache-status", rc.EA_STATUS), ("content-cache-servers-found", rc.EA_FOUND), ("content-cache-macos-assets", rc.EA_ASSETS),
                ("content-cache-decoded", rc.EA_DECODED), ("content-cache-effectiveness", rc.EA_EFFECT)):
    imp(f'jamfplatform_pro_computer_extension_attribute.script["{k}"]', eas.get(name))
imp("jamfplatform_pro_computer_extension_attribute.readiness", eas.get(rc.EA_READY))
meas = {e["name"]: e["id"] for e in j.call("/api/v1/mobile-device-extension-attributes?page=0&page-size=500")["results"]}
imp("jamfplatform_pro_mobile_device_extension_attribute.server", meas.get(rc.EA_MOBILE_SERVER))
groups = {g["name"]: g["id"] for g in j.call("/api/v2/computer-groups/smart-groups?page=0&page-size=1000")["results"]}
for n in ("Content Caching - Servers", "Content Caching - Ready for OS push", "Content Caching - Partially ready", "Content Caching - Not ready",
          "Content Caching - Inactive or broken", "Content Caching - Low on space", "Content Caching - Low benefit", "Content Caching - Wiped recently", "Macs with no content cache"):
    imp(f'jamfplatform_pro_smart_computer_group.preheat["{n}"]', groups.get(n))
mg = {(g.get("groupName") or g.get("name")): (g.get("groupId") or g.get("id")) for g in j.call("/api/v2/mobile-device-groups/smart-groups?page=0&page-size=1000")["results"]}
imp("jamfplatform_pro_smart_mobile_device_group.no_cache", mg.get("Mobile devices with no content cache"))
scripts = {s["name"]: s["id"] for s in j.call("/api/v1/scripts?page=0&page-size=500")["results"]}
imp("jamfplatform_pro_script.labels", scripts.get("preheat-labels.py"))
pols = {p["name"]: p["id"] for p in j.call("/JSSResource/policies")["policies"]}
imp("jamfplatform_pro_policy.labels", pols.get("Preheat - Refresh cache labels"))
print("\nPer-office 'served by' groups are keyed by the label you give in var.cache_servers; import them by hand, e.g.\n"
      "  terraform import 'jamfplatform_pro_smart_computer_group.served_by[\"Office X\"]' <group id>")
PY
