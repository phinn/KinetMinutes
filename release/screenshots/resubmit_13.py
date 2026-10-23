#!/usr/bin/env python3
"""等 1.3 四语截图全 COMPLETE 后重新提审:先试 canceled RS 直接 submit,不行就建新 RS"""
import sys, os, json, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools', 'asc-watch'))
from asc_api import make_token
import urllib.request

APP = "6813593104"
VID = "5998abcf-2099-4fb9-8241-36ff9038f1f5"
OLD_RS = "d2084445-0a15-42aa-8703-70130b5f4e8b"

def call(method, path, body=None):
    tok = make_token()
    data = json.dumps(body).encode() if body else None
    r = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, data=data, method=method,
        headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r) as resp: return resp.status, json.load(resp)
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read().decode() or "{}")

def shots_ready():
    code, d = call("GET", f"/v1/appStoreVersions/{VID}/appStoreVersionLocalizations")
    states = set()
    for loc in d["data"]:
        lid = loc["id"]
        c2, d2 = call("GET", f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets")
        for s in d2["data"]:
            c3, d3 = call("GET", f"/v1/appScreenshotSets/{s['id']}/appScreenshots")
            for x in d3["data"]:
                st = x["attributes"]["assetDeliveryState"]
                states.add(st if isinstance(st, str) else st.get("state", str(st)))
    return states

# 1) 轮询素材处理
for i in range(12):
    states = shots_ready()
    print(f"attempt {i} states: {states}")
    if states <= {"COMPLETE"}:
        break
    time.sleep(30)
else:
    print("GIVE_UP: shots not complete"); sys.exit(1)

# 2) 先试旧 RS(canceled) 直接重提
code, d = call("GET", "/v1/reviewSubmissions/" + OLD_RS)
rs_state = d["data"]["attributes"]["state"]
print("old RS state:", rs_state)

code, d = call("PATCH", "/v1/reviewSubmissions/" + OLD_RS,
    {"data": {"type": "reviewSubmissions", "id": OLD_RS, "attributes": {"submitted": True}}})
print("resubmit old RS:", code, d.get("data", {}).get("attributes", {}).get("state"))
if code == 200:
    print("DONE"); sys.exit(0)

# 3) 建新 RS(带版本) → submit
code, d = call("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
    "attributes": {"platform": "MAC_OS"},
    "relationships": {"app": {"data": {"type": "apps", "id": APP}},
                      "appStoreVersionForReview": {"data": {"type": "appStoreVersions", "id": VID}}}}})
print("create RS:", code, json.dumps(d.get("errors", []))[:200])
if code == 409:
    # 已有进行中的 RS,找它
    code, d = call("GET", f"/v1/reviewSubmissions?filter[app]={APP}&filter[platform]=MAC_OS")
    cand = [x for x in d["data"] if x["attributes"]["state"] in ("READY_FOR_REVIEW", "INCOMPLETE", "CANCELED", "WAITING_FOR_REVIEW", "REJECTED")]
    rs = cand[0]["id"] if cand else None
    print("reuse RS:", rs)
else:
    rs = d["data"]["id"]

if rs:
    # item 可能已在,先查
    code, d = call("GET", f"/v1/reviewSubmissions/{rs}/items?include=appStoreVersion")
    has_item = any(i["relationships"]["appStoreVersion"]["data"]["id"] == VID for i in d.get("data", []))
    print("items:", [(i["id"][:8], i["relationships"]["appStoreVersion"]["data"]["id"][:8]) for i in d.get("data", [])], "has_item:", has_item)
    if not has_item:
        code, d = call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems",
            "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": rs}},
                              "appStoreVersion": {"data": {"type": "appStoreVersions", "id": VID}}}}})
        print("add item:", code)
        if code == 201:
            call("PATCH", "/v1/reviewSubmissionItems/" + d["data"]["id"],
                {"data": {"type": "reviewSubmissionItems", "id": d["data"]["id"], "attributes": {"confirmed": True}}})
    code, d = call("PATCH", "/v1/reviewSubmissions/" + rs,
        {"data": {"type": "reviewSubmissions", "id": rs, "attributes": {"submitted": True}}})
    print("submit:", code, d.get("data", {}).get("attributes", {}).get("state"), json.dumps(d.get("errors", []))[:300])
