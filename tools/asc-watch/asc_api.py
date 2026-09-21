#!/usr/bin/env python3
"""ASC API JWT + GET helper. 用 openssl 签 ES256, 不依赖 pyjwt. (沙盒模式, 放仓库 scripts/ 下)"""
import base64, json, subprocess, sys, time, urllib.request, urllib.error, os

KEY = os.path.expanduser("~/.appstoreconnect/private_keys/AuthKey_WGY2HCFK9K.p8")
KID = "WGY2HCFK9K"
ISSUER = "d4da77ce-6781-4aef-acdd-c7480df892d5"
PEM = "scripts/.asc-key.pem"

def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def make_token() -> str:
    # 归一化 p8 -> pkcs8 pem
    raw = open(KEY, "rb").read()
    p = subprocess.run(["openssl", "pkey"], input=raw, capture_output=True)
    if p.returncode != 0:
        sys.exit("openssl pkey failed: " + p.stderr.decode())
    os.makedirs("scripts", exist_ok=True)
    with open(PEM, "wb") as f:
        f.write(p.stdout)
    header = b64url(json.dumps({"alg": "ES256", "kid": KID}).encode())
    payload = b64url(json.dumps({
        "iss": ISSUER,
        "iat": int(time.time()) - 30,
        "exp": int(time.time()) + 1200,
        "aud": "appstoreconnect-v1",
    }).encode())
    signing_input = f"{header}.{payload}".encode()
    p2 = subprocess.run(["openssl", "dgst", "-sha256", "-sign", PEM],
                        input=signing_input, capture_output=True)
    os.remove(PEM)
    if p2.returncode != 0:
        sys.exit("sign failed: " + p2.stderr.decode())
    der = p2.stdout

    def read_int(buf, i):
        # buf[i]=0x02 (INTEGER tag), buf[i+1]=长度, 之后是内容
        ln = buf[i + 1]
        start = i + 2
        return buf[start:start + ln], start + ln

    assert der[0] == 0x30, "not a DER sequence"
    # 外层 SEQUENCE 头(短形式 2 字节)之后是第一个 INTEGER
    rb, i = read_int(der, 2)
    sb, i = read_int(der, i)
    r = int.from_bytes(rb, "big").to_bytes(32, "big")
    s = int.from_bytes(sb, "big").to_bytes(32, "big")
    return f"{header}.{payload}.{b64url(r + s)}"

def api(path: str):
    token = make_token()
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
                                 headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())

if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "/v1/apps?limit=50"
    try:
        out = api(path)
        print(json.dumps(out, ensure_ascii=False))
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode()[:2000])
