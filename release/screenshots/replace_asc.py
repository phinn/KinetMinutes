#!/usr/bin/env python3
"""替换四语 App Store 截图为 1.0.1 新 UI。
流程: DELETE 旧 appScreenshots → POST 创建(拿 uploadOperations)→ 二进制 PATCH 上传 → PATCH checksum 提交。
复用 asc_api.make_token()。"""
import sys, os, json, hashlib, urllib.request, urllib.error
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
    import time
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
    png = os.path.join(HERE, loc, "01-library.png")
    size = os.path.getsize(png)
    # 清空该 set 现有全部截图(含历轮孤儿)
    code, out = call(f"/v1/appScreenshotSets/{set_id}/appScreenshots")
    if code == 200:
        for s in out.get("data", []):
            c, _ = call(f"/v1/appScreenshots/{s['id']}", "DELETE")
            print(loc, "DEL", s["id"], c)
    code, out = call("/v1/appScreenshots", "POST", body={
        "data": {"type": "appScreenshots",
                 "attributes": {"fileName": "01-library.png", "fileSize": size},
                 "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})
    if code != 201:
        print(loc, "POST FAIL", code, str(out)[:300]); continue
    new_id = out["data"]["id"]
    op = out["data"]["attributes"]["uploadOperations"][0]
    code, out = call(op["url"], op["method"], raw=open(png, "rb").read(),
                     headers={h["name"]: h["value"] for h in op["requestHeaders"]})
    print(loc, "UPLOAD", code, out if code != 200 else "")
    code, out = call(f"/v1/appScreenshots/{new_id}", "PATCH", body={
        "data": {"type": "appScreenshots", "id": new_id,
                 "attributes": {"uploaded": True, "sourceFileChecksum": md5_b64(png)}}})
    print(loc, "COMMIT", new_id, code)
print("done")
