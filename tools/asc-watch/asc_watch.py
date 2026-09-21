#!/usr/bin/env python3
"""asc_watch.py — ASC 全家桶审核状态看门狗

轮询 6 个 Kinet app 的 appStoreVersions 状态:
- 状态变更 → 追加日志 + macOS 通知
- 目标 KinetZen 变 READY_FOR_SALE → 通知「已上架」
- 变 REJECTED/METADATA_REJECTED/DEVELOPER_REJECTED → 通知 + 尝试拉拒审详情
  (Resolution Center note 正文 v1 API 无端点,走 iris 网页会话,此处只拉 v1 能拿到的
   submission items state + 409 associatedErrors 摘要,note 全文留待人工/后续 iris 脚本)
- 幂等:同状态重复轮询不重复通知(状态记录在 state.json)
"""
import sys, json, os, time, subprocess, urllib.request, urllib.error

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)  # asc_api.py 同目录部署(launchd 环境不依赖 ~/Documents)
from asc_api import make_token

APPS = {
    "6814033986": "KinetRain",       # 2026-09-20 WFR
    "6813897412": "KinetZen",
    "6808698046": "KinetFlashFind",
    "6813423397": "KinetMagicDisk",
    "6813593104": "KinetMinutes",
    "6813776720": "KinetSentinel",
    "6779978181": "KinetMorning",
}
TARGET = "6813593104"
TERMINAL_OK = {"READY_FOR_SALE", "PENDING_DEVELOPER_RELEASE"}
REJECTED = {"REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED", "REJECTED_FROM_REVIEW"}

BASE = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(BASE, "state.json")
LOG_FILE = os.path.join(BASE, "asc_watch.log")


def call(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path, data=data, method=method,
        headers={"Authorization": "Bearer " + make_token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:4000]


def log(msg: str):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


def notify(title: str, body: str):
    try:
        subprocess.run([
            "osascript", "-e",
            f'display notification "{body}" with title "{title}" sound name "Glass"'
        ], timeout=10, check=False)
    except Exception:
        pass


def load_state() -> dict:
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE) as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_state(s: dict):
    with open(STATE_FILE, "w") as f:
        json.dump(s, f, ensure_ascii=False, indent=1)


def fetch_versions(app_id: str):
    code, out = call("GET", f"/v1/apps/{app_id}/appStoreVersions?limit=10")
    if code != 200 or not isinstance(out, dict):
        return None
    rows = []
    for v in out.get("data", []):
        rows.append({
            "id": v["id"],
            "version": v["attributes"]["versionString"],
            "state": v["attributes"]["appStoreState"],
        })
    return rows


def auto_release(app_id: str, name: str, rows: list):
    """过审即自动发布:ACCEPTED/PENDING_DEVELOPER_RELEASE 的 version 补丁成 AUTOMATIC。
    幂等:已是 AUTOMATIC 时 PATCH 无害。目标是「上架闭环不卡人工」。"""
    for v in rows:
        if v["state"] in {"ACCEPTED", "PENDING_DEVELOPER_RELEASE"}:
            code, out = call("PATCH", f"/v1/appStoreVersions/{v['id']}",
                             {"data": {"type": "appStoreVersions", "id": v["id"],
                                       "attributes": {"releaseType": "AUTOMATIC"}}})
            log(f"[AUTO-RELEASE] {name} {v['version']}: PATCH releaseType=AUTOMATIC -> {code}")
            if code == 200:
                notify(f"🚀 {name} 过审自动发布", f"{v['version']} {v['state']} → AUTOMATIC")


