#!/usr/bin/python3
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
"""
preheat-labels.py: name the OS update files a content cache holds. Runs ON the cache server, as root,
from a Jamf policy (recurring check-in, ongoing, with Update Inventory). Needs NO Jamf credentials.

The cache stores updates under opaque paths. Apple's public lookup service (gdmf.apple.com) is the only
way to turn a path into "iOS 27.0 (24A437) full for iPhone17,3". This script asks that service on behalf
of every device model (list from AppleDB), and writes what it learns to
    /Library/Application Support/preheat/labels.json      {"labels": {"<path>": "<human label>"}}
The EA script ea-content-cache-decoded.sh reads that file at inventory time, so the EA itself stays
local-only. A path's label never changes, so labels are kept forever and the network is only used when
the cache holds a path that has no label yet.

Passes, each only if unlabelled paths remain:
  1. full installers (InstallAssistant.pkg) from Apple's software update catalog
  2. every model with no source build: full images, and every tvOS delta
  3. every model of the platforms still unlabelled, per released build (newest first): deltas.
     iOS only offers a delta when the source version AND build both match a real release (AppleDB supplies the pair)

Usage:  preheat-labels.py [--paths FILE] [--out FILE] [--all] [--max-builds N]
  --paths FILE   read cached paths from FILE (one per line, or raw assets EA text) instead of the cache database
  --all          label everything Apple offers, not just what this cache holds (passes 1-2)
Python 3 standard library only.
"""
import argparse, base64, concurrent.futures, datetime, json, os, re, shutil, sqlite3, subprocess, sys, tempfile
import urllib.parse, urllib.request, uuid

GDMF_URL = "https://gdmf.apple.com/v2/assets"
APPLEDB_DEVICES = "https://api.appledb.dev/device/main.json"
APPLEDB_BUILDS = "https://api.appledb.dev/ios/index.json"      # ["iOS;23H24", "macOS;25G229", ...]
SUCATALOG_URL = ("https://swscan.apple.com/content/catalogs/others/"
                 "index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog")
STATE_DIR = "/Library/Application Support/preheat"
UA = {"User-Agent": "preheat/1.0"}
FORMAT = 3      # bump when label wording changes: every file is renamed once
SEARCH_REV = 3  # bump when the search gets smarter: paths given up on are tried again at once      # bump when label wording or logic changes
SU = "com.apple.MobileAsset.SoftwareUpdate"
# platform -> (asset type, release audience, OS name, AppleDB build-list names)
PLATFORMS = {
    "mac":      ("com.apple.MobileAsset.MacSoftwareUpdate", "60b55e25-a8ed-4f45-826c-c1495a4ccc65", "macOS", ("macOS",)),
    "ios":      (SU, "01c1d682-6e8f-4908-b724-5501fe3f5e5c", "iOS", ("iOS",)),
    "ipados":   (SU, "01c1d682-6e8f-4908-b724-5501fe3f5e5c", "iPadOS", ("iPadOS", "iOS")),
    "tvos":     (SU, "356d9da0-eee4-4c6c-bbe5-99b60eadddf0", "tvOS", ("tvOS",)),
    "visionos": (SU, "c59ff9d1-5468-4f6c-9e54-f68d5eeab93b", "visionOS", ("visionOS",)),
    "watchos":  (SU, "b82fcf9c-c284-41c9-8eb2-e69bf5a5269f", "watchOS", ("watchOS",)),
    "audioos":  (SU, "0322d49d-d558-4ddf-bdff-c0443d0e6fac", "HomePod software", ("audioOS",)),
}
# Source version sent when there is no real one. It must look like a real version: "0" is refused for HomePod and
# "1.0" returns nothing for Apple TV, while any two-part version (tested 18.0, 26.0, 99.0) works on every platform.
NO_VERSION = "26.0"
# The previous OS branch (iOS 26.7 once 27 is out) is published on a second, "alternate" audience; ask both
ALT_AUDIENCE = {"ios": "c724cb61-e974-42d3-a911-ffd4dce11eda", "ipados": "c724cb61-e974-42d3-a911-ffd4dce11eda",
                "visionos": "bb4eeb45-d4f7-4777-bd18-eb38c8443a9c"}

