#!/usr/bin/env python3
"""KinetMinutes 1.3 上架:建版本 → 挂 build 8 → 四语 metadata(新 whatsNew)→ 换 6 图 ×4 语 → 提审
用法: python3 submit_13.py [status]
"""
import sys, os, json, time, io, base64, hashlib
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools", "asc-watch"))
import urllib.request
from asc_api import make_token

TOK = make_token()
BASE = "https://api.appstoreconnect.apple.com"
APP_ID = "6813593104"
BUILD_ID = "2f7ba01e-7cc8-4775-9aae-56d55a372c00"  # build 8
VER = "1.3"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
LOCALES = ["en", "zh-Hans", "zh-Hant", "ja"]
SC_LOCALES = {"en": "en-US", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "ja": "ja"}

def call(method, path, body=None, raw=None, ctype=None):
    url = path if path.startswith("http") else BASE + path
    data = None
    headers = {"Authorization": "Bearer " + TOK}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    elif raw is not None:
        data = raw
        headers["Content-Type"] = ctype or "application/octet-stream"
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r) as resp:
            txt = resp.read().decode()
            return resp.status, (json.loads(txt) if txt else {})
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")

def meta(loc, name):
    p = os.path.join(ROOT, "release", "metadata", loc, name)
    return io.open(p, encoding="utf-8").read().strip()

SHOT_IDS = ["01-library", "02-minutes", "03-timeline", "04-privacy", "05-chinese", "06-export"]

def status():
    code, d = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?limit=5")
    for v in d.get("data", []):
        a = v["attributes"]
        print(a.get("versionString"), a.get("appVersionState"), v["id"])

def main():
    # 1) 建 1.3
    code, d = call("POST", "/v1/appStoreVersions", {
        "data": {"type": "appStoreVersions", "attributes": {
            "versionString": VER, "platform": "MAC_OS", "releaseType": "MANUAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
    if code == 201:
        vid = d["data"]["id"]; print("created 1.3", vid)
    else:
        print("create:", code, json.dumps(d.get("errors", d), ensure_ascii=False)[:300])
        # 找已有的 1.3(重跑)
        code, d = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?filter[versionString]={VER}&filter[platform]=MAC_OS")
        vid = d["data"][0]["id"]; print("reuse", vid)
    time.sleep(1)
    # 2) 挂 build
    code, d = call("PATCH", f"/v1/appStoreVersions/{vid}", {
        "data": {"type": "appStoreVersions", "id": vid,
                 "relationships": {"build": {"data": {"type": "builds", "id": BUILD_ID}}}}})
    print("attach build:", code)
    # 3) 四语 metadata(ASC 建 1.3 时自动克隆上版本本地化,POST 会 405 → 改 PATCH)
    code, d = call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    meta_ids = {x["attributes"]["locale"]: x["id"] for x in d["data"]}
    for loc in LOCALES:
        l = SC_LOCALES[loc]
        if l in meta_ids:
            code, d = call("PATCH", "/v1/appStoreVersionLocalizations/" + meta_ids[l], {
                "data": {"type": "appStoreVersionLocalizations", "id": meta_ids[l],
                         "attributes": {
                             "whatsNew": meta(loc, "whatsnew.txt"),
                             "description": meta(loc, "description.txt"),
                             "keywords": meta(loc, "keywords.txt"),
                             "promotionalText": meta(loc, "promo.txt"),
                             "supportUrl": "https://kinetapp.github.io/kinetminutes/support-" + loc + ".html"}}})
        else:
            code, d = call("POST", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations", {
                "data": {"type": "appStoreVersionLocalizations",
                         "attributes": {"locale": l,
                                        "whatsNew": meta(loc, "whatsnew.txt"),
                                        "description": meta(loc, "description.txt"),
                                        "keywords": meta(loc, "keywords.txt"),
                                        "promotionalText": meta(loc, "promo.txt"),
                                        "supportUrl": "https://kinetapp.github.io/kinetminutes/support-" + loc + ".html"},
                         "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
        print("meta", loc, code)
    # 4) 截图集:重建(APP_DESKTOP,资源名 appScreenshotSets/appScreenshots)
    code, d = call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    loc_ids = {x["attributes"]["locale"]: x["id"] for x in d["data"]}
    for loc in LOCALES:
        l = SC_LOCALES[loc]; lid = loc_ids[l]
        # 清旧 set
        code, d = call("GET", f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets")
        for s in d.get("data", []):
            if s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP":
                code2, shots = call("GET", f"/v1/appScreenshotSets/{s['id']}/appScreenshots")
                for x in shots.get("data", []):
                    call("DELETE", "/v1/appScreenshots/" + x["id"])
        # 找或建 set
        sid = None
        for s in d.get("data", []):
            if s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP":
                sid = s["id"]
        if sid is None:
            code, d = call("POST", "/v1/appScreenshotSets", {
                "data": {"type": "appScreenshotSets",
                         "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
                         "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": lid}}}}})
            print("set", loc, code)
            sid = d["data"]["id"]
        for i, fid in enumerate(SHOT_IDS):
            fn = os.path.join(ROOT, "release", "screenshots", loc, fid + ".png")
            fname = fid + ".png"
            # presign
            code, d = call("POST", "/v1/appScreenshots", {
                "data": {"type": "appScreenshots",
                         "attributes": {"fileName": fname, "fileSize": os.path.getsize(fn)},
                         "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sid}}}}})
            if code != 201:
                print("  shot presign", fid, code, json.dumps(d.get("errors", []), ensure_ascii=False)[:200]); continue
            up = d["data"]["attributes"]["uploadOperations"][0]
            blob = io.open(fn, "rb").read()
            r = urllib.request.Request(up["url"], data=blob[up["offset"]:up["offset"]+up["length"]], method=up.get("method", "PUT"))
            hdrs = up.get("requestHeaders") or {}
            if isinstance(hdrs, list):
                hdrs = {h.get("key") or h.get("name"): h.get("value") for h in hdrs}
            for k, v in hdrs.items():
                r.add_header(k, v)
            with urllib.request.urlopen(r) as resp:
                print("  upload", fname, resp.status)
            md5 = base64.b64encode(hashlib.md5(blob).digest()).decode()
            code, _ = call("PATCH", "/v1/appScreenshots/" + d["data"]["id"],
                {"data": {"type": "appScreenshots", "id": d["data"]["id"],
                          "attributes": {"uploaded": True, "sourceFileChecksum": md5}}})
            print("  commit", fname, code)
    # 5) 提审
    code, d = call("PATCH", f"/v1/appStoreVersions/{vid}", {
        "data": {"type": "appStoreVersions", "id": vid, "attributes": {"submitted": True}}})
    print("submit:", code)
    code, d = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?filter[versionString]={VER}&filter[platform]=MAC_OS")
    a = d["data"][0]["attributes"]
    print("FINAL:", a["versionString"], a["appVersionState"])

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "status":
        status()
    else:
        main()
