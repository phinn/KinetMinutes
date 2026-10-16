#!/usr/bin/env python3
"""预铺 1.0.2:创建版本 + 四语 localization + 上传 6×4 截图(版本保持 DEVELOPER_RELEASED 状态,不提交审核)。
用法: python3 prep_102.py
依赖: tools/asc-watch/asc_api.py 的 make_token;截图在 release/screenshots/{loc}/0[1-6]-*.png (2560×1600)
"""
import sys, os, json, time, hashlib, base64, urllib.request, urllib.error

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "asc-watch"))
from asc_api import make_token

APP_ID = "6813593104"
BASE = "https://api.appstoreconnect.apple.com"
LOCALES = ["en-US", "zh-Hans", "zh-Hant", "ja"]
LOCALE_DIRS = {"en-US": "en", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "ja": "ja"}
SHOT_DIR = os.path.join(os.path.dirname(__file__))

def wcall(path, method="GET", body=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Authorization", "Bearer " + make_token())
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body).encode()
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req) as r:
                data = r.read()
                return r.status, json.loads(data) if data else {}
        except urllib.error.HTTPError as e:
            err = e.read().decode(errors="replace")
            if e.code in (429, 500, 502, 503) and attempt < 2:
                time.sleep(15 * (attempt + 1))
                continue
            return e.code, err[:300]
        except Exception as e:
            if attempt < 2:
                time.sleep(10)
                continue
            return -1, str(e)[:300]

def find_or_create_version():
    _, vs = wcall(f"/v1/apps/{APP_ID}/appStoreVersions")
    for d in vs.get("data", []):
        if d["attributes"]["versionString"] == "1.0.2":
            return d["id"], d["attributes"]["appStoreState"]
    body = {"data": {"type": "appStoreVersions", "attributes": {
                        "versionString": "1.0.2",
                        "platform": "MAC_OS",
                        "releaseType": "MANUAL"},
                     "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}}
    c, r = wcall("/v1/appStoreVersions", "POST", body)
    print("create 1.0.2:", c)
    if c != 201:
        print(r); sys.exit(1)
    return r["data"]["id"], r["data"]["attributes"]["appStoreState"]

def ensure_localization(vid, locale):
    _, locs = wcall(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    for d in locs.get("data", []):
        if d["attributes"]["locale"] == locale:
            return d["id"]
    body = {"data": {"type": "appStoreVersionLocalizations",
                     "attributes": {"locale": locale,
                                    "description": " placeholder",
                                    "whatsNew": "优化与修复。"},
                     "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}}
    c, r = wcall("/v1/appStoreVersionLocalizations", "POST", body)
    print(f"loc {locale}: {c}")
    return r["data"]["id"] if c == 201 else None

def find_set(lid, locale):
    _, sets = wcall(f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets")
    for d in sets.get("data", []):
        if d["attributes"]["screenshotDisplayType"] == "APP_DESKTOP":
            return d["id"]
    body = {"data": {"type": "appScreenshotSets",
                     "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
                     "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": lid}}}}}
    c, r = wcall("/v1/appScreenshotSets", "POST", body)
    print(f"set {locale}: {c}")
    return r["data"]["id"] if c == 201 else None

def clear_set(set_id):
    _, shots = wcall(f"/v1/appScreenshotSets/{set_id}/appScreenshots")
    for d in shots.get("data", []):
        wcall(f"/v1/appScreenshots/{d['id']}", "DELETE")

def upload_shot(set_id, path, fname):
    body = {"data": {"type": "appScreenshots",
                     "attributes": {"fileName": fname, "fileSize": os.path.getsize(path)},
                     "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}}
    c, r = wcall("/v1/appScreenshots", "POST", body)
    if c != 201:
        print(f"  POST {fname}: {c}", r); return False
    sid = r["data"]["id"]
    ops = r["data"]["attributes"]["uploadOperations"]
    with open(path, "rb") as f:
        blob = f.read()
    for op in ops:
        req = urllib.request.Request(op["url"], method=op["method"])
        hdrs = op.get("requestHeaders") or {}
        if isinstance(hdrs, list):
            hdrs = {h.get("key") or h.get("name"): h.get("value") for h in hdrs}
        for k, v in hdrs.items():
            req.add_header(k, v)
        off, ln = op["offset"], op["length"]
        req.data = blob[off:off+ln]
        with urllib.request.urlopen(req) as resp:
            resp.read()
    md5 = base64.b64encode(hashlib.md5(blob).digest()).decode()
    c2, _ = wcall(f"/v1/appScreenshots/{sid}", "PATCH",
                  {"data": {"type": "appScreenshots", "id": sid,
                            "attributes": {"uploaded": True, "sourceFileChecksum": md5}}})
    print(f"  {fname}: commit {c2}")
    return c2 == 200

def main():
    vid, state = find_or_create_version()
    print(f"1.0.2 vid={vid} state={state}")
    for locale in LOCALES:
        lid = ensure_localization(vid, locale)
        if not lid: continue
        set_id = find_set(lid, locale)
        if not set_id: continue
        clear_set(set_id)
        d = os.path.join(SHOT_DIR, LOCALE_DIRS[locale])
        files = sorted(f for f in os.listdir(d) if f.startswith("0") and f.endswith(".png") and "raw" not in f)
        print(f"{locale}: 清空后传 {len(files)} 张", flush=True)
        for f in files:
            upload_shot(set_id, os.path.join(d, f), f)

if __name__ == "__main__":
    main()
