#!/usr/bin/env python3
"""
Content cache macOS update readiness check, per cache server  (admin-side, NOT an EA script)

Question answered: for each content caching server, is it ready for the Macs that actually
use it, i.e. does it already hold the macOS update every hardware/build combination on its
network would download?

Data sources (all from Jamf Pro inventory)
  every Mac        model identifier -> board          hardware family key Apple uses (J413AP ...), from AppleDB
  every Mac        EA "Content Caching - Servers Found" which cache server(s) this Mac would use (GUID host:port ...)
  cache servers    Jamf's Content Caching inventory   activated, active, server GUID (the join key), port, addresses
                   (and EA "Content Caching - Status", the same facts worked out during inventory, for Smart Groups)
  cache servers    EA "Content Caching - macOS Assets"  cached macOS assets with COMPLETE / PARTIAL
  every Mac        model identifier, OS version, OS build, site, building

Steps
  1. Group Macs by the cache server they report (or by building with --group-by building).
  2. For each server, for each distinct (board, model, version, build) among ITS Macs, ask
     Apple's lookup service (gdmf.apple.com) which asset that Mac would download.
  3. Check that asset against the server's cached assets.
  4. Print a per-server report; with --write store "READY / PARTIAL / NOT READY ..." in the
     server's EA "Content Caching - macOS Readiness" for Smart Groups.

Auth: the macOS login keychain (store once with --store-credentials), or the environment
      variables JAMF_URL, JAMF_CLIENT_ID, JAMF_CLIENT_SECRET for CI and one-off runs.
Offline test:  --inventory-json admin/sample-inventory.json
Python 3 standard library only.
"""
import argparse, json, os, re, sys, time, urllib.error, urllib.request, urllib.parse, uuid, base64, datetime, collections

GDMF_URL = "https://gdmf.apple.com/v2/assets"
MACOS_RELEASE_AUDIENCE = "60b55e25-a8ed-4f45-826c-c1495a4ccc65"
# Platform -> (Apple lookup asset type, release audience). iOS and iPadOS share both.
PLATFORMS = {
    "mac":      ("com.apple.MobileAsset.MacSoftwareUpdate", "60b55e25-a8ed-4f45-826c-c1495a4ccc65"),
    "ios":      ("com.apple.MobileAsset.SoftwareUpdate",    "01c1d682-6e8f-4908-b724-5501fe3f5e5c"),
    "ipados":   ("com.apple.MobileAsset.SoftwareUpdate",    "01c1d682-6e8f-4908-b724-5501fe3f5e5c"),
    "tvos":     ("com.apple.MobileAsset.SoftwareUpdate",    "356d9da0-eee4-4c6c-bbe5-99b60eadddf0"),
    "visionos": ("com.apple.MobileAsset.SoftwareUpdate",    "c59ff9d1-5468-4f6c-9e54-f68d5eeab93b"),
    # Jamf does not inventory these, so they never appear in readiness; they exist for --preheat-models
    "watchos":  ("com.apple.MobileAsset.SoftwareUpdate",    "b82fcf9c-c284-41c9-8eb2-e69bf5a5269f"),
    "audioos":  ("com.apple.MobileAsset.SoftwareUpdate",    "0322d49d-d558-4ddf-bdff-c0443d0e6fac"),
}
OSNAME = {"mac": "macOS", "ios": "iOS", "ipados": "iPadOS", "tvos": "tvOS", "visionos": "visionOS", "watchos": "watchOS", "audioos": "HomePod software"}
# Source version sent when there is no real one; must look real ("0" is refused for HomePod, "1.0" gets nothing for Apple TV)
NO_VERSION = "26.0"

# ---------- Xcode components ----------
# Apple publishes the index Xcode itself reads: every simulator runtime and Metal toolchain, with the mapping from an
# Xcode or SDK build to the runtime build it wants. No login. The download URL then comes from the same lookup service
# as OS updates, asked with the runtime's build as RequestedBuild on the "generic" audience.
XCODE_INDEX_URL = "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex"
XCODE_GENERIC_AUDIENCE = "02d8e57e-dd1c-4090-aa50-b4ed2aef0062"
XCODE_PLATFORMS = {"ios": ("com.apple.platform.iphoneos", "com.apple.MobileAsset.iOSSimulatorRuntime", "iOS"),
                   "tvos": ("com.apple.platform.appletvos", "com.apple.MobileAsset.appleTVOSSimulatorRuntime", "tvOS"),
                   "watchos": ("com.apple.platform.watchos", "com.apple.MobileAsset.watchOSSimulatorRuntime", "watchOS"),
                   "visionos": ("com.apple.platform.xros", "com.apple.MobileAsset.xrOSSimulatorRuntime", "visionOS")}

def xcode_index():
    """Apple's simulator index as a dict, cached for a day."""
    import plistlib
    path = _cache("xcode-index.plist", "~/.preheat-xcode-index.plist")
    fresh = os.path.exists(path) and (datetime.datetime.now().timestamp() - os.path.getmtime(path)) < 86400
    if not fresh:
        with urllib.request.urlopen(urllib.request.Request(XCODE_INDEX_URL, headers={"User-Agent": "preheat/1.0"}), timeout=120) as r: open(path, "wb").write(r.read())
    return plistlib.load(open(path, "rb"))

def xcode_wants(xcode_version, platforms, betas=False):
    """[(kind, platform key, name, build, size)] for the simulator runtimes and Metal toolchain an Xcode version wants.
    xcode_version '27.0' matches Xcode 27.0.x; 'latest' = the newest Xcode the index knows."""
    idx = xcode_index(); out = []
    runtimes = {d["simulatorVersion"]["buildUpdate"]: d for d in idx.get("downloadables", []) if d.get("downloadMethod") == "mobileAsset" and d.get("simulatorVersion")}
    # Xcode version -> SDK identifiers it ships. The index maps SDK build -> runtime build; the SDK a given Xcode
    # ships is named by the runtime entries' "version" (27.0.0.x = Xcode 27.0 generation). Simplest reliable rule:
    # take, per platform, the "preferred" (else newest available) runtime whose major.minor equals Xcode's.
    want = None
    if xcode_version != "latest": want = ".".join(xcode_version.split(".")[:2])
    for key, (plat_id, atype, osname) in XCODE_PLATFORMS.items():
        if key not in platforms: continue
        cands = [d for d in runtimes.values() if d.get("platform") == plat_id and not d.get("isInternalContent")]
        if not betas: cands = [d for d in cands if "beta" not in d.get("name", "").lower()]
        if want: cands = [d for d in cands if d["simulatorVersion"]["version"].split(".")[0] == want.split(".")[0]]
        if not cands: continue
        best = max(cands, key=lambda d: (vkey(d["simulatorVersion"]["version"]), d["simulatorVersion"]["buildUpdate"]))
        out.append(("simulator", key, best["name"], best["simulatorVersion"]["buildUpdate"], best.get("fileSize") or 0))
    # Metal toolchain: the index names each one "Metal Toolchain (<build>) for Xcode <version>"
    mts = [d for d in idx.get("otherDownloadables", []) if d.get("name", "").startswith("Metal Toolchain")]
    def xv(d):
        m = re.search(r"for Xcode ([\d.]+)", d.get("name", "")); return m.group(1) if m else ""
    if not betas: mts = [d for d in mts if "beta" not in d.get("name", "").lower()]
    if want: mts = [d for d in mts if xv(d).split(".")[:2] == want.split(".")[:2]] or [d for d in mts if xv(d).split(".")[0] == want.split(".")[0]]
    if mts:
        d = max(mts, key=lambda d: vkey(xv(d)))
        b = re.search(r"\(([\w]+)\)", d["name"]); build = b.group(1) if b else ""
        if build: out.append(("metal", "mac", d["name"], build, d.get("fileSize") or 0))
    return out