def fetch_rejection_reason(app_id: str, name: str) -> str:
    """拉拒审详情(v1 能拿到的全部)+ Resolution Center 直链"""
    reasons = []
    code, out = call("GET", f"/v1/reviewSubmissions?filter[app]={app_id}&sort=-createdDate&limit=2")
    if code == 200 and isinstance(out, dict):
        for s in out.get("data", []):
            a = s["attributes"]
            reasons.append(f"submission {s['id'][:8]} state={a.get('state')}")
            code2, out2 = call("GET", f"/v1/reviewSubmissions/{s['id']}/items")
            if code2 == 200 and isinstance(out2, dict):
                for i in out2.get("data", []):
                    reasons.append(f"  item {i['id'][:8]} {json.dumps(i['attributes'], ensure_ascii=False)[:300]}")
    reasons.append("NOTE 正文: https://appstoreconnect.apple.com/apps/%s/distribution/messages" % app_id)
    return "\n".join(reasons)


def fetch_submission_snapshot(app_id: str):
    """拒审时能从 v1 拿到的全部:submission 状态 + items 状态"""
    code, out = call("GET", f"/v1/reviewSubmissions?filter[app]={app_id}")
    snaps = []
    if code == 200 and isinstance(out, dict):
        for s in out.get("data", []):
            a = s["attributes"]
            item_states = []
            code2, out2 = call("GET", f"/v1/reviewSubmissions/{s['id']}/items")
            if code2 == 200 and isinstance(out2, dict):
                item_states = [i["attributes"].get("state") for i in out2.get("data", [])]
            snaps.append(f"sub[{a.get('state')}] items={item_states}")
    return "; ".join(snaps) if snaps else "(no submission)"


def main():
    state = load_state()
    any_change = False
    for app_id, name in APPS.items():
        versions = fetch_versions(app_id)
        if versions is None:
            log(f"[ERROR] {name}: API fetch failed")
            continue
        cur_sig = "; ".join(f'{v["version"]}={v["state"]}' for v in versions)
        prev_sig = state.get(app_id, {}).get("sig")
        if cur_sig == prev_sig:
            continue  # 无变化
        any_change = True
        prev_state = state.get(app_id, {}).get("states", [])
        cur_states = {v["state"] for v in versions}
        log(f"[CHANGE] {name}: {prev_sig or '(first-run baseline)'} -> {cur_sig}")

        # 通知策略
        if cur_states & REJECTED:
            snap = fetch_rejection_reason(app_id, name)
            log(f"[REJECTED] {name} detail:\n{snap}")
            notify(f"❌ {name} 被拒", f"{cur_sig} | 详情 {LOG_FILE}")
            with open(os.path.join(BASE, f"rejection_{app_id}.txt"), "w") as f:
                f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\n{name}\n{cur_sig}\n{snap}\n")
        elif cur_states & {"ACCEPTED", "PENDING_DEVELOPER_RELEASE"}:
            # 过审 → 自动转 AUTOMATIC 发布(上架闭环核心)
            auto_release(app_id, name, [v for v in versions if v["state"] in {"ACCEPTED", "PENDING_DEVELOPER_RELEASE"}])
            notify(f"✅ {name} 过审", f"{cur_sig} → 自动发布中")
            log(f"[ACCEPTED] {name}: {cur_sig}")
        elif TARGET == app_id and cur_states & TERMINAL_OK:
            notify(f"🎉 {name} 已上架", cur_sig)
            log(f"[LIVE] {name}: {cur_sig}")
        elif (cur_states - set(prev_state or [])) & {"IN_REVIEW"}:
            notify(f"⏳ {name} 审核进展", cur_sig)

        state[app_id] = {"sig": cur_sig, "states": sorted(cur_states), "ts": time.time()}
    if any_change:
        save_state(state)
    # 首跑建立基线
    if not state:
        for app_id in APPS:
            versions = fetch_versions(app_id)
            if versions:
                state[app_id] = {"sig": "; ".join(f'{v["version"]}={v["state"]}' for v in versions),
                                 "states": sorted({v["state"] for v in versions}), "ts": time.time()}
        save_state(state)
        log("[BASELINE] initial state saved")


if __name__ == "__main__":
    main()