def platform_of(model):
    for prefix, plat in (("iPhone", "ios"), ("iPod", "ios"), ("iPad", "ipados"), ("AppleTV", "tvos"), ("RealityDevice", "visionos"),
                         ("Watch", "watchos"), ("AudioAccessory", "audioos")):
        if model.startswith(prefix): return plat
    return "mac" if re.match(r"(Mac|iMac|MacBook)", model) else None

def fetch(url, timeout=120):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r: return r.read()

def cached_paths():
    """OS update paths in this Mac's content cache database (root only)."""
    try:
        st = json.loads(subprocess.run(["/usr/bin/AssetCacheManagerUtil", "-j", "settings"], capture_output=True, text=True).stdout or "{}")
    except Exception: st = {}
    data = (st.get("result") or {}).get("DataPath") or "/Library/Application Support/Apple/AssetCache/Data"
    db = os.path.join(data, "AssetInfo.db")
    if not os.path.isfile(db): return []
    w = tempfile.mkdtemp(prefix="preheat-labels.")
    try:
        for ext in ("", "-wal", "-shm"):
            if os.path.exists(db + ext): shutil.copy(db + ext, os.path.join(w, "db" + ext))
        con = sqlite3.connect(os.path.join(w, "db"))
        return [r[0] for r in con.execute("select ZURI from ZASSET where ZURI like '%/InstallAssistant.pkg' "
                "or ZURI like '%com_apple_MobileAsset_MacSoftwareUpdate/%' or ZURI like '%com_apple_MobileAsset_SoftwareUpdate/%' "
                "or ZURI like '%SimulatorRuntime/%' or ZURI like '%com_apple_MobileAsset_MetalToolchain/%' or ZURI like '/itunes-assets/Aerials%'")]
    finally: shutil.rmtree(w, ignore_errors=True)

def models():
    """[(model identifier, board, platform)] for everything released since 2013, from AppleDB (Macs incl. Intel, iPhone, iPad, Apple TV, Vision Pro, Watch, HomePod)."""
    out, seen = [], set()
    db = json.loads(fetch(APPLEDB_DEVICES))
    # Intel Macs with a T2 chip: Apple answers for the T2's own board in capitals (MacBookPro16,1 -> J152FAP), not Mac-xxxx
    t2 = {m.group(1): (d.get("board") if isinstance(d.get("board"), str) else (d.get("board") or [""])[0])[:-2].upper() + "AP"
          for d in db for m in [re.fullmatch(r"T2 \((\w+,\d+)\)", d.get("name") or "")] if m and d.get("board")}
    for d in db:
        ids = d.get("identifier") or []; ids = [ids] if isinstance(ids, str) else ids
        bs = d.get("board") or []; bs = [bs] if isinstance(bs, str) else bs
        rel = d.get("released"); rel = (rel[0] if isinstance(rel, list) and rel else rel) or ""
        if not ids or not bs or str(rel) < "2013": continue
        for i, m in enumerate(ids):
            p = platform_of(m)
            for b in ([t2[m]] if m in t2 else bs if len(ids) == 1 else [bs[i] if i < len(bs) else bs[0]]):
                if p and (m, b) not in seen: seen.add((m, b)); out.append((m, b, p))
    return out

def gdmf(model, board, plat, build="0", version=NO_VERSION):
    atype, audience = PLATFORMS[plat][:2]; assets = []
    for aud in [audience] + ([ALT_AUDIENCE[plat]] if plat in ALT_AUDIENCE else []):
        body = {"ClientVersion": 2, "AssetType": atype, "AssetAudience": aud, "CertIssuanceDay": "2023-12-10",
                "BuildVersion": build, "HWModelStr": board, "ProductType": model, "ProductVersion": version,
                "CompatibilityVersion": 20, "Nonce": str(uuid.uuid4())}
        req = urllib.request.Request(GDMF_URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as r: jwt = r.read().decode()
            p = jwt.split(".")[1]
            assets += json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))).get("Assets", [])
        except Exception: pass
    return model, plat, assets

