#!/usr/bin/env python3
"""盘点 1.3 四语 APP_DESKTOP 截图 set:数量/状态/重复,自动清理多余并补传缺失"""
import sys, os, json, time, base64, hashlib, io
import urllib.request
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools', 'asc-watch'))
from asc_api import make_token

APP = "6813593104"
VID = "5998abcf-2099-4fb9-8241-36ff9038f1f5"
LOCALES = ["en", "zh-Hans", "zh-Hant", "ja"]
SHOT_IDS = ["01-library", "02-minutes", "03-timeline", "04-privacy", "05-chinese", "06-export"]
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # release/ -> repo

def call(method, path, body=None):
    tok = make_token()
    data = json.dumps(body).encode() if body else None
    r = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, data=data, method=method,
        headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r) as resp: return resp.status, json.load(resp)
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read().decode() or "{}")

code, d = call("GET", f"/v1/appStoreVersions/{VID}/appStoreVersionLocalizations")
loc_ids = {x["attributes"]["locale"]: x["id"] for x in d["data"]}
LOCALES_API = {"en": "en-US"}  # ASC locale = en-US, 本地目录 = en
fix_needed = False
for loc in LOCALES:
    lid = loc_ids[LOCALES_API.get(loc, loc)]
    code, d = call("GET", f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets")
    sid = None
    for s in d["data"]:
        if s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP":
            sid = s["id"]
    if sid is None:
        print(loc, "NO SET!"); fix_needed = True; continue
    code, d = call("GET", f"/v1/appScreenshotSets/{sid}/appScreenshots")
    shots = d["data"]
    names = {}
    states = set()
    for x in shots:
        fn = x["attributes"]["fileName"]
        names.setdefault(fn, []).append(x["id"])
        st = x["attributes"]["assetDeliveryState"]
        states.add(st if isinstance(st, str) else st.get("state", str(st)))
    dups = {k: v for k, v in names.items() if len(v) > 1}
    missing = [f for f in (s + ".png" for s in SHOT_IDS) if f not in names]
    extra = [k for k in names if k not in [s + ".png" for s in SHOT_IDS]]
    print(loc, "count:", len(shots), "| states:", states or "-", "| dups:", list(dups) or "-", "| missing:", missing or "-", "| extra:", extra or "-")
    if dups or missing or extra: fix_needed = True

    # 清重复(保留最后一个)与多余
    for k, ids in list(dups.items()) + [(e, names.get(e, [])) for e in extra]:
        for iid in ids:
            c, _ = call("DELETE", "/v1/appScreenshots/" + iid)
            print("  delete", iid[:8], c)

    # 补传缺失
    for fid in SHOT_IDS:
        fn = fid + ".png"
        if fn in names and fn not in dups: continue
        p = os.path.join(ROOT, "release", "screenshots", loc, fn)
        code, d = call("POST", "/v1/appScreenshots", {
            "data": {"type": "appScreenshots",
                     "attributes": {"fileName": fn, "fileSize": os.path.getsize(p)},
                     "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sid}}}}})
        if code != 201:
            print("  presign fail", loc, fn, code); continue
        up = d["data"]["attributes"]["uploadOperations"][0]
        blob = io.open(p, "rb").read()
        r = urllib.request.Request(up["url"], data=blob[up["offset"]:up["offset"]+up["length"]], method=up.get("method", "PUT"))
        hdrs = up.get("requestHeaders") or {}
        if isinstance(hdrs, list):
            hdrs = {h.get("key") or h.get("name"): h.get("value") for h in hdrs}
        for k2, v2 in hdrs.items(): r.add_header(k2, v2)
        with urllib.request.urlopen(r) as resp: pass
        md5 = base64.b64encode(hashlib.md5(blob).digest()).decode()
        code, _ = call("PATCH", "/v1/appScreenshots/" + d["data"]["id"],
            {"data": {"type": "appScreenshots", "id": d["data"]["id"],
                      "attributes": {"uploaded": True, "sourceFileChecksum": md5}}})
        print("  reupload", loc, fn, code)

print("FIX_NEEDED" if fix_needed else "ALL_CLEAN")