def gdmf_xcode(kind, plat, build):
    """The file Apple serves for a simulator runtime or Metal toolchain build: {url, path, size, build} or None."""
    atype = "com.apple.MobileAsset.MetalToolchain" if kind == "metal" else XCODE_PLATFORMS[plat][1]
    body = {"ClientVersion": 2, "AssetType": atype, "AssetAudience": XCODE_GENERIC_AUDIENCE, "CertIssuanceDay": "2023-12-10",
            "BuildVersion": "26A428", "HWModelStr": "J274AP", "ProductType": "Macmini9,1", "ProductVersion": "27.0",
            "CompatibilityVersion": 20, "RequestedBuild": build, "Nonce": str(uuid.uuid4())}
    req = urllib.request.Request(GDMF_URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r: jwt = r.read().decode()
    except urllib.error.HTTPError as e: jwt = e.read().decode()
    parts = jwt.strip().split(".")
    if len(parts) != 3: return None
    payload = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
    for a in payload.get("Assets", []):
        url = a.get("__BaseURL", "") + a.get("__RelativePath", "")
        label = f"{XCODE_PLATFORMS[plat][2]} {a.get('SimulatorVersion') or ''} Simulator Runtime ({a.get('Build')})" if kind != "metal" else f"Metal Toolchain ({a.get('Build')})"
        _decoded.setdefault(urllib.parse.urlparse(url).path, label.replace("  ", " "))
        return {"url": url, "path": urllib.parse.urlparse(url).path, "size": a.get("_DownloadSize") or 0, "build": a.get("Build")}
    return None
APPLEDB_URL = "https://api.appledb.dev/device/main.json"   # model identifier -> board ID, all platforms
# Per-user download caches live where macOS expects them; everything here can be deleted at any time.
CACHE_DIR = os.path.expanduser("~/Library/Caches/preheat")
def _cache(name, old):
    """Path in CACHE_DIR; a file from the earlier ~/.preheat-* location is moved across once."""
    path = os.path.join(CACHE_DIR, name); legacy = os.path.expanduser(old)
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        if os.path.exists(legacy) and not os.path.exists(path): os.replace(legacy, path)
    except OSError: pass
    return path
BOARD_CACHE = _cache("boards.json", "~/.preheat-boards.json")

def platform_of(model):
    """Jamf model identifier -> platform key, or None."""
    m = (model or "")
    for prefix, plat in (("iPhone", "ios"), ("iPod", "ios"), ("iPad", "ipados"), ("AppleTV", "tvos"),
                         ("RealityDevice", "visionos"), ("Watch", "watchos"), ("AudioAccessory", "audioos")):
        if m.startswith(prefix): return plat
    return "mac" if m else None

_boards = None; _board_count = {}      # _board_count: how many different boards AppleDB lists for a model
def board_for(model):
    """Board ID for a model identifier, from AppleDB (cached locally for 7 days)."""
    global _boards
    if _boards is None:
        _boards = {}
        try:
            fresh = os.path.exists(BOARD_CACHE) and (datetime.datetime.now().timestamp() - os.path.getmtime(BOARD_CACHE)) < 7*86400
            if not fresh:
                req = urllib.request.Request(APPLEDB_URL, headers={"User-Agent": "preheat/1.0"})
                with urllib.request.urlopen(req, timeout=120) as r: raw = r.read()
                open(BOARD_CACHE, "wb").write(raw)
            t2 = {}
            for d in json.load(open(BOARD_CACHE)):
                ids = d.get("identifier") or []; ids = [ids] if isinstance(ids, str) else ids
                b = d.get("board") or []; b = [b] if isinstance(b, str) else b
                m = re.fullmatch(r"T2 \((\w+,\d+)\)", d.get("name") or "")
                if m and b: t2[m.group(1)] = b[0][:-2].upper() + "AP"; continue
                for i in ids:
                    if b: _board_count.setdefault(i, set()).update(b)
                    if b and i not in _boards: _boards[i] = b[0]
            _boards.update(t2)
            for i in t2: _board_count[i] = {t2[i]}
        except Exception as e:
            print(f"warning: could not load board map from AppleDB: {e}")
    return _boards.get(model, "")

def lookup_board(model, board):
    """The board Apple's lookup service keys on. Intel Macs with a T2 chip (2018-2020) report a Mac-xxxx board ID, but
    Apple answers for the T2's own board, in capitals (MacBookPro16,1 -> J152FAP); with Mac-xxxx it offers only macOS 11."""
    if (board or "").startswith("Mac-"): return board_for(model) or board
    return board
# The name of each EA in Jamf. One name each: the setup tools create them under it and everything else finds them by it.
EA_BOARD  = "Content Caching - Board ID"          # only for Macs from before 2016 (ea/ea-board-id.sh)
EA_FOUND  = "Content Caching - Servers Found"     # ea/ea-content-cache-servers-found.sh
EA_STATUS = "Content Caching - Status"            # ea/ea-content-cache-status.sh
EA_ASSETS = "Content Caching - macOS Assets"      # ea/ea-content-cache-macos-assets.sh
EA_EFFECT = "Content Caching - Effectiveness"     # ea/ea-content-cache-effectiveness.sh
EA_READY  = "Content Caching - macOS Readiness"   # Text Field, written by --write
EA_MOBILE_SERVER = "Content Caching - Server"     # mobile device Text Field EA, written by --write
EA_DECODED = "Content Caching - Cached Updates"   # ea/ea-content-cache-decoded.sh, fed by admin/preheat-labels.py; if left a Text Field, --write fills it
SUCATALOG_URL = ("https://swscan.apple.com/content/catalogs/others/"
                 "index-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog")
SUCATALOG_CACHE = _cache("sucatalog.plist", "~/.preheat-sucatalog.plist")
DECODED_CACHE = _cache("decoded.json", "~/.preheat-decoded.json")
_decoded = {}   # asset URL path -> human label, filled by every lookup and by the installer catalog, persisted across runs
try: _decoded.update(json.load(open(DECODED_CACHE)))
except Exception: pass
def save_decoded():
    try: json.dump(_decoded, open(DECODED_CACHE, "w"), indent=0)
    except Exception: pass

# ---------- Apple lookup ----------
_gdmf_cache = {}
_recorded = None      # what Apple answered when a sample fleet was recorded (--inventory-json): used in place of asking
# Apple publishes the previous OS branch (iOS 26.7 once 27 is out) on a second, "alternate" audience. A device that
# holds on the old branch is offered its updates from there, so both are asked and the answers merged.
ALT_AUDIENCE = {"ios": "c724cb61-e974-42d3-a911-ffd4dce11eda", "ipados": "c724cb61-e974-42d3-a911-ffd4dce11eda",
                "visionos": "bb4eeb45-d4f7-4777-bd18-eb38c8443a9c"}

def gdmf_assets(board, model, version, build, platform="mac"):
    key = (platform, board, model, version, build)
    if key in _gdmf_cache: return _gdmf_cache[key]
    if _recorded is not None:      # a recorded fleet: the same answer every time, whatever Apple has released since
        _gdmf_cache[key] = [dict(a, path=urllib.parse.urlparse(a["url"]).path) for a in _recorded.get("|".join(str(k) for k in key)) or []]
        return _gdmf_cache[key]
    asset_type, audience = PLATFORMS[platform]
    out = []; seen = set()
    for n, aud in enumerate([audience] + ([ALT_AUDIENCE[platform]] if platform in ALT_AUDIENCE else [])):
        body = {"ClientVersion": 2, "AssetType": asset_type,
                "AssetAudience": aud, "CertIssuanceDay": "2023-12-10",
                "BuildVersion": build, "HWModelStr": board, "ProductType": model,
                "ProductVersion": version, "CompatibilityVersion": 20, "DelayRequested": False,
                "Supervised": False, "DeviceName": "Mac", "Nonce": str(uuid.uuid4())}
        req = urllib.request.Request(GDMF_URL, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
        try:
            try:
                with urllib.request.urlopen(req, timeout=60) as r: jwt = r.read().decode()
            except urllib.error.HTTPError as e:
                jwt = e.read().decode()
            parts = jwt.strip().split(".")
            if len(parts) != 3: raise RuntimeError(f"unexpected gdmf reply: {jwt[:200]}")
            payload = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
            if payload.get("Status"): raise RuntimeError(f"gdmf {payload.get('Status')}: {payload.get('Message')}")
        except Exception:
            if n == 0: raise
            continue      # the alternate audience is a bonus; never fail a lookup over it
        for a in payload.get("Assets", []):
            url = a.get("__BaseURL", "") + a.get("__RelativePath", "")
            if url in seen: continue
            seen.add(url)
            ver = (a.get("OSVersion") or "").replace("9.9.", "", 1)      # Apple marks full iOS images "9.9.<version>"
            out.append({"version": ver, "build": a.get("Build"), "url": url, "prereq": a.get("PrerequisiteBuild") or "",
                        "path": urllib.parse.urlparse(url).path, "size": a.get("_DownloadSize") or 0})
            osname = OSNAME[platform]
            kind = f"delta from {a.get('PrerequisiteOSVersion')} ({a.get('PrerequisiteBuild')})" if a.get("PrerequisiteBuild") else "full"
            _decoded.setdefault(urllib.parse.urlparse(url).path, f"{osname} {ver} ({a.get('Build')}) {kind} for {model}")
    _gdmf_cache[key] = out
    return out

def vkey(v): return tuple(int(x) for x in (v or "0").split(".") if x.isdigit())

def wanted(assets, target, current=""):
    """Version tuple a target means: '' = newest Apple offers this device, '26' = newest 26.x, '26.7' = exactly that,
    'same' = newest within the major version the device runs now (a Blueprint set to "Ignore major versions")."""
    if target == "same": target = (current or "").split(".")[0]
    if not target: return max((vkey(a["version"]) for a in assets), default=())
    if "." not in target: return max((vkey(a["version"]) for a in assets if vkey(a["version"])[:1] == vkey(target)), default=vkey(target))
    return vkey(target)

def choose(assets, build, target, target_build, current=""):
    """The asset a device on `build` downloads for the target: its delta if Apple offers one, else the full image."""
    if target_build: pick = [a for a in assets if a["build"] == target_build]
    else:
        want = wanted(assets, target, current)
        pick = [a for a in assets if vkey(a["version"]) == want]
    pick.sort(key=lambda a: (a["prereq"] != build, bool(a["prereq"])))     # own delta, then full, then other deltas
    pick = [a for a in pick if a["prereq"] in ("", build)]
    return pick[0] if pick else None

BUILDS_CACHE = _cache("builds.json", "~/.preheat-builds.json")
def builds_for(platform, version):
    """Release builds of an OS version (ios 26.0 -> 23A341, 23A345, ...; one version can have several, some for a single
    hardware family). From AppleDB. Builds that share a leading number share a major version, so one lookup per leading
    number finds the right group and only that group is read in full. Cached locally."""
    try: known = json.load(open(BUILDS_CACHE))
    except Exception: known = {}
    osname = {"audioos": "audioOS"}.get(platform, OSNAME[platform]); tab = known.setdefault(osname, {"majors": {}, "versions": {}, "read": []})
    if version in tab["versions"]: return tab["versions"][version]
    def get(u, tries=3):      # AppleDB is a community service and sometimes times out: retry before giving up
        for n in range(tries):
            try: return urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "preheat/1.0"}), timeout=60).read()
            except Exception:
                if n == tries - 1: raise
                import time; time.sleep(3 * (n + 1))
    ver_of = lambda bld: json.loads(get(f"https://api.appledb.dev/ios/{osname};{bld}.json")).get("version") or ""
    try:
        groups = collections.defaultdict(list)
        for x in json.loads(get("https://api.appledb.dev/ios/index.json")):
            o, _, bld = x.partition(";")
            if o == osname and re.fullmatch(r"\d+[A-Z]\d+", bld): groups[re.match(r"\d+", bld).group()].append(bld)
        major = version.split(".")[0]
        for lead in sorted(groups, key=int, reverse=True):
            if lead not in tab["majors"]:
                try: tab["majors"][lead] = ver_of(sorted(groups[lead])[0]).split(".")[0]
                except Exception: continue
            if tab["majors"][lead] == major and lead not in tab["read"]:
                for bld in sorted(groups[lead], reverse=True):
                    try: tab["versions"].setdefault(ver_of(bld), []).append(bld)
                    except Exception: pass
                tab["read"].append(lead)
            if tab["majors"].get(lead) == major: break
        json.dump(known, open(BUILDS_CACHE, "w"), indent=0)
    except Exception as e: print(f"WARNING: AppleDB did not answer ({e}): {osname} {version} could not be turned into a build, so --from {version} is SKIPPED for {osname} in this run. Run it again.")
    return tab["versions"].get(version, [])

