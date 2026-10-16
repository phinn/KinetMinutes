#!/usr/bin/env python3
"""替换四语 App Store 截图(6张完整版)。
每个 locale: DELETE 旧全部 → 按 01..06 顺序 POST+UPLOAD+COMMIT。
复用 asc_api.make_token()。"""
import sys, os, json, hashlib, glob, time, urllib.request, urllib.error
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "tools", "asc-watch")))
from asc_api import make_token

BASE = "https://api.appstoreconnect.apple.com"

def call(path, method="GET", body=None, headers=None, raw=None):
    url = path if path.startswith("http") else BASE + path
    req = urllib.request.Request(url, method=method)
    if raw is None:
        req.add_header("Authorization", "Bearer " + make_token())
        if body is not None:
            req.add_header("Content-Type", "application/json")
            req.data = json.dumps(body).encode()
    else:
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        req.data = raw
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req) as r:
                data = r.read()
                return r.status, json.loads(data) if data and r.headers.get("Content-Type","").startswith("application/json") else (data or b"")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(errors="replace")
        except Exception as e:
            if attempt == 3:
                return -1, repr(e)
            time.sleep(2 * (attempt + 1))

def md5_b64(path):
    import base64
    digest = hashlib.md5(open(path, "rb").read()).digest()
    return base64.b64encode(digest).decode()

HERE = os.path.dirname(__file__)
LOCALES = json.load(open(os.path.join(HERE, "locales.json")))

for loc, info in LOCALES.items():
    set_id = info["set"]
    # 清空
    code, out = call(f"/v1/appScreenshotSets/{set_id}/appScreenshots")
    if code == 200:
        for s in out.get("data", []):
            c, _ = call(f"/v1/appScreenshots/{s['id']}", "DELETE")
            print(loc, "DEL", s["id"][:8], c)
    # 上传 01..06
    pngs = sorted(glob.glob(os.path.join(HERE, loc, "0*.png")))
    pngs = [p for p in pngs if not p.endswith("raw-library.png")]
    for i, png in enumerate(pngs):
        fname = os.path.basename(png)
        size = os.path.getsize(png)
        code, out = call("/v1/appScreenshots", "POST", body={
            "data": {"type": "appScreenshots",
                     "attributes": {"fileName": fname, "fileSize": size},
                     "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})
        if code != 201:
            print(loc, fname, "POST FAIL", code, str(out)[:300]); continue
        sid = out["data"]["id"]
        op = out["data"]["attributes"]["uploadOperations"][0]
        code, out = call(op["url"], op["method"], raw=open(png, "rb").read(),
                         headers={h["name"]: h["value"] for h in op["requestHeaders"]})
        print(loc, fname, "UPLOAD", code)
        code, out = call(f"/v1/appScreenshots/{sid}", "PATCH", body={
            "data": {"type": "appScreenshots", "id": sid,
                     "attributes": {"uploaded": True, "sourceFileChecksum": md5_b64(png)}}})
        print(loc, fname, "COMMIT", code)
print("done")