def sweep(jobs, info):
    """Run lookups in parallel and fold every asset seen into info[path]."""
    with concurrent.futures.ThreadPoolExecutor(8) as ex:
        for model, plat, assets in ex.map(lambda j: gdmf(*j), jobs):
            for a in assets:
                path = urllib.parse.urlparse(a.get("__BaseURL", "") + a.get("__RelativePath", "")).path
                e = info.setdefault(path, {"plat": plat, "ver": (a.get("OSVersion") or "").replace("9.9.", "", 1), "build": a.get("Build"),
                                           "from_ver": a.get("PrerequisiteOSVersion"), "from_build": a.get("PrerequisiteBuild"),
                                           "beta": a.get("ReleaseType") == "Beta", "models": set()})
                if e["beta"] and a.get("ReleaseType") != "Beta": e.update(beta=False, build=a.get("Build"))   # same file listed as beta and release
                e["models"].add(model)

def label(e):
    ms = sorted(e["models"])
    who = f"all Macs ({len(ms)} models)" if e["plat"] == "mac" and len(ms) >= 10 else ", ".join(ms[:3]) + (f" +{len(ms)-3} more" if len(ms) > 3 else "")
    kind = f"delta from {e['from_ver']} ({e['from_build']})" if e["from_build"] else "full"
    return f"{PLATFORMS[e['plat']][2]} {e['ver']} ({e['build']}) {kind}{' beta' if e['beta'] else ''} for {who}"

def label_installers(want, labels):
    import plistlib
    cat = plistlib.loads(fetch(SUCATALOG_URL))
    for pid, prod in cat.get("Products", {}).items():
        for pkg in prod.get("Packages", []):
            path = urllib.parse.urlparse(pkg.get("URL", "")).path
            if path not in want: continue
            labels[path] = f"macOS full installer, product {pid}"
            try:
                dists = prod.get("Distributions", {}); x = fetch(dists.get("English") or next(iter(dists.values())), 60).decode(errors="ignore")
                v = re.search(r"<key>VERSION</key>\s*<string>([^<]+)</string>", x); b = re.search(r"<key>BUILD</key>\s*<string>([^<]+)</string>", x)
                t = re.search(r"<title>([^<]+)</title>", x)
                if v: labels[path] = f"{(t.group(1) if t else 'macOS').strip()} {v.group(1)} ({b.group(1) if b else '?'}) full installer for all Macs"
            except Exception: pass