def decode_installers(paths):
    """Label InstallAssistant.pkg paths from Apple's software update catalog (cached locally for a day)."""
    import plistlib
    want = [p for p in paths if p.endswith("/InstallAssistant.pkg") and p not in _decoded]
    if not want: return
    try:
        fresh = os.path.exists(SUCATALOG_CACHE) and (datetime.datetime.now().timestamp() - os.path.getmtime(SUCATALOG_CACHE)) < 86400
        if not fresh:
            with urllib.request.urlopen(SUCATALOG_URL, timeout=120) as r: open(SUCATALOG_CACHE, "wb").write(r.read())
        cat = plistlib.load(open(SUCATALOG_CACHE, "rb"))
    except Exception as e:
        print(f"warning: software update catalog unavailable ({e}); installers stay unidentified"); return
    for pid, prod in cat.get("Products", {}).items():
        for pkg in prod.get("Packages", []):
            path = urllib.parse.urlparse(pkg.get("URL", "")).path
            if path in want:
                label = f"macOS full installer, product {pid}"
                try:
                    dist = prod.get("Distributions", {}).get("English") or next(iter(prod.get("Distributions", {}).values()))
                    with urllib.request.urlopen(dist, timeout=60) as r: x = r.read().decode(errors="ignore")
                    b = re.search(r"<key>BUILD</key>\s*<string>([^<]+)</string>", x); v = re.search(r"<key>VERSION</key>\s*<string>([^<]+)</string>", x)
                    t = re.search(r"<title>([^<]+)</title>", x)
                    if v: label = f"{(t.group(1) if t else 'macOS').strip()} {v.group(1)} ({b.group(1) if b else '?'}) full installer"
                except Exception: pass
                _decoded[path] = label

def full_installers():
    """Every full macOS installer in Apple's software update catalog: [{version, build, title, size, url, path, date}],
    newest first. This is what softwareupdate --fetch-full-installer and Jamf's installer packages download."""
    import plistlib
    fresh = os.path.exists(SUCATALOG_CACHE) and (datetime.datetime.now().timestamp() - os.path.getmtime(SUCATALOG_CACHE)) < 86400
    if not fresh:
        with urllib.request.urlopen(SUCATALOG_URL, timeout=120) as r: open(SUCATALOG_CACHE, "wb").write(r.read())
    cat = plistlib.load(open(SUCATALOG_CACHE, "rb")); out = []
    for pid, prod in cat.get("Products", {}).items():
        pkg = next((p for p in prod.get("Packages", []) if p.get("URL", "").endswith("/InstallAssistant.pkg")), None)
        if not pkg: continue
        e = {"product": pid, "url": pkg["URL"], "path": urllib.parse.urlparse(pkg["URL"]).path, "size": pkg.get("Size") or 0,
             "date": str(prod.get("PostDate", ""))[:10], "version": "", "build": "", "title": "macOS"}
        try:
            dists = prod.get("Distributions", {}); x = urllib.request.urlopen(dists.get("English") or next(iter(dists.values())), timeout=60).read().decode(errors="ignore")
            v = re.search(r"<key>VERSION</key>\s*<string>([^<]+)</string>", x); b = re.search(r"<key>BUILD</key>\s*<string>([^<]+)</string>", x)
            t = re.search(r"<title>([^<]+)</title>", x)
            e.update(version=v.group(1) if v else "", build=b.group(1) if b else "", title=(t.group(1) if t else "macOS").strip())
        except Exception: pass
        if e["version"]:
            _decoded.setdefault(e["path"], f"{e['title']} {e['version']} ({e['build']}) full installer for all Macs"); out.append(e)
    return sorted(out, key=lambda e: vkey(e["version"]), reverse=True)

# ---------- Aerial screen savers ----------
# macOS finds its Aerials through a public config plist that points at a manifest tarball; entries.json inside lists
# every video with its name, category and 4K URL on sylvan.apple.com. ~170 MB each, 164 of them on macOS 27.
AERIAL_CONFIG_URL = "https://configuration.apple.com/configurations/internetservices/aerials/resources-config-27-0.plist"

def aerials():
    """[{name, category, url, path, id}] for every Aerial video macOS offers, from Apple's manifest (cached for a day)."""
    import plistlib, tarfile, io
    path = _cache("aerials-entries.json", "~/.preheat-aerials.json")
    fresh = os.path.exists(path) and (datetime.datetime.now().timestamp() - os.path.getmtime(path)) < 86400
    if not fresh:
        get = lambda u: urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "preheat/1.0"}), timeout=120).read()
        cfg = plistlib.loads(get(AERIAL_CONFIG_URL)); tar = tarfile.open(fileobj=io.BytesIO(get(cfg["resources-url"])))
        member = next(m for m in tar.getmembers() if m.name.endswith("entries.json"))
        open(path, "wb").write(tar.extractfile(member).read())
    d = json.load(open(path)); cats = {c["id"]: c.get("localizedNameKey", "").replace("AerialCategory", "") for c in d.get("categories", [])}
    out = []
    for a in d.get("assets", []):
        url = a.get("url-4K-SDR-240FPS")
        if not url: continue
        cat = ", ".join(cats.get(c, c) for c in a.get("categories", [])) or "Aerial"
        e = {"name": a.get("accessibilityLabel") or a.get("id"), "category": cat, "url": url, "path": urllib.parse.urlparse(url).path, "id": a.get("id")}
        _decoded.setdefault(e["path"], f"Aerial screen saver: {e['name']} ({cat})"); out.append(e)
    return out

def decoded_lines(assets_ea):
    """Turn a server's raw assets EA into human lines."""
    have = parse_assets_ea(assets_ea); decode_installers(list(have))
    out = []
    for line in (assets_ea or "").splitlines():
        p = line.split()
        if len(p) < 4 or not p[-1].startswith("/"): continue
        path = p[-1]; state, size, date = " ".join(p[:-3]), p[-3], p[-2]
        label = _decoded.get(path)
        if not label:
            kind = "macOS update" if "MacSoftwareUpdate" in path else "iOS/iPadOS/tvOS/visionOS update" if "MobileAsset_SoftwareUpdate" in path else "asset"
            label = f"unidentified {kind} {os.path.basename(path)[:12]}... (no device in inventory matches it)"
        out.append(f"{state} {size} {date} {label}")
    return out

# ---------- credentials ----------
KEYCHAIN_SERVICE = "preheat"
CRED_KEYS = ("JAMF_URL", "JAMF_CLIENT_ID", "JAMF_CLIENT_SECRET")

def keychain_get(key):
    """Read one item from the login keychain (service 'preheat', account = key)."""
    import subprocess
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", key, "-w"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""

def keychain_store(values):
    """Store the three credentials in the login keychain. Values go through security's stdin, never argv."""
    import subprocess
    script = "".join(f"add-generic-password -U -s {KEYCHAIN_SERVICE} -a {k} -w {json.dumps(v)}\n" for k, v in values.items())
    r = subprocess.run(["/usr/bin/security", "-i"], input=script, capture_output=True, text=True)
    if r.returncode != 0: sys.exit("keychain store failed: " + (r.stderr or r.stdout).strip())

def load_credentials():
    """Environment variables win (CI, one-off runs); otherwise the login keychain."""
    creds = {k: os.environ.get(k, "") for k in CRED_KEYS}
    if not all(creds.values()):
        for k in CRED_KEYS:
            if not creds[k]: creds[k] = keychain_get(k)
    missing = [k for k in CRED_KEYS if not creds[k]]
    if missing:
        sys.exit("missing credentials: " + ", ".join(missing) +
                 ". Set them as environment variables, or store them once with: python3 admin/readiness-check.py --store-credentials")
    return creds

def jamf_from_credentials():
    c = load_credentials(); return Jamf(c["JAMF_URL"], c["JAMF_CLIENT_ID"], c["JAMF_CLIENT_SECRET"])

