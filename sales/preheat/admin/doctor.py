#!/usr/bin/env python3
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
"""
doctor.py: check a Preheat installation end to end and say, in plain words, what to fix next.
Read-only: it never changes anything in Jamf, on a Mac or in a cache.

    python3 admin/doctor.py            # everything
    python3 admin/doctor.py --offline  # only the parts that need no Jamf (Apple's lookup service, AppleDB, Python)

Each line is PASS, WARN (works, but something is worth a look) or FAIL (a feature will not work until fixed),
followed by what to do. Exit status 1 if anything failed. Credentials as for readiness-check.py.
"""
import argparse, datetime, os, re, sys, urllib.error, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(__file__)); rc = __import__("readiness-check")

results = {"PASS": 0, "WARN": 0, "FAIL": 0}
def say(level, what, fix=""):
    results[level] += 1
    print(f"{level:4}  {what}" + (f"\n        -> {fix}" if fix else ""))

def probe(j, path):
    """HTTP status of a GET, 200 when it works."""
    try: j.call(path); return 200
    except urllib.error.HTTPError as e: return e.code
    except Exception: return 0

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--offline", action="store_true", help="skip everything that needs Jamf")
    args = ap.parse_args()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    print("== This Mac and the outside services")
    v = sys.version_info
    say("PASS" if v >= (3, 8) else "FAIL", f"Python {v.major}.{v.minor}", "" if v >= (3, 8) else "install the Xcode Command Line Tools: xcode-select --install")
    try:
        a = rc.gdmf_assets("J274AP", "Macmini9,1", rc.NO_VERSION, "0", "mac")
        say("PASS" if a else "FAIL", f"Apple's lookup service answers ({len(a)} macOS assets for a Mac mini M1)", "" if a else "gdmf.apple.com returned nothing: check outbound HTTPS, or Apple changed the service")
    except Exception as e: say("FAIL", f"Apple's lookup service: {e}", "allow outbound HTTPS to gdmf.apple.com")
    try:
        try: os.remove(rc.BOARD_CACHE) if os.path.exists(rc.BOARD_CACHE) and os.path.getsize(rc.BOARD_CACHE) < 1000 else None
        except OSError: pass
        b = rc.board_for("iPhone17,3"); t2 = rc.board_for("MacBookPro16,1")
        say("PASS" if b == "D47AP" and t2 == "J152FAP" else "FAIL", f"AppleDB model list (iPhone17,3 -> {b or '?'}, T2 MacBookPro16,1 -> {t2 or '?'})",
            "" if b and t2 else "api.appledb.dev unreachable or its format changed; mobile devices and Intel T2 Macs cannot be looked up")
    except Exception as e: say("FAIL", f"AppleDB: {e}", "allow outbound HTTPS to api.appledb.dev")
    if args.offline: return finish()

    print("\n== Jamf Pro: credentials and privileges")
    try: j = rc.jamf_from_credentials()
    except SystemExit as e: say("FAIL", str(e)); return finish()
    except urllib.error.HTTPError as e:
        say("FAIL", f"Jamf refused the API client (HTTP {e.code})", "check the client ID and secret, that the client is enabled, and that the URL is your Jamf Pro URL"); return finish()
    except Exception as e: say("FAIL", f"cannot reach Jamf Pro: {e}", "check JAMF_URL and the network"); return finish()
    say("PASS", f"API client accepted by {j.base}")
    needs = [("/api/v1/computers-inventory?page=0&page-size=1", "Read Computers", "everything", "FAIL"),
             ("/api/v1/computer-extension-attributes?page=0&page-size=1", "Read Computer Extension Attributes", "everything", "FAIL"),
             ("/api/v2/mobile-devices/detail?page=0&page-size=1", "Read Mobile Devices", "--platforms (iPhone, iPad, Apple TV, Vision Pro)", "WARN"),
             ("/api/v2/computer-groups/smart-groups?page=0&page-size=1", "Read Smart Computer Groups", "create-smart-groups.py and --cohort", "WARN"),
             ("/api/v2/mobile-device-groups/smart-groups?page=0&page-size=1", "Read Smart Mobile Device Groups", "mobile Smart Groups and --cohort", "WARN"),
             ("/api/v2/computer-groups/static-groups?page=0&page-size=1", "Read Static Computer Groups", "--cohort with a Static group", "WARN"),
             ("/api/v1/mobile-device-groups/static-groups?page=0&page-size=1", "Read Static Mobile Device Groups", "--cohort with a Static mobile group", "WARN"),
             ("/api/v1/scripts?page=0&page-size=1", "Read Scripts", "create-labels-policy.py", "WARN"),
             ("/JSSResource/policies", "Read Policies", "create-labels-policy.py", "WARN")]
    ok = {}
    for path, priv, feature, level in needs:
        code = probe(j, path); ok[priv] = code == 200
        say("PASS" if code == 200 else level, f"{priv}" + ("" if code == 200 else f" (HTTP {code})"), "" if code == 200 else f"needed for {feature}: add it to the API role")
    print("        (write privileges are only proven by use: Update Computers / Update Mobile Devices for --write, Create and Update for the setup scripts)")
    if not ok["Read Computers"] or not ok["Read Computer Extension Attributes"]: return finish()

    print("\n== Jamf Pro: what is installed")
    eas = {e["name"]: e for e in j.call("/api/v1/computer-extension-attributes?page=0&page-size=500").get("results", [])}
    for name, why in ((rc.EA_BOARD, "the board now comes from the model identifier"),):
        old = eas.get(name)
        if old: say("PASS", f"EA {old['name']} is installed and no longer needed ({why})", "it can be deleted in Jamf; nothing reads it" + (" except Macs from before 2016, which need it" if name == rc.EA_BOARD else ""))
    scripts = {rc.EA_STATUS: "ea-content-cache-status.sh", rc.EA_FOUND: "ea-content-cache-servers-found.sh",
               rc.EA_ASSETS: "ea-content-cache-macos-assets.sh", rc.EA_DECODED: "ea-content-cache-decoded.sh", rc.EA_EFFECT: "ea-content-cache-effectiveness.sh"}
    for name, fn in scripts.items():
        hit = eas.get(name)
        if not hit: say("FAIL", f"EA {name} is not in Jamf", "python3 admin/sync-eas.py --create"); continue
        local = open(os.path.join(here, "ea", fn)).read().strip()
        if hit.get("inputType") != "SCRIPT": say("WARN", f"EA {hit['name']} is a {hit.get('inputType')} field, not a script", "python3 admin/sync-eas.py converts it")
        elif (hit.get("scriptContents") or "").replace("\r\n", "\n").strip() != local: say("WARN", f"EA {hit['name']} differs from ea/{fn}", "python3 admin/sync-eas.py")
        else: say("PASS", f"EA {hit['name']} matches ea/{fn}")
    ready = eas.get(rc.EA_READY)
    say("PASS" if ready else "FAIL", f"EA {rc.EA_READY} (Text Field, filled by --write)" + ("" if ready else " is not in Jamf"), "" if ready else "create it by hand: data type String, input type Text Field")
    if ok.get("Read Smart Computer Groups"):
        groups = {g["name"] for g in j.call("/api/v2/computer-groups/smart-groups?page=0&page-size=1000").get("results", [])}
        want = ["Content Caching - Servers", "Content Caching - Ready for OS push", "Content Caching - Not ready", "Content Caching - Inactive or broken", "Content Caching - Low on space", "Content Caching - Low benefit", "Content Caching - Wiped recently", "Macs with no content cache"]
        miss = [g for g in want if g not in groups]
        say("PASS" if not miss else "WARN", "Smart Groups present" if not miss else "Smart Groups missing: " + ", ".join(miss), "" if not miss else "python3 admin/create-smart-groups.py")
    if ok.get("Read Policies"):
        pol = [p for p in j.call("/JSSResource/policies")["policies"] if p["name"] == "Preheat - Refresh cache labels"]
        if not pol: say("WARN", "the labels policy is not in Jamf, so the decoded EA will show 'unidentified' for new files", "python3 admin/create-labels-policy.py")
        else:
            g = j.call(f"/JSSResource/policies/id/{pol[0]['id']}")["policy"]["general"]
            say("PASS" if g.get("enabled") else "WARN", "labels policy present" + ("" if g.get("enabled") else " but DISABLED"), "" if g.get("enabled") else "enable it in Jamf, or decoded names stop updating")

    print("\n== The fleet, as Jamf sees it today")
    comps = j.inventory(); today = datetime.date.today()
    servers = [c for c in comps if c["cache_guid"]]
    say("PASS" if servers else "FAIL", f"{len(servers)} content cache server(s) among {len(comps)} Macs",
        "" if servers else "Jamf's Content Caching inventory shows no Mac with caching switched on: is content caching on, is that Mac enrolled, has it sent inventory since?")
    for c in comps:     # a Mac that found a cache on itself, and is not one now, was a cache server until recently
        was = re.search(r"localhost:\d+ last-seen (\d{4}-\d\d-\d\d)", c["caches_found"] or "")
        # Someone switched it off (its status is fine). A cache that lost its storage reports a problem instead,
        # counts as a cache server that is down, and is reported further on.
        if was and not c["cache_guid"] and (today - datetime.date.fromisoformat(was.group(1))).days <= 7:
            say("WARN", f"{c['name']} was a content cache on {was.group(1)} and is switched off now",
                "if that was meant, nothing to do (this note stops after 7 days). If not: Sharing > Content Caching on that Mac, then an inventory update")
    sites = rc.collect_sites(comps)
    for st in sites:
        inside = [s["name"] for s in servers if rc.in_ranges(s.get("cache_public_ip"), st["public"])]
        say("PASS" if inside else "WARN", f"site with public addresses {rc.show_ranges(st['public'])}" + (f", favored caches {rc.show_ranges(st['favored'])}" if st["favored"] else "") + f" ({st['source']}): " + (", ".join(inside) if inside else "no cache server registers from any of them"),
            "" if inside else "the DNS TXT record and the caches' public addresses disagree: devices on this network are offered no cache")
        if st["favored"]:
            fav = [s["name"] for s in servers if any(rc.in_ranges(a, st["favored"]) for a in s.get("cache_ips") or [])]
            if not fav: say("WARN", f"the favored range {rc.show_ranges(st['favored'])} contains no cache server Jamf knows", "devices fall back to other caches for shared content; check the fss record against the caches' addresses")
    limit = j.silent_threshold(); utcnow = datetime.datetime.now(datetime.timezone.utc)
    for s in servers:      # a server that is off, or off the network, changes nothing in Jamf: only its silence shows
        heard = rc.last_heard(s, rc.live_cache(j.cache_status(s.get("management_id")), s.get("inventory_time") or ""))
        if not heard: continue
        quiet = int((utcnow - heard).total_seconds() // 60)
        if quiet > limit: say("FAIL", f"{s['name']} has not been heard from since {heard.astimezone().strftime('%Y-%m-%d %H:%M')} ({quiet} minutes; limit {limit})",
                              "it is off or off the network, and no device can use its cache. Its record in Jamf still reads as it did: check the Mac, its cable and its address")
        else: say("PASS", f"{s['name']} was last heard from {quiet} minute(s) ago")
    seen_live = 0
    for c in comps:      # what each cache server, or former one, says about itself right now (macOS 27, through DDM)
        if not (c["cache_guid"] or "localhost:" in (c["caches_found"] or "")): continue
        live = rc.live_cache(j.cache_status(c.get("management_id")), c.get("inventory_time") or "")
        if not live: continue
        seen_live += 1
        if not c["cache_guid"]:      # not a cache by inventory: said above. Worth a line only if it has been switched on since
            if live["on"]: say("WARN", f"{c['name']} reports itself a running content cache since {live['since']}, and its inventory does not show that yet", "run an inventory update on it (sudo jamf recon)")
            continue
        if live["on"]: say("PASS", f"{c['name']} reports itself {live['line']} (DDM, {live['as_of']})")
        else: say("FAIL", f"{c['name']} reports: {live['problem']} since {live['since']} (DDM, {live['as_of']})",
                  "no device can use this cache until it is running and registered: check Sharing > Content Caching, its storage volume and its network")
        known = {s["cache_guid"]: s["name"] for s in servers}
        for x in live["peer_list"]:
            who = known.get(x["guid"])
            if who and x["healthy"]: say("PASS", f"{c['name']} has a peer: {who} at {x['address']}")
            elif who: say("WARN", f"{c['name']} reports its peer {who} as unhealthy", "its content is not counted until it is healthy again")
            else: say("WARN", f"{c['name']} has a peer at {x['address']} that Jamf does not list as a cache server", "a Mac with content caching on that is not enrolled, or has not sent inventory since it was switched on. Its content cannot be counted, and devices may be using it")
        if live["changed_since_inventory"] and live["on"] != (c.get("cache_status") or "").startswith("Active"):      # a cache reports again whenever anything about it changes; only a different state matters
            say("WARN", f"{c['name']}: the cache changed state at {live['since']}, after its last inventory", "run an inventory update on it (sudo jamf recon) so the file list and readiness are current")
    if servers and not seen_live:
        print("        (no live cache status through DDM: needs macOS 27 on the cache server and the privilege to read DDM status; inventory is used instead)")
    for s in servers:
        if "status OK" not in (s["cache_status"] or ""): say("WARN", f"{s['name']}: {s['cache_status'][:90]}", "see docs/CAVEATS.md: registration, VPN on the server, disk space")
        assets = rc.parse_assets_ea(s["assets_ea"])
        if not s["assets_ea"] or s["assets_ea"].startswith(("Must run", "No database")): say("WARN", f"{s['name']}: assets EA says '{s['assets_ea'][:60]}'", "run an inventory update on the server (sudo jamf recon)")
        else: say("PASS", f"{s['name']}: {len(assets)} OS update file(s) listed, last inventory {s['last_inventory']}")
        if s["last_inventory"] and (today - datetime.date.fromisoformat(s["last_inventory"])).days > 2:
            say("WARN", f"{s['name']}: no inventory for {(today - datetime.date.fromisoformat(s['last_inventory'])).days} days, so every cache EA is stale", "check the Mac is on and checking in")
    def age(c):
        try: return (today - datetime.date.fromisoformat(c["last_inventory"])).days
        except (TypeError, ValueError): return 9999
    old = [c for c in comps if not c["cache_guid"] and age(c) > 30]     # readiness-check.py leaves these out too (--max-age-days)
    if old: say("PASS", f"{len(old)} Mac record(s) with no inventory for over 30 days, left out of the readiness check: " + ", ".join(f"{c['name']} ({c['last_inventory'] or 'never'})" for c in old[:6]),
                "nothing to do if they are retired or kept for reference")
    macs = [c for c in comps if not c["cache_guid"] and age(c) <= 30]
    noboard = []; nofound = [c["name"] for c in macs if not c["caches_found"]]
    oldmacs = [c["name"] for c in macs if not c["board"]]
    if oldmacs: say("WARN", f"{len(oldmacs)} Mac(s) whose board cannot be worked out from the model: " + ", ".join(oldmacs[:6]), "Macs from before 2016 with more than one board per model: install ea/ea-board-id.sh as a script EA named \"" + rc.EA_BOARD + "\" for them")
    none = [c["name"] for c in macs if c["caches_found"].strip() == "None found"]
    if noboard or nofound: say("WARN", f"{len(set(noboard + nofound))} Mac(s) have empty EAs (no inventory since the EAs were created): " + ", ".join(sorted(set(noboard + nofound))[:6]), "they fill in at the next inventory update")
    if none: say("WARN", f"{len(none)} Mac(s) report 'None found': " + ", ".join(none[:6]), "expected for remote Macs; for office Macs look for a VPN or full-tunnel client (README caveats)")
    if ok.get("Read Mobile Devices"):
        try:
            mob = j.mobile_inventory(); pubs = {s["cache_public_ip"] for s in servers if s.get("cache_public_ip")}
            known = [r for st in sites for r in st["public"]]
            off = [m["name"] for m in mob if m.get("ip") and pubs and m["ip"] not in pubs and not rc.in_ranges(m["ip"], known)]
            say("PASS", f"{len(mob)} mobile device(s) in inventory")
            if off: say("WARN", f"{len(off)} mobile device(s) report a public IP that matches no cache server: " + ", ".join(off[:6]), "remote devices, or a VPN on the device: Apple will not offer them the cache either. If the site has more than one public address, see --public-ranges in readiness-check.py --help. Otherwise either")
        except Exception as e: say("WARN", f"mobile inventory: {e}")
    return finish()

def finish():
    print(f"\n{results['PASS']} passed, {results['WARN']} to look at, {results['FAIL']} failed")
    sys.exit(1 if results["FAIL"] else 0)

if __name__ == "__main__": main()