def build_key(b):
    m = re.match(r"(\d+)([A-Z])(\d+)", b); return (int(m.group(1)), m.group(2), int(m.group(3))) if m else (0, "", 0)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paths"); ap.add_argument("--out", default=os.path.join(STATE_DIR, "labels.json"))
    ap.add_argument("--all", action="store_true"); ap.add_argument("--max-builds", type=int, default=16, help="pass 3 rounds: how many earlier builds per model to try")
    args, _ = ap.parse_known_args()          # Jamf passes mount point, computer name and user as $1-$3
    if args.paths: paths = [l.split()[-1] for l in open(args.paths) if l.strip() and l.split()[-1].startswith("/")]
    else: paths = cached_paths()
    try: state = json.load(open(args.out))
    except Exception: state = {}
    labels = state.get("labels", {}) if state.get("format") == FORMAT else {}      # a format bump renames everything once
    today = datetime.date.today().isoformat()
    if state.get("search_rev") != SEARCH_REV: state["gave_up"] = {}
    todo = lambda: [p for p in paths if p not in labels and state.get("gave_up", {}).get(p) != today]
    print(f"{len(paths)} cached OS update path(s), {len(todo())} without a label")
    if not todo() and not args.all: return
    if any(p.startswith("/itunes-assets/Aerials") for p in todo()):      # Aerial screen savers: names from Apple's public manifest
        try:
            import plistlib, tarfile, io
            cfg = plistlib.loads(fetch("https://configuration.apple.com/configurations/internetservices/aerials/resources-config-27-0.plist"))
            tar = tarfile.open(fileobj=io.BytesIO(fetch(cfg["resources-url"])))
            d = json.load(tar.extractfile(next(m for m in tar.getmembers() if m.name.endswith("entries.json"))))
            cats = {c["id"]: c.get("localizedNameKey", "").replace("AerialCategory", "") for c in d.get("categories", [])}
            for a in d.get("assets", []):
                for k, u in a.items():
                    if k.startswith("url") and u:
                        labels[urllib.parse.urlparse(u).path] = f"Aerial screen saver: {a.get('accessibilityLabel') or a.get('id')} ({', '.join(cats.get(c, c) for c in a.get('categories', [])) or 'Aerial'})"
            # The manifest lists one file per video (4K). Apple TVs and older systems ask for other encodings of the
            # same shot, stored under another folder with the same opening to the file name: name those by their shot.
            known = {os.path.basename(k): v for k, v in labels.items() if k.startswith("/itunes-assets/Aerials") and "another encoding" not in v}
            def shot(a, b):      # how much of the opening two file names share: (whole words, letters)
                n = len(os.path.commonprefix([a, b])); whole = a[:n] if n == len(a) or not a[n:n+1].isalnum() else a[:n].rpartition("_")[0]
                return len([w for w in whole.split("_") if w and w != "comp"]), n
            for path in [x for x in todo() if x.startswith("/itunes-assets/Aerials")]:
                name = os.path.basename(path); ranked = {}
                for fn, lab in known.items(): ranked[lab] = max(ranked.get(lab, (0, 0)), shot(name, fn))
                best = sorted(ranked.items(), key=lambda kv: kv[1], reverse=True)[:2]
                if best and best[0][1][0] >= 2 and (len(best) == 1 or best[0][1] > best[1][1]):
                    labels[path] = best[0][0] + ", another encoding"
            print(f"aerials: {len(todo())} path(s) still without a label after Apple's manifest")
        except Exception as e: print(f"warning: Apple's Aerial manifest unavailable ({e})")
    if any("SimulatorRuntime" in p or "MetalToolchain" in p for p in todo()):      # Xcode components: names from Apple's public index
        try:
            import plistlib
            idx = plistlib.loads(fetch("https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex"))
            fam = {"iOS ": "com.apple.MobileAsset.iOSSimulatorRuntime", "tvOS ": "com.apple.MobileAsset.appleTVOSSimulatorRuntime",
                   "watchOS ": "com.apple.MobileAsset.watchOSSimulatorRuntime", "visionOS ": "com.apple.MobileAsset.xrOSSimulatorRuntime", "xrOS ": "com.apple.MobileAsset.xrOSSimulatorRuntime"}
            jobs = [(d["simulatorVersion"]["buildUpdate"], d["name"], t) for d in idx.get("downloadables", []) if d.get("simulatorVersion")
                    for pre, t in fam.items() if d["name"].startswith(pre)]
            jobs += [(m.group(1), d["name"], "com.apple.MobileAsset.MetalToolchain") for d in idx.get("otherDownloadables", [])
                     for m in [re.search(r"^Metal Toolchain \((\w+)\)", d.get("name", ""))] if m]
            def ask(job):
                build, name, atype = job
                body = {"ClientVersion": 2, "AssetType": atype, "AssetAudience": "02d8e57e-dd1c-4090-aa50-b4ed2aef0062", "CertIssuanceDay": "2023-12-10",
                        "BuildVersion": "26A428", "HWModelStr": "J274AP", "ProductType": "Macmini9,1", "ProductVersion": "27.0", "CompatibilityVersion": 20,
                        "RequestedBuild": build, "Nonce": str(uuid.uuid4())}
                req = urllib.request.Request(GDMF_URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
                try:
                    with urllib.request.urlopen(req, timeout=60) as r: p = r.read().decode().split(".")[1]
                    return [(urllib.parse.urlparse(a.get("__BaseURL", "") + a.get("__RelativePath", "")).path, name) for a in json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))).get("Assets", [])]
                except Exception: return []
            with concurrent.futures.ThreadPoolExecutor(8) as ex:
                for pairs in ex.map(ask, jobs):
                    for path, name in pairs: labels[path] = name
            print(f"xcode: {len(jobs)} index entries asked, {len(todo())} path(s) still without a label")
        except Exception as e: print(f"warning: Apple's simulator index unavailable ({e})")
    info = {}
    try:
        inst = {p for p in todo() if p.endswith("/InstallAssistant.pkg")}
        if inst: label_installers(inst, labels)
        if todo() or args.all:
            devs = models(); print(f"pass 2: {len(devs)} models, no source build")
            sweep([(m, b, p) for m, b, p in devs], info)
            labels.update({p: label(e) for p, e in info.items()})
        if todo():      # pass 3: deltas. Each model is asked about ITS OWN recent builds, newest first: the builds that share
            # a leading number with the newest OS it can run (17.7.11 is 21H461, so 21H450, 21H440 ...), then the
            # generation before (how a 26.7 device reaches 27.0). One round = one build per model.
            index = json.loads(fetch(APPLEDB_BUILDS)); meta = state.setdefault("build_meta", {})
            fam = {}      # (os name, leading number) -> builds, newest first
            for x in index:
                o, _, bld = x.partition(";")
                if re.fullmatch(r"\d+[A-Z]\d+", bld): fam.setdefault((o, re.match(r"\d+", bld).group()), []).append(bld)
            for k in fam: fam[k].sort(key=build_key, reverse=True)
            def build_info(ob):      # AppleDB lists release candidates, betas and internal builds beside releases; devices only
                o, bld = ob          # run releases, and trying the others first pushed real source builds out of reach
                key = f"{o};{bld}"
                if key not in meta:
                    try:
                        d = json.loads(fetch(f"https://api.appledb.dev/ios/{urllib.parse.quote(o)};{bld}.json", 60))
                        meta[key] = {"v": (d.get("version") or "").split(" ")[0], "skip": bool(d.get("beta") or d.get("rc") or d.get("internal"))}
                    except Exception: meta[key] = {"v": "", "skip": False}
                return meta[key]
            def version_of(o, bld): return build_info((o, bld))["v"]
            newest = {}      # model -> build of the newest full image Apple offers it
            for e in info.values():
                if not e["from_build"]:
                    for m in e["models"]:
                        if m not in newest or build_key(e["build"]) > build_key(newest[m]): newest[m] = e["build"]
            left = todo()
            kinds = {"mac"} if all("MacSoftwareUpdate" in p for p in left) else set(PLATFORMS) - {"mac", "tvos"} if not any("MacSoftwareUpdate" in p for p in left) else set(PLATFORMS) - {"tvos"}
            cands = {}
            for m, b, p in devs:
                if p not in kinds or m not in newest: continue
                lead = int(re.match(r"\d+", newest[m]).group()); o = next((n for n in PLATFORMS[p][3] if (n, str(lead)) in fam), PLATFORMS[p][3][0])
                same = [x for x in fam.get((o, str(lead)), []) if build_key(x) < build_key(newest[m])]; prev = fam.get((o, str(lead - 1)), [])
                merged = [x for pair in zip(same, prev) for x in pair] + same[len(prev):] + prev[len(same):]
                cands[(m, b, p)] = [(o, x) for x in merged[:40]]
            with concurrent.futures.ThreadPoolExecutor(8) as ex: list(ex.map(build_info, {ob for c in cands.values() for ob in c}))
            cands = {k: [ob for ob in c if not build_info(ob)["skip"]] for k, c in cands.items()}
            rnd = -1
            for rnd in range(args.max_builds):
                if not todo(): break
                jobs = [(m, b, p, c[rnd][1], version_of(*c[rnd]) or NO_VERSION) for (m, b, p), c in cands.items() if rnd < len(c)]
                if not jobs: break
                sweep(jobs, info); labels.update({p: label(e) for p, e in info.items()})
            print(f"pass 3: {rnd + 1} round(s), {len(todo())} path(s) still without a label")
            for p in todo(): state.setdefault("gave_up", {})[p] = today      # retry tomorrow, not at every check-in
    finally:
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        tmp = args.out + ".tmp"
        json.dump({"format": FORMAT, "search_rev": SEARCH_REV, "updated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), "labels": labels,
                   "build_meta": state.get("build_meta", {}), "gave_up": {p: d for p, d in state.get("gave_up", {}).items() if p not in labels}}, open(tmp, "w"), indent=0)
        os.chmod(tmp, 0o644); os.replace(tmp, args.out)
    left = [p for p in paths if p not in labels]      # includes paths given up on until tomorrow
    print(f"{len(labels)} label(s) on file; {len(left)} cached path(s) still unidentified" + (": " + ", ".join(os.path.basename(p)[:12] for p in left) if left else ""))

if __name__ == "__main__": main()