# ---------- Jamf ----------
class Jamf:
    def __init__(self, url, cid, secret):
        self.base = url.rstrip("/"); self._cid, self._secret = cid, secret
        self.login()
    def login(self):
        """Jamf's tokens are short-lived (the API client sets the lifetime, often a few minutes) and a long run outlives one."""
        data = urllib.parse.urlencode({"client_id": self._cid, "client_secret": self._secret,
                                       "grant_type": "client_credentials"}).encode()
        req = urllib.request.Request(self.base + "/api/oauth/token", data=data,
                                     headers={"Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=60) as r: t = json.load(r)
        self.token = t["access_token"]; self.expires = time.time() + max(0, int(t.get("expires_in") or 60) - 15)
    def call(self, path, method="GET", body=None):
        if time.time() >= self.expires: self.login()
        for attempt in (1, 2):
            req = urllib.request.Request(self.base + path, method=method,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers={"Authorization": "Bearer " + self.token, "Accept": "application/json",
                                                  "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    txt = r.read().decode(); return json.loads(txt) if txt else {}
            except urllib.error.HTTPError as e:
                if e.code != 401 or attempt == 2: raise
                self.login()
    def cache_status(self, management_id):
        """What the Mac itself last reported about its content cache through declarative device management
        (macOS 27 and later): {"status.active": ("true", datetime), ...}. Empty when there is nothing to read:
        an older macOS, an older Jamf Pro, or an API role without the privilege. Never an error."""
        if not management_id: return {}
        try: items = self.call(f"/api/v1/ddm/{management_id}/status-items").get("statusItems") or []
        except (urllib.error.HTTPError, urllib.error.URLError, ValueError): return {}
        out = {}
        for i in items:
            k = i.get("key") or ""
            if not k.startswith("content-cache."): continue
            try: when = datetime.datetime.fromisoformat((i.get("lastUpdateTime") or "")[:19]).replace(tzinfo=datetime.timezone.utc)
            except ValueError: when = None
            out[k[len("content-cache."):]] = (str(i.get("value") or ""), when)
        return out
    def silent_threshold(self):
        """Minutes without any word from a cache server before it counts as silent: three times the tenant's check-in
        frequency and at least 30. Where the frequency cannot be read (needs Read Computer Check-In) it is 180, three
        times the longest check-in Jamf Pro allows: a shorter guess would call a healthy server silent between check-ins."""
        try: return max(30, 3 * int(self.call("/api/v3/check-in").get("checkInFrequency") or 60))
        except (urllib.error.HTTPError, urllib.error.URLError, ValueError, TypeError): return 180
    def inventory(self):
        page, out = 0, []
        while True:
            q = urllib.parse.urlencode({"page": page, "page-size": 500, "section":
                ["GENERAL", "HARDWARE", "OPERATING_SYSTEM", "USER_AND_LOCATION", "CONTENT_CACHING", "EXTENSION_ATTRIBUTES"]}, doseq=True)
            res = self.call("/api/v1/computers-inventory?" + q)
            out += [normalize(c) for c in res.get("results", [])]
            page += 1
            if page * 500 >= res.get("totalCount", 0): break
        return out

    def group_members(self, name):
        """Ids in a Smart or Static group of that name: ({computer ids}, {mobile device ids}). Either kind may not exist."""
        out = []
        for path, top, key in (("computergroups", "computer_group", "computers"), ("mobiledevicegroups", "mobile_device_group", "mobile_devices")):
            try: out.append({str(d["id"]) for d in self.call(f"/JSSResource/{path}/name/{urllib.parse.quote(name)}")[top][key]})
            except urllib.error.HTTPError: out.append(None)
        return out

    def mobile_inventory(self):
        page, out = 0, []
        while True:
            q = urllib.parse.urlencode({"page": page, "page-size": 500, "section":
                ["GENERAL", "HARDWARE", "USER_AND_LOCATION", "EXTENSION_ATTRIBUTES"]}, doseq=True)
            res = self.call("/api/v2/mobile-devices/detail?" + q)
            out += [normalize_mobile(d) for d in res.get("results", [])]
            page += 1
            if page * 500 >= res.get("totalCount", 0): break
        return out

def normalize_mobile(d):
    g = d.get("general", {}); h = d.get("hardware", {}); loc = d.get("userAndLocation", {})
    model = h.get("modelIdentifier") or ""
    served = ""
    for ea in (d.get("extensionAttributes") or []) + (g.get("extensionAttributes") or []) + (h.get("extensionAttributes") or []) + (loc.get("extensionAttributes") or []):
        if ea.get("name") == EA_MOBILE_SERVER and ea.get("value"): served = ea["value"][0]
    return {"id": d.get("mobileDeviceId") or d.get("id"), "name": g.get("displayName") or d.get("name"),
            "model": model, "platform": platform_of(model),
            "version": g.get("osVersion"), "build": g.get("osBuild"),
            "last_inventory": (g.get("lastInventoryUpdateDate") or "")[:10],
            "ip": g.get("ipAddress") or "", "site": "", "building": loc.get("building") or "",
            "board": board_for(model), "caches_found": "", "cache_guid": "", "cache_status": "",
            "assets_ea": "", "ready_ea_id": None, "served_ea": served}

def ea_value(c, name):
    for ea in c.get("extensionAttributes", []) + c.get("general", {}).get("extensionAttributes", []):
        if ea.get("name") == name:
            v = ea.get("values") or []; return (v[0] if v else ""), ea.get("definitionId")
    return "", None

def mac_board(model):
    """A Mac's board from its model identifier alone (AppleDB), for Macs that have not reported the Board ID EA, or
    where that EA is not installed. Empty for the few old Intel models that came with more than one board."""
    b = board_for(model) if model else ""
    return b if b and len(_board_count.get(model, ())) == 1 else ""

def cache_status_line(c):
    """One line about this Mac as a cache server, from Jamf's own Content Caching inventory (collected from every Mac
    on macOS 10.15.4 or later, no EA needed): "Not a content cache" | "Active; guid ...; ip ...; port ...; public ...;
    free ...; used ...; status OK" | "Inactive (LOWSPACE; ...); guid ...". Every Mac has a server GUID and a cache
    status of OK, cache or not, so only 'activated' says that a Mac is a cache server. "" if Jamf sent no such section."""
    cc = c.get("contentCaching") or {}
    if cc.get("activated") is None: return ""
    gb = lambda b: f"{(b or 0)/1e9:.1f} GB"
    guid = cc.get("serverGuid") or "?"; g = c.get("general", {})
    if not cc["activated"]:      # never a cache: status OK. Storage gone: caching switches itself off and reports a problem
        st = cc.get("cacheStatus") or "OK"
        return "Not a content cache" if st == "OK" else f"Inactive ({st}; caching switched itself off); guid {guid}"
    if not cc.get("active"):
        why = "; ".join(x for x in (cc.get("cacheStatus") or "?", cc.get("registrationError") or cc.get("startupStatus") or "") if x and x != "OK") or "not running"
        return f"Inactive ({why}); guid {guid}"
    return (f"Active; guid {guid}; ip {g.get('lastReportedIp') or '?'}; port {cc.get('port') or '?'}; public {cc.get('publicAddress') or '?'}; "
            f"free {gb(cc.get('cacheBytesFree'))}; used {gb(cc.get('actualCacheBytesUsed') or cc.get('cacheBytesUsed'))}; status {cc.get('cacheStatus') or '?'}")

def normalize(c):
    g = c.get("general", {}); loc = c.get("userAndLocation", {})
    status = cache_status_line(c) or ea_value(c, EA_STATUS)[0]      # Jamf's own section (collected just after inventory), else the status EA
    m = re.search(r"guid ([0-9A-Fa-f-]{36})", status)
    ipm = re.search(r"\bip ([0-9.,]+)", status); pubm = re.search(r"\bpublic ([0-9.]+)", status)
    return {"id": c.get("id"), "name": g.get("name"), "model": c.get("hardware", {}).get("modelIdentifier"),
            "platform": "mac", "ip": g.get("lastReportedIp") or g.get("lastIpAddress") or "",
            "management_id": g.get("managementId") or "", "inventory_time": g.get("reportDate") or "",
            "last_contact": g.get("lastContactTime") or "",
            "last_inventory": (g.get("reportDate") or "")[:10],
            "version": c.get("operatingSystem", {}).get("version"), "build": c.get("operatingSystem", {}).get("build"),
            "site": ((g.get("site") or {}).get("name") or "").replace("None", ""), "building": loc.get("building") or "",
            "board": ea_value(c, EA_BOARD)[0].strip() or mac_board(c.get("hardware", {}).get("modelIdentifier")), "caches_found": ea_value(c, EA_FOUND)[0],
            "cache_guid": m.group(1).upper() if m else "", "cache_status": status,
            "cache_ips": ipm.group(1).split(",") if ipm else [], "cache_public_ip": pubm.group(1) if pubm else "",
            "assets_ea": ea_value(c, EA_ASSETS)[0], "ready_ea_id": ea_value(c, EA_READY)[1]}

def parse_time(t):
    """A Jamf time such as 2026-09-29T00:17:46.011Z, which is UTC, as a datetime; None if there is none."""
    m = re.match(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d", t or "")
    return datetime.datetime.fromisoformat(m.group(0)).replace(tzinfo=datetime.timezone.utc) if m else None

def last_heard(c, live=None):
    """The latest moment Jamf heard from this Mac in any way: a check-in, an inventory update or a DDM status report.
    A Mac that is off, or off the network, sends none of them, and nothing in its record changes: no Smart Group
    moves and no alert is sent. This is the only sign."""
    return max([t for t in (parse_time(c.get("last_contact")), parse_time(c.get("inventory_time")), (live or {}).get("as_of_time")) if t], default=None)

def live_cache(items, inventory_time=""):
    """Read Jamf.cache_status() into plain facts. The status items change when the cache changes state, so they are
    newer than inventory whenever something happened in between. (The size figures, info.*, are only refreshed when the
    declaration sets DeclarativeStatusInterval, so they are not used here.)
    -> None if there is nothing to read, else {"on", "as_of", "line", "changed_since_inventory", "problem"}"""
    val = lambda k: (items.get(k) or ("", None))[0]
    when = lambda k: (items.get(k) or ("", None))[1]
    if "status.active" not in items and "status.activated" not in items: return None
    activated, active = val("status.activated") == "true", val("status.active") == "true"
    times = [t for k, (v, t) in items.items() if k.startswith("status.") and t]
    state_time = max([t for t in (when("status.active"), when("status.activated")) if t], default=None)
    as_of = max(times, default=None)
    registered = val("status.registration-status") == "1"
    problem = ""
    if not activated: problem = "content caching is switched off"
    elif not active: problem = "content caching is on but not running" + (f" ({val('status.cache-status')})" if val("status.cache-status") not in ("", "OK") else "")
    elif not registered: problem = "not registered with Apple" + (f" ({val('status.registration-error')}, code {val('status.registration-response-code')})" if val("status.registration-error") else "")
    try: inv = datetime.datetime.fromisoformat(inventory_time.replace("Z", "+00:00")[:32]) if inventory_time else None
    except ValueError: inv = None
    if inv and inv.tzinfo is None: inv = inv.replace(tzinfo=datetime.timezone.utc)
    local = lambda t: t.astimezone().strftime("%Y-%m-%d %H:%M") if t else "?"
    line = ("running, registered with Apple" if not problem else problem) + f", address {val('status.private-addresses') or '?'} port {val('status.port') or '?'}"
    # Jamf returns each peer as "{address=10.0.0.3, port=49152, healthy=true, friendly=true, identifier=<GUID>, version=265}"
    peer_list = []
    for rec in re.findall(r"\{([^{}]*)\}", val("peers")) or ([val("peers")] if val("peers") else []):
        f = dict(kv.split("=", 1) for kv in re.split(r",\s*", rec) if "=" in kv)
        g = re.search(r"[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}", f.get("identifier") or f.get("guid") or rec)
        if g and f.get("_removed") != "true": peer_list.append({"guid": g.group(0).upper(), "address": f.get("address", ""), "healthy": f.get("healthy", "true") == "true"})
    return {"on": not problem, "as_of": local(as_of), "as_of_time": as_of, "since": local(state_time), "line": line, "problem": problem,
            "changed_since_inventory": bool(inv and state_time and state_time > inv),
            "guid": val("status.server-guid").upper(), "peers": val("peers"), "parents": val("parents"),
            "peer_guids": [x["guid"] for x in peer_list if x["healthy"] and x["guid"] != val("status.server-guid").upper()],
            "peer_list": peer_list}

def parse_assets_ea(text):
    out = {}
    for line in (text or "").splitlines():
        p = line.split()
        if len(p) >= 4 and p[-1].startswith("/"):
            out[p[-1]] = " ".join(p[:-3]) if p[0] == "PARTIAL" else p[0]
    return out

def parse_served(text):
    """mobile 'served by' EA -> {GUID: (server name, last-seen date or None)}"""
    out = {}
    for part in (text or "").split(";"):
        m = re.search(r"^\s*(.*?)\s+guid\s+([0-9A-Fa-f-]{36})(?:\s+seen\s+(\d{4}-\d{2}-\d{2}))?", part)
        if m:
            try: dt = datetime.date.fromisoformat(m.group(3)) if m.group(3) else None
            except ValueError: dt = None
            out[m.group(2).upper()] = (m.group(1).strip(), dt)
    return out

def found_guids(text):
    return {p.split()[0].upper() for p in (text or "").splitlines() if re.match(r"[0-9A-Fa-f-]{36} ", p)}

def favored_guids(text):
    """Servers this Mac's DNS marks as favored (Apple's fss record): while one of them is up, the Mac uses no other."""
    return {p.split()[0].upper() for p in (text or "").splitlines() if re.match(r"[0-9A-Fa-f-]{36} ", p) and " favored" in p and "last-seen" not in p}

# ---------- sites with several public addresses, favored caches, peers ----------
def parse_ranges(text):
    """'203.0.113.10-203.0.113.19, 198.51.100.7, 10.0.0.0/24' -> [(low, high)] as integers. What cannot be read is left out."""
    import ipaddress
    out = []
    for part in re.split(r"[,;\s]+", text or ""):
        if not part or part == "more": continue
        try:
            if "-" in part: a, b = part.split("-", 1); lo, hi = int(ipaddress.ip_address(a)), int(ipaddress.ip_address(b))
            elif "/" in part: n = ipaddress.ip_network(part, strict=False); lo, hi = int(n[0]), int(n[-1])
            else: lo = hi = int(ipaddress.ip_address(part))
            out.append((min(lo, hi), max(lo, hi)))
        except ValueError: continue
    return out

def in_ranges(ip, ranges):
    import ipaddress
    try: n = int(ipaddress.ip_address((ip or "").strip()))
    except ValueError: return False
    return any(lo <= n <= hi for lo, hi in ranges)

def show_ranges(ranges):
    import ipaddress
    f = lambda n: str(ipaddress.ip_address(n))
    return ", ".join(f(lo) if lo == hi else f"{f(lo)}-{f(hi)}" for lo, hi in ranges) or "none"

def dns_line(text):
    """The 'dns:' line of the servers-found EA -> (public ranges, favored ranges): what this Mac read from Apple's
    content caching TXT records in its own DNS."""
    for line in (text or "").splitlines():
        if line.startswith("dns:"):
            pub = re.search(r"public ([^;]*)", line); fav = re.search(r"favored ([^;]*)", line)
            return parse_ranges(pub.group(1) if pub else ""), parse_ranges(fav.group(1) if fav else "")
    return [], []

def txt_records(name):
    """TXT strings for a DNS name, through dig or nslookup (Python has no TXT lookup of its own). None if there are none."""
    import subprocess, shutil
    unescape = lambda t: re.sub(r"\\(\d{3}|.)", lambda m: chr(int(m.group(1))) if m.group(1).isdigit() else m.group(1), t)
    for tool, argv in (("dig", ["+short", "+time=3", "+tries=1", "TXT", name]), ("nslookup", ["-type=TXT", "-timeout=3", name])):
        exe = shutil.which(tool)
        if not exe: continue
        try: out = subprocess.run([exe] + argv, capture_output=True, text=True, timeout=15).stdout
        except Exception: continue
        found = ["".join(unescape(q) for q in re.findall(r'"((?:[^"\\]|\\.)*)"', line)) for line in out.splitlines() if '"' in line]
        found = [f for f in found if re.match(r"(prs|prn|fss|fsn)=", f)]
        return found or None
    return None

def packed_ranges(raw):
    """Apple's compact form (prn, fsn): a tag byte, then one address (0x14, 0x16) or a first and a last (0x24, 0x26)."""
    import ipaddress
    b = raw.encode("latin-1"); i = 0; out = []; more = False
    while i < len(b):
        tag = b[i]; i += 1
        if tag == 0x2b: more = True; continue
        count, size = tag >> 4, {4: 4, 6: 16}.get(tag & 0x0f)
        if count not in (1, 2) or not size or i + count * size > len(b): break
        vals = [int(ipaddress.ip_address(b[i + k * size:i + (k + 1) * size])) for k in range(count)]; i += count * size
        out.append((min(vals), max(vals)))
    return out, more

def dns_site(domain):
    """Apple's content caching TXT records in one DNS domain (_aaplcache._tcp, then _aaplcache1 ... 24) -> (public, favored)."""
    pub, fav = [], []
    for i in range(25):
        recs = txt_records(f"_aaplcache{i or ''}._tcp.{domain.strip('.')}")
        if not recs: break
        more = False
        for r in recs:
            key, val = r.split("=", 1)
            if key in ("prs", "fss"): got = parse_ranges(val); more = more or val.rstrip().endswith("more")
            else: got, m = packed_ranges(val); more = more or m
            (pub if key.startswith("p") else fav).extend(got)
        if not more: break
    return pub, fav

def collect_sites(comps, public_ranges=(), dns_domains=()):
    """Every set of public addresses that counts as one site: given by hand, read from DNS, or reported by the Macs
    themselves (the 'dns:' line of the servers-found EA). -> [{"public", "favored", "source"}]"""
    sites = []
    def add(pub, fav, source):
        if not pub and not fav: return
        for st in sites:
            if st["public"] == pub:
                st["favored"] = st["favored"] or fav; st["seen"] += 1; return
        sites.append({"public": pub, "favored": fav, "source": source, "seen": 1})
    for spec in public_ranges: add(parse_ranges(spec), [], "--public-ranges")
    for dom in dns_domains:
        pub, fav = dns_site(dom)
        if pub or fav: add(pub, fav, f"DNS TXT records of {dom}")
        else: print(f"--dns-domain {dom}: no content caching TXT record found (_aaplcache._tcp.{dom}); give the addresses with --public-ranges if this Mac cannot see that DNS")
    for c in comps:
        pub, fav = dns_line(c.get("caches_found"))
        add(pub, fav, "reported by Macs on that network")
    return sites

# ---------- main ----------
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", help="macOS version to check readiness for (default: newest Apple offers)")
    ap.add_argument("--target-build", help="exact build to check for (e.g. 26B123), as pinned in a DDM declaration; overrides --target")
    ap.add_argument("--max-age-days", type=int, default=30,
                    help="ignore Macs whose last Jamf inventory is older than this (default 30); they are not on the network. 0 = keep all")
    ap.add_argument("--platforms", default="",
                    help="add mobile platforms: a comma list of ios,ipados,tvos,visionos, or 'all'. Macs are always included")
    ap.add_argument("--group-by", choices=["locator", "building", "subnet"], default="locator",
                    help="how a device is matched to a server. locator: the Mac reports which server it uses (Macs only; "
                         "mobile devices fall back to same-public-IP-as-server, which is Apple's own rule, then subnet, "
                         "then building). building: same Jamf building as the server. subnet: device IP in the server's subnet")
    ap.add_argument("--subnet-bits", type=int, default=24, help="prefix length for subnet matching (default 24)")
    ap.add_argument("--sticky-days", type=int, default=90,
                    help="a device stays 'served by' a cache server for this many days after it was last seen using it (default 90)")
    ap.add_argument("--write", action="store_true", help="store the summary in each cache server's readiness EA")
    ap.add_argument("--preheat-plan", metavar="FILE", help="write a JSON plan of every MISSING/PARTIAL asset per server, for admin/preheat.sh")
    ap.add_argument("--cohort", action="append", metavar="GROUP=VERSION", default=[],
                    help="devices in this Jamf group (computer or mobile, Smart or Static) are judged against this version instead of "
                         "--target: '26' = the newest 26.x Apple offers them, '26.7' = exactly that, 'same' = the newest within each "
                         "device's current major version (what a Blueprint set to Ignore major versions enforces). Repeat for more groups; the first "
                         "match wins. For fleets where one group holds on the previous OS while the rest move on")
    ap.add_argument("--preheat-models", metavar="MODELS",
                    help="with --preheat-plan: also plan for hardware that is not in inventory yet, a list of model "
                         "identifiers, e.g. \"iPhone18,3 Mac17,5\" (commas or spaces between them both work), or a whole family: "
                         "all, mac, iphone, ipad, appletv, visionpro. Without --from these are treated as new hardware: full images")
    ap.add_argument("--from", dest="preheat_from", metavar="VERSIONS",
                    help="the OS version(s) the --preheat-models devices will be on, e.g. 26.7 or 26.6,26.7 (or 26.7:23H24 to name "
                         "the build). Devices download a delta from their current build, so this picks the right file")
    ap.add_argument("--preheat-xcode", metavar="VERSION",
                    help="with --preheat-plan: also plan the simulator runtimes and Metal toolchain this Xcode version wants "
                         "(27.0, or latest), for developer Macs on each server's network. iOS by default; --xcode-platforms adds "
                         "tvos, watchos, visionos. Uses Apple's public simulator index, so Xcode need not be installed here")
    ap.add_argument("--xcode-platforms", default="ios", help="comma list for --preheat-xcode: ios, tvos, watchos, visionos, or all (default ios)")
    ap.add_argument("--xcode-betas", action="store_true", help="let --preheat-xcode pick beta simulator runtimes")
    ap.add_argument("--preheat-installers", metavar="VERSIONS",
                    help="with --preheat-plan: also plan full macOS installers (InstallAssistant.pkg, what softwareupdate "
                         "--fetch-full-installer and Jamf installer packages download), for erase-and-install and rebuild work. "
                         "'latest' = the newest of each major Apple still offers; '27' = the newest 27.x; '27.0,26.7' = exactly those; 'all' = every one")
    ap.add_argument("--preheat-aerials", metavar="CATEGORIES",
                    help="with --preheat-plan: also plan Aerial screen saver videos (164 in all, about 80 GB; 0.5 GB on average, the largest 1.5 GB): a comma list of "
                         "categories (landscapes, cities, underwater, space, mac, dynamic), or all")
    ap.add_argument("--preheat-server", metavar="NAME_OR_GUID", help="limit --preheat-models to cache servers whose name or GUID contains this (default: every server)")
    ap.add_argument("--inventory-json", help="use this JSON list of normalized computers instead of Jamf")
    ap.add_argument("--public-ranges", action="append", default=[], metavar="RANGES",
                    help="for a site that reaches the internet from more than one public address: all of them, as in the site's "
                         "DNS TXT record, e.g. \"203.0.113.10-203.0.113.19,198.51.100.7\". A mobile device coming from any of them "
                         "is matched to the caches registered from any of them. Repeat for each site. Not needed where Macs on "
                         "the site report the ranges themselves (servers-found EA, 'dns:' line)")
    ap.add_argument("--dns-domain", action="append", default=[], metavar="DOMAIN",
                    help="read a site's public and favored ranges from Apple's content caching TXT records in this DNS domain "
                         "(_aaplcache._tcp.DOMAIN), the way devices do. Needs dig or nslookup, and a Mac that can see that DNS. Repeat for each site")
    ap.add_argument("--record-answers", action="store_true",
                    help="with --inventory-json: ask Apple now and store its answers in that file. From then on the file gives "
                         "the same result whatever Apple releases, which is what a sample or a test needs")
    ap.add_argument("--silent-minutes", type=int, metavar="N",
                    help="a cache server Jamf has not heard from for this long (no check-in, inventory or status report) is "
                         "NOT READY: it is off or off the network, and nothing else in Jamf will say so. Default: three times "
                         "your check-in frequency and at least 30; 180 if the API role cannot read the frequency. 0 = do not check")
    ap.add_argument("--assume-peers", action="store_true",
                    help="treat cache servers that share a public address (or site) and a subnet as peers even when they do not "
                         "report each other. Peers hand each other content, so a file on any of them counts. Without this, only "
                         "peers a cache reports itself (macOS 27) are used")
    ap.add_argument("--store-credentials", action="store_true",
                    help="prompt for the Jamf URL, API client ID and secret and store them in the macOS login keychain, then exit")
    args = ap.parse_args()
    if args.store_credentials:
        import getpass
        vals = {"JAMF_URL": input("Jamf Pro URL (https://yourorg.jamfcloud.com): ").strip().rstrip("/"),
                "JAMF_CLIENT_ID": input("API client ID: ").strip(),
                "JAMF_CLIENT_SECRET": getpass.getpass("API client secret (not echoed): ").strip()}
        keychain_store(vals); print(f"stored in the login keychain under service '{KEYCHAIN_SERVICE}'"); return

    if (args.preheat_models or args.preheat_xcode or args.preheat_installers or args.preheat_aerials) and not args.preheat_plan: sys.exit("--preheat-models, --preheat-xcode, --preheat-installers and --preheat-aerials need --preheat-plan FILE to write to")
    plats = set(PLATFORMS) if args.platforms == "all" else {"mac"} | {p.strip() for p in args.platforms.split(",") if p.strip()}
    bad = plats - set(PLATFORMS)
    if bad: sys.exit(f"unknown platform(s): {', '.join(bad)}; choose from {', '.join(PLATFORMS)}")
    if args.inventory_json:
        data = json.load(open(args.inventory_json)); jamf = None
        # a plain list of devices, or {"devices": [...], "apple_answers": {...}} as --record-answers writes it
        comps = data["devices"] if isinstance(data, dict) else data
        recorded_devices = json.loads(json.dumps(comps))
        if isinstance(data, dict) and "apple_answers" in data and not args.record_answers:
            global _recorded; _recorded = data["apple_answers"]
        for c in comps:
            c.setdefault("platform", platform_of(c.get("model"))); c.setdefault("ip", "")
            if not c.get("board"): c["board"] = board_for(c.get("model"))
            ipm = re.search(r"\bip ([0-9a-fA-F.:,]+)", c.get("cache_status") or ""); pubm = re.search(r"\bpublic ([0-9a-fA-F.:]+)", c.get("cache_status") or "")
            c.setdefault("cache_ips", ipm.group(1).split(",") if ipm else []); c.setdefault("cache_public_ip", pubm.group(1) if pubm else "")
    else:
        jamf = jamf_from_credentials()
        comps = jamf.inventory()
        if plats - {"mac"}:
            try: comps += jamf.mobile_inventory()
            except urllib.error.HTTPError as e: print(f"warning: mobile device inventory not readable (HTTP {e.code}); Macs only")
    comps = [c for c in comps if c.get("platform") in plats or c.get("cache_guid")]
    for spec in args.cohort:      # GROUP=VERSION: members are judged against VERSION
        group, _, ver = spec.rpartition("=")
        if not group or not re.fullmatch(r"same|\d+(\.\d+)*", ver): sys.exit(f"--cohort '{spec}': expected GROUP NAME=VERSION, e.g. \"Hold on 26=26\"")
        macs, mobiles = jamf.group_members(group) if jamf else (None, None)
        if jamf and macs is None and mobiles is None: sys.exit(f"--cohort: no computer or mobile device group named '{group}' that this API client can see. Check the spelling; "
                                                                      "a Static group also needs Read Static Computer Groups / Read Static Mobile Device Groups on the API role "
                                                                      "(python3 admin/doctor.py shows which are missing)")
        n = 0
        for c in comps:
            ids = macs if c.get("platform") == "mac" else mobiles
            if c.get("cohort"): continue
            if (ids is not None and str(c.get("id")) in ids) or group in (c.get("groups") or []): c["cohort"] = (group, ver); n += 1
        print(f"Cohort '{group}' -> {ver}: {n} device(s)")

    if args.max_age_days:
        cutoff = (datetime.date.today() - datetime.timedelta(days=args.max_age_days)).isoformat()
        stale = [c for c in comps if c.get("last_inventory") and c["last_inventory"] < cutoff]
        comps = [c for c in comps if c not in stale]
        if stale: print(f"Ignoring {len(stale)} Mac(s) with no inventory in {args.max_age_days} days: " + ", ".join(c["name"] for c in stale))
    servers = [c for c in comps if c["cache_guid"] or parse_assets_ea(c["assets_ea"])]
    if not servers: sys.exit("No cache servers found: Jamf's Content Caching inventory shows no Mac with content caching switched on. Nothing to check.")

    # ---- assign client Macs to servers ----
    def same_subnet(ip, ips, bits):
        try:
            import ipaddress
            net = lambda a: ipaddress.ip_network(f"{a}/{bits}", strict=False)
            return any(ip and a and net(ip) == net(a) for a in ips)
        except ValueError: return False
    sites = collect_sites(comps, args.public_ranges, args.dns_domain)
    site_of = lambda ip: {i for i, st in enumerate(sites) if ip and in_ranges(ip, st["public"])}
    for st in sites:
        print(f"Site with public addresses {show_ranges(st['public'])}" + (f", favored caches {show_ranges(st['favored'])}" if st["favored"] else "") + f" ({st['source']})")
    for s in servers:      # what each cache says about itself through DDM: read once, used for peers and in the report
        s["ddm"] = live_cache(jamf.cache_status(s.get("management_id")), s.get("inventory_time") or "") if jamf else None
    silent_after = (jamf.silent_threshold() if args.silent_minutes is None else args.silent_minutes) if jamf else 0
    for s in servers:      # a server nobody has heard from: off, or off the network
        s["heard"] = last_heard(s, s["ddm"])
        s["quiet_minutes"] = int((datetime.datetime.now(datetime.timezone.utc) - s["heard"]).total_seconds() // 60) if s["heard"] else 0
        s["silent"] = bool(silent_after and s["heard"] and s["quiet_minutes"] > silent_after)
    by_guid = {s["cache_guid"]: s for s in servers if s["cache_guid"]}
    peers = {g: {} for g in by_guid}      # guid -> {peer guid: how we know}
    for s in servers:
        for g in (s.get("peers") or []) + ((s["ddm"] or {}).get("peer_guids") or []):
            g = g.upper()
            if g in by_guid and g != s["cache_guid"] and s["cache_guid"]:
                peers[s["cache_guid"]][g] = "reported by the cache"; peers[g].setdefault(s["cache_guid"], "reported by the cache")
    if args.assume_peers:
        for a in servers:
            for b in servers:
                if a is b or not a["cache_guid"] or not b["cache_guid"] or b["cache_guid"] in peers[a["cache_guid"]]: continue
                same_site = (a.get("cache_public_ip") and a.get("cache_public_ip") == b.get("cache_public_ip")) or (site_of(a.get("cache_public_ip")) & site_of(b.get("cache_public_ip")))
                if same_site and any(same_subnet(x, b.get("cache_ips") or [], args.subnet_bits) for x in a.get("cache_ips") or []):
                    peers[a["cache_guid"]][b["cache_guid"]] = "assumed: same public address and subnet"
    members = {s["name"]: [] for s in servers}; assigned = set()
    for c in comps:
        hits = []
        for s in servers:
            mode = args.group_by
            if mode == "locator" and not c.get("caches_found"):   # no locator EA (mobile devices): use Apple's own rule,
                if c.get("ip") and s.get("cache_public_ip"): mode = "public-ip"   # same public IP as the server
                elif c.get("ip") and s.get("cache_ips"): mode = "subnet"
                else: mode = "building"
            if mode == "locator": hit = s["cache_guid"] and s["cache_guid"] in found_guids(c["caches_found"])
            elif mode == "public-ip":      # the same public address, or two addresses of one site
                hit = c.get("ip") == s.get("cache_public_ip") or bool(site_of(c.get("ip")) & site_of(s.get("cache_public_ip")))
            elif mode == "subnet": hit = same_subnet(c.get("ip"), s.get("cache_ips") or [], args.subnet_bits)
            else: hit = c["building"] and c["building"] == s["building"]
            sticky = False
            if not hit and c.get("platform") != "mac" and s["cache_guid"]:   # mobile: keep a recent sighting alive
                prev = parse_served(c.get("served_ea")).get(s["cache_guid"])
                if prev and prev[1] and (datetime.date.today() - prev[1]).days <= args.sticky_days: sticky = True
            if hit or sticky: hits.append((s, bool(hit)))
        # Favored caches (Apple's fss record): while one of them is up, a device uses no other.
        live = [s for s, now in hits if now]
        if c.get("platform") == "mac": fav = [s for s in live if s["cache_guid"] in favored_guids(c.get("caches_found"))]
        else:
            ranges = [r for i in site_of(c.get("ip")) for r in sites[i]["favored"]]
            fav = [s for s in live if ranges and any(in_ranges(a, ranges) for a in s.get("cache_ips") or [])]
        if fav: hits = [(s, now) for s, now in hits if s in fav or not now]
        for s, now in hits:
            if now: c.setdefault("matched_now", set()).add(s["cache_guid"])
            members[s["name"]].append(c); assigned.add(c["name"])
    unassigned = [c for c in comps if c["name"] not in assigned and c["name"] not in members]

    extra = []      # --preheat-models: (model, platform, board, from version, from build)
    want = args.preheat_models or ""
    words = {w.lower() for w in re.findall(r"\b(all|mac|iphone|ipad|appletv|visionpro)\b", want, re.I)}
    ids = re.findall(r"[A-Za-z]+\d+,\d+", want)      # identifiers contain a comma themselves (iPhone18,3)
    junk = re.sub(r"[A-Za-z]+\d+,\d+|\b(all|mac|iphone|ipad|appletv|visionpro)\b", "", want, flags=re.I).strip(" ,;")
    if junk: print(f"--preheat-models: could not read '{junk}'; use model identifiers such as iPhone18,3, or all / mac / iphone / ipad / appletv / visionpro")
    if words:      # a whole family: every model AppleDB lists since 2013 (Apple Watch and HomePod only when named by identifier)
        fam = {"mac": "mac", "iphone": "ios", "ipad": "ipados", "appletv": "tvos", "visionpro": "visionos"}
        keep = set(fam.values()) if "all" in words else {fam[w] for w in words}
        board_for("")
        try:
            for d in json.load(open(BOARD_CACHE)):
                rel = d.get("released"); rel = (rel[0] if isinstance(rel, list) and rel else rel) or ""
                di = d.get("identifier") or []; di = [di] if isinstance(di, str) else di
                for m in di:
                    if str(rel) >= "2013" and platform_of(m) in keep and board_for(m) and m not in ids: ids.append(m)
        except Exception as e: print(f"--preheat-models: cannot read the AppleDB model list ({e})")
        print(f"--preheat-models {' '.join(sorted(words))}: {len(ids)} models")
    froms = [f.strip() for f in (args.preheat_from or "").split(",") if f.strip()]
    quiet = len(ids) > 12      # a family run reports totals, not a line per model and version
    def resolve(model):
        """[(model, platform, board, from version, from build)] for one model, plus the messages it produced."""
        plat, board = platform_of(model), board_for(model); msgs = []
        if not plat or not board: return [], [f"--preheat-models: {model} is not a model identifier AppleDB knows (expected e.g. iPhone18,3 or Mac17,5); skipped"]
        got = []
        for f in froms:      # one --from list can serve several platforms; a version that is not this platform's is skipped
            fver, _, fbuild = f.partition(":")
            cands = [fbuild] if fbuild else builds_for(plat, fver)
            for bld in cands:      # the build of that version Apple offers THIS model a delta from
                try:
                    if any(a["prereq"] == bld for a in gdmf_assets(board, model, fver, bld, plat)): got.append((fver, bld)); break
                except Exception: pass
            else:
                if cands: msgs.append(f"--from {fver}: Apple offers {model} no delta from it; the full image covers it")
        if froms and not got:
            try: newest = max((vkey(a["version"]) for a in gdmf_assets(board, model, NO_VERSION, "0", plat)), default=())
            except Exception: newest = ()
            if newest and any(vkey(f.partition(":")[0]) >= newest for f in froms):
                return [], msgs + [f"--preheat-models: {model} on {args.preheat_from} already runs the newest OS Apple offers it; nothing to preheat"]
            msgs.append(f"--from: nothing in '{args.preheat_from}' gives {model} a delta; planned as a full image")
        return [(model, plat, board, fver, fbuild) for fver, fbuild in got or [("", "")]], msgs
    if ids:
        for plat in {platform_of(m) for m in ids if platform_of(m)}:      # warm the version -> build table once, not per thread
            for f in froms:
                if ":" not in f: builds_for(plat, f.partition(":")[0])
        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor(8) as ex:
            for rows, msgs in ex.map(resolve, ids):
                extra += rows
                if not quiet:
                    for m in msgs: print(m)
    xcode = []      # --preheat-xcode: [(name, platform key, {url,path,size,build})]
    if args.preheat_xcode:
        xp = set(XCODE_PLATFORMS) if args.xcode_platforms == "all" else {p.strip() for p in args.xcode_platforms.split(",") if p.strip()}
        bad = xp - set(XCODE_PLATFORMS)
        if bad: sys.exit(f"--xcode-platforms: unknown {', '.join(bad)}; choose from {', '.join(XCODE_PLATFORMS)} or all")
        try: wants = xcode_wants(args.preheat_xcode, xp, args.xcode_betas)
        except Exception as e: sys.exit(f"--preheat-xcode: cannot read Apple's simulator index ({e})")
        if not wants: sys.exit(f"--preheat-xcode: Apple's index lists no simulator runtime for Xcode {args.preheat_xcode}")
        for kind, plat, name, build, size in wants:
            a = gdmf_xcode(kind, plat, build)
            if a: xcode.append((name, plat, a))
            else: print(f"--preheat-xcode: Apple's lookup offers no file for {name}; skipped")
        print(f"--preheat-xcode {args.preheat_xcode}: {len(xcode)} file(s), {sum(a['size'] for _, _, a in xcode)/1e9:.1f} GB")
    installers = []      # --preheat-installers: full macOS installers from Apple's catalog
    if args.preheat_installers:
        try: allinst = full_installers()
        except Exception as e: sys.exit(f"--preheat-installers: cannot read Apple's software update catalog ({e})")
        want = args.preheat_installers.strip().lower()
        if want == "all": installers = allinst
        elif want == "latest":
            seen = set()
            for e in allinst:
                if e["version"].split(".")[0] not in seen: seen.add(e["version"].split(".")[0]); installers.append(e)
        else:
            for w in [x.strip() for x in want.split(",") if x.strip()]:
                hit = [e for e in allinst if e["version"] == w] or [e for e in allinst if e["version"].startswith(w + ".")] or [e for e in allinst if e["version"].split(".")[0] == w]
                if hit: installers.append(hit[0])
                else: print(f"--preheat-installers: Apple's catalog has no full installer for macOS {w}")
        print(f"--preheat-installers {args.preheat_installers}: {len(installers)} installer(s), {sum(e['size'] for e in installers)/1e9:.1f} GB: " + ", ".join(f"{e['version']} ({e['build']})" for e in installers))
    aerial = []      # --preheat-aerials
    if args.preheat_aerials:
        try: allaer = aerials()
        except Exception as e: sys.exit(f"--preheat-aerials: cannot read Apple's Aerial manifest ({e})")
        want = {w.strip().lower() for w in args.preheat_aerials.split(",") if w.strip()}
        aerial = allaer if "all" in want else [e for e in allaer if any(w in e["category"].lower() for w in want)]
        if not aerial: sys.exit(f"--preheat-aerials: no category matches '{args.preheat_aerials}'; the manifest has: " + ", ".join(sorted({c for e in allaer for c in e["category"].split(", ")})))
        print(f"--preheat-aerials {args.preheat_aerials}: {len(aerial)} video(s), about {len(aerial) * 0.49:.0f} GB (sizes are not in the manifest; all 164 measured 2026-09-27: 79.7 GB, 0.49 on average, from under 0.1 to 1.5 GB)")
    if args.preheat_server: servers_for_extra = [s for s in servers if args.preheat_server.lower() in (s["name"] + " " + (s["cache_guid"] or "")).lower()]
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    print(f"Inventory: {len(comps)} devices ({', '.join(sorted(plats))}), {len(servers)} cache server(s), grouping by {args.group_by}.")
    values = {}; plan = []
    for s in servers:
        have = parse_assets_ea(s["assets_ea"]); macs = members[s["name"]]
        label = ", ".join(x for x in (s["site"], s["building"]) if x) or "no site/building set"
        print(f"\n### {s['name']}  [{label}]  guid {s['cache_guid'] or '?'}  {s['cache_status'] or ''}")
        live = s.get("ddm")
        mine = peers.get(s["cache_guid"]) or {}
        peer_have = {}      # path -> name of a peer that holds it whole
        for g, how in mine.items():
            pr = by_guid[g]; up = not (pr.get("ddm") and not pr["ddm"]["on"]) and (pr.get("cache_status") or "").startswith("Active") and not pr.get("silent")
            print(f"    peer: {pr['name']} ({how})" + ("" if up else ", not running: its content is not counted"))
            if up:
                for path, state in parse_assets_ea(pr["assets_ea"]).items():
                    if state == "COMPLETE": peer_have.setdefault(path, pr["name"])
        if s.get("silent"):
            print(f"    NOT HEARD FROM since {s['heard'].astimezone().strftime('%Y-%m-%d %H:%M')}: no check-in, inventory or status report for {s['quiet_minutes']} minutes (limit {silent_after}). What follows is what Jamf last knew")
        if live:
            print(f"    reported by the Mac itself (DDM, {live['as_of']}): {live['line']}")
            if live["changed_since_inventory"] and live["on"] != (s.get("cache_status") or "").startswith("Active"):
                print(f"    note: the cache changed state at {live['since']}, after the last inventory; the file list below is older than that")
        byplat = collections.Counter(c.get("platform") for c in macs)
        print(f"    serves {len(macs)} device(s) {dict(byplat)}; {sum(1 for v in have.values() if v == 'COMPLETE')} complete OS asset(s) cached")
        combos = collections.defaultdict(list); noboard = 0
        for c in macs:
            if c["board"] and c["model"] and c["build"] and c["version"] and c.get("platform"):
                combos[(c["platform"], c["board"], c["model"], c["version"], c["build"], c.get("cohort") or ("", ""))].append(c["name"])
            else: noboard += 1
        if noboard: print(f"    {noboard} device(s) skipped: missing board ID / model / OS data")
        ok = partial = missing = dev_ok = dev_total = via_peer = 0
        for (plat, board, model, version, build, (cgroup, cver)), names in sorted(combos.items()):
            n = len(names); head = f"    [{plat}] {model} ({board}) on {version} ({build}) x{n}" + (f" [{cgroup} -> {cver}]" if cgroup else "") + ": "
            target, target_build = (cver, "") if cgroup else (args.target, args.target_build)
            try: assets = gdmf_assets(lookup_board(model, board), model, version, build, plat)
            except Exception as e: print(head + f"lookup error: {e}"); continue
            if not assets: print(head + "already current (Apple offers nothing for this device)"); continue
            if target_build and build == target_build: print(head + "already on that build"); continue
            want = wanted(assets, target, version)
            if not target_build and want and vkey(version) >= want: print(head + ("already current" if not cgroup else f"already on {version}, nothing newer wanted")); continue
            a = choose(assets, build, target, target_build, version)
            if not a: print(head + (f"Apple offers no asset with build {target_build} for this hardware/build" if target_build else f"Apple offers this device no {target or 'newer'} update from {version}")); continue
            st = have.get(a["path"], "MISSING"); dev_total += n
            if st != "COMPLETE" and a["path"] in peer_have:      # a peer on the same network hands it over: no download from Apple
                print(head + f"needs {a['version']} ({a['build']}) {'delta' if a['prereq'] else 'full'} {a['size']/1e9:.1f} GB -> COMPLETE on peer {peer_have[a['path']]} (here: {st})")
                st = "COMPLETE"; via_peer += 1
            else:
                print(head + f"needs {a['version']} ({a['build']}) {'delta' if a['prereq'] else 'full'} {a['size']/1e9:.1f} GB -> {st}")
            if st != "COMPLETE":
                plan.append({"server": s["name"], "server_guid": s["cache_guid"], "platform": plat, "model": model, "board": board,
                             "from_version": version, "from_build": build, "to_version": a["version"], "to_build": a["build"],
                             "devices": n, "size": a["size"], "url": a["url"], "state": st})
            if st == "COMPLETE": ok += 1; dev_ok += n
            elif st.startswith("PARTIAL"): partial += 1
            else: missing += 1
        for model, plat, board, fver, fbuild in (extra if not args.preheat_server or s in servers_for_extra else []):      # hardware nobody here owns yet: plan only, never part of readiness
            head = f"    [extra {plat}] {model} ({board}) " + (f"from {fver} ({fbuild}): " if fbuild else "new hardware: ")
            try: assets = gdmf_assets(board, model, fver or NO_VERSION, fbuild or "0", plat)
            except Exception as e: print(head + f"lookup error: {e}"); continue
            a = choose(assets, fbuild, args.target, args.target_build)
            if not a:
                if not quiet: print(head + "Apple offers nothing (not released yet, or this model cannot run the target)")
                continue
            st = have.get(a["path"], "MISSING"); where = ""
            if st != "COMPLETE" and a["path"] in peer_have: st, where = "COMPLETE", f" on peer {peer_have[a['path']]}"
            if not quiet or st != "COMPLETE": print(head + f"{a['version']} ({a['build']}) {'delta' if a['prereq'] else 'full'} {a['size']/1e9:.1f} GB -> {st}{where}")
            if st != "COMPLETE" and not any(x["url"] == a["url"] and x["server_guid"] == s["cache_guid"] for x in plan):
                plan.append({"server": s["name"], "server_guid": s["cache_guid"], "platform": plat, "model": model, "board": board,
                             "from_version": fver or "new", "from_build": fbuild, "to_version": a["version"], "to_build": a["build"],
                             "devices": 0, "size": a["size"], "url": a["url"], "state": st})
        for name, plat, a in (xcode if not args.preheat_server or s in servers_for_extra else []):      # Xcode components: plan only
            st = have.get(a["path"], "MISSING")
            print(f"    [xcode] {name} {a['size']/1e9:.1f} GB -> {st}")
            if st != "COMPLETE" and not any(x["url"] == a["url"] and x["server_guid"] == s["cache_guid"] for x in plan):
                plan.append({"server": s["name"], "server_guid": s["cache_guid"], "platform": "xcode", "model": name, "board": "",
                             "from_version": "", "from_build": "", "to_version": args.preheat_xcode, "to_build": a["build"],
                             "devices": 0, "size": a["size"], "url": a["url"], "state": st})
        for e in (installers if not args.preheat_server or s in servers_for_extra else []):      # full installers: plan only
            st = have.get(e["path"], "MISSING")
            print(f"    [installer] {e['title']} {e['version']} ({e['build']}) {e['size']/1e9:.1f} GB -> {st}")
            if st != "COMPLETE" and not any(x["url"] == e["url"] and x["server_guid"] == s["cache_guid"] for x in plan):
                plan.append({"server": s["name"], "server_guid": s["cache_guid"], "platform": "installer", "model": f"{e['title']} {e['version']}", "board": "",
                             "from_version": "", "from_build": "", "to_version": e["version"], "to_build": e["build"],
                             "devices": 0, "size": e["size"], "url": e["url"], "state": st})
        for e in (aerial if not args.preheat_server or s in servers_for_extra else []):      # Aerials: plan only
            st = have.get(e["path"], "MISSING")
            if st != "COMPLETE" and not any(x["url"] == e["url"] and x["server_guid"] == s["cache_guid"] for x in plan):
                plan.append({"server": s["name"], "server_guid": s["cache_guid"], "platform": "aerial", "model": f"{e['name']} ({e['category']})", "board": "",
                             "from_version": "", "from_build": "", "to_version": "", "to_build": "",
                             "devices": 0, "size": 490_000_000, "url": e["url"], "state": st})
        if aerial: print(f"    [aerials] {sum(1 for e in aerial if have.get(e['path']) == 'COMPLETE')} of {len(aerial)} cached")
        total = ok + partial + missing
        if total == 0: val = f"READY (nothing pending for {len(macs)} devices)"
        elif ok == total: val = f"READY {ok}/{total} combos, {dev_ok} devices" + (f" ({via_peer} held by a peer)" if via_peer else "")
        # Jamf's "like" ignores case and matches anywhere in the value: no word here may contain PARTIAL or READY by accident
        elif ok == 0: val = f"NOT READY 0/{total} combos, 0/{dev_total} devices ({partial} still downloading)"
        else: val = f"PARTIAL {ok}/{total} combos, {dev_ok}/{dev_total} devices" + (f" ({via_peer} held by a peer)" if via_peer else "")
        if live and not live["on"]:      # the files may be there, but no device can get them
            val = f"NOT READY cache is down: {live['problem']} since {live['since']}"
        if s.get("silent"):      # off, or off the network: whatever Jamf last knew, no device can reach it
            val = f"NOT READY cache server silent since {s['heard'].astimezone().strftime('%Y-%m-%d %H:%M')}"
        values[s["name"]] = val + f" @ {now}"
        print(f"    => {values[s['name']]}")

    if args.record_answers:
        if not args.inventory_json: sys.exit("--record-answers needs --inventory-json")
        answers = {"|".join(str(k) for k in key): [{k: v for k, v in a.items() if k != "path"} for a in assets] for key, assets in sorted(_gdmf_cache.items())}
        json.dump({"recorded": now, "devices": recorded_devices, "apple_answers": answers}, open(args.inventory_json, "w"), indent=1)
        print(f"\nRecorded Apple's answers for {len(answers)} hardware and build combination(s) in {args.inventory_json}")
    if args.preheat_plan:
        json.dump({"generated": now, "sticky_days": args.sticky_days, "assets": plan}, open(args.preheat_plan, "w"), indent=1)
        gb = sum(a["size"] for a in plan) / 1e9
        print(f"\nPreheat plan: {len(plan)} asset(s), {gb:.1f} GB total, written to {args.preheat_plan}")
        for a in plan: print(f"    {a['server']}: [{a['platform']}] {a['model']} {a['from_version']}->{a['to_version']} {a['size']/1e9:.1f} GB ({a['state']})")
    if unassigned:
        by = collections.Counter((c["site"], c["building"]) for c in unassigned)
        print(f"\n### {len(unassigned)} device(s) matched no cache server:")
        for (site, bld), n in by.most_common(): print(f"    {n:4d}  {site or '-'} / {bld or '-'}")

    if args.write:
        if not jamf: sys.exit("--write needs Jamf (not --inventory-json)")
        # mobile devices: record which server they matched (Macs already carry this in their locator EA)
        mobile = [c for c in comps if c.get("platform") and c["platform"] != "mac"]
        if mobile:
            try:
                eas = jamf.call("/api/v1/mobile-device-extension-attributes?page=0&page-size=500").get("results", [])
                ea_id = next((e["id"] for e in eas if e["name"] == EA_MOBILE_SERVER), None)
            except urllib.error.HTTPError: ea_id = None
            if not ea_id: print(f"mobile devices: EA '{EA_MOBILE_SERVER}' not found in Jamf; create it (Text Field) to enable per-office mobile groups")
            else:
                today = datetime.date.today(); n = 0
                for c in mobile:
                    entries = {}
                    for g, (nm, dt) in parse_served(c.get("served_ea")).items():      # previous sightings still inside the window
                        if dt and (today - dt).days <= args.sticky_days: entries[g] = (nm, dt)
                    for s in servers:                                                  # what matched right now
                        if s["cache_guid"] in (c.get("matched_now") or set()): entries[s["cache_guid"]] = (s["name"], today)
                    val = "; ".join(f"{nm} guid {g} seen {dt.isoformat()}" for g, (nm, dt) in sorted(entries.items(), key=lambda kv: kv[1][1], reverse=True)) or "None found"
                    if c.get("served_ea") == val: continue
                    try:
                        jamf.call(f"/api/v2/mobile-devices/{c['id']}", "PATCH",
                                  {"updatedExtensionAttributes": [{"id": str(ea_id), "name": EA_MOBILE_SERVER, "type": "STRING", "value": [val]}]})
                        n += 1
                    except urllib.error.HTTPError as e: print(f"{c['name']}: write failed HTTP {e.code}")
                print(f"mobile devices: wrote '{EA_MOBILE_SERVER}' on {n} device(s)")
        try:
            ceas = jamf.call("/api/v1/computer-extension-attributes?page=0&page-size=500").get("results", [])
            # Written from here only while it is a text field; as a script EA (ea-content-cache-decoded.sh) the server fills it itself.
            decoded_id = next((e["id"] for e in ceas if e["name"] == EA_DECODED and e.get("inputType") != "SCRIPT"), None)
        except urllib.error.HTTPError: decoded_id = None
        for s in servers:
            if not s["ready_ea_id"]: print(f"{s['name']}: EA '{EA_READY}' not on record; create it in Jamf first"); continue
            eas = [{"definitionId": str(s["ready_ea_id"]), "values": [values[s["name"]]]}]
            if decoded_id:
                eas.append({"definitionId": str(decoded_id), "values": ["\n".join(decoded_lines(s["assets_ea"])) or "No OS update assets cached"]})
            jamf.call(f"/api/v1/computers-inventory-detail/{s['id']}", "PATCH", {"extensionAttributes": eas})
            print(f"{s['name']}: wrote readiness EA" + (" and decoded assets EA" if decoded_id else ""))

if __name__ == "__main__":
    try: main()
    except urllib.error.HTTPError as e:
        hint = {401: "Jamf refused the API client: check the client ID and secret, and that the client is enabled",
                403: "the API role lacks a privilege this step needs (docs/SETUP.md lists them per feature)",
                404: "Jamf does not know that address: check JAMF_URL, and that the EA, group or record still exists"}.get(e.code, "unexpected reply")
        sys.exit(f"\nStopped: HTTP {e.code} from {e.url.split('?')[0]}\n  {hint}\n  python3 admin/doctor.py checks the whole setup and says what to fix")
    except urllib.error.URLError as e:
        sys.exit(f"\nStopped: cannot reach a server ({e.reason}). Needs outbound HTTPS to your Jamf Pro, gdmf.apple.com and api.appledb.dev\n  python3 admin/doctor.py --offline tests the two Apple-side services")
    finally: save_decoded()
        