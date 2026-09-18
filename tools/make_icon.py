#!/usr/bin/env python3
"""KinetMinutes App Icon — 波形会议主题。
设计:深空靛蓝背景 + 中心声波纹(渐变青→琥珀),下方一条"纪要"光带。
全幅出血,squircle 由系统遮罩。1024 master → appiconset 全套(显式 sRGB)。
"""
import math, os, struct, zlib
import numpy as np

OUT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ASSETSET = os.path.join(OUT_ROOT, "Resources", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(ASSETSET, exist_ok=True)

SIZE = 1024
SS = 2


def srgb_bytes(arr):
    """float 0-1 HWC ndarray -> PNG bytes with sRGB chunk."""
    h, w = arr.shape[:2]
    data = (np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)
    raw = b"".join(b"\x00" + data[y].tobytes() for y in range(h))

    def chunk(tag, payload):
        c = struct.pack(">I", len(payload)) + tag + payload
        return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"sRGB", b"\x00") + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    return png


def build(size):
    n = size * SS
    y, x = np.mgrid[0:n, 0:n].astype(np.float64)
    x = (x + 0.5) / SS / size      # 0..1
    y = (y + 0.5) / SS / size

    # 背景对角渐变 深靛蓝 → 近黑 + 左上柔光
    t = np.clip(x * 0.65 + y * 0.35, 0, 1)
    bg_r = 0.055 + 0.030 * (1 - t)
    bg_g = 0.065 + 0.040 * (1 - t)
    bg_b = 0.130 + 0.055 * (1 - t)
    glow = np.exp(-(((x - 0.22) ** 2 + (y - 0.18) ** 2) / 0.10))
    img = np.stack([bg_r + glow * 0.05, bg_g + glow * 0.06, bg_b + glow * 0.10], axis=-1)

    # 声波:5 根竖条 + 中线镜像,青→琥珀渐变
    cx, cy = 0.5, 0.46
    bar_w, gap = 0.052, 0.040
    heights = [0.16, 0.26, 0.20, 0.30, 0.14]
    cols = [(0.20, 0.85, 0.95), (0.25, 0.78, 0.98), (0.45, 0.72, 1.00), (1.00, 0.72, 0.25), (1.00, 0.55, 0.30)]
    for i, hh in enumerate(heights):
        bx = cx + (i - 2) * (bar_w + gap)
        top, bot = cy - hh / 2, cy + hh / 2
        m = (x > bx - bar_w / 2) & (x < bx + bar_w / 2) & (y > top) & (y < bot)
        rr = np.clip((y - top) / max(1e-6, hh), 0, 1)
        fade = 0.75 + 0.25 * np.sin(rr * math.pi)
        c = cols[i]
        edge = 0.028
        mm = np.zeros_like(m)
        # 圆角条:距离场
        dy = np.maximum(top + edge - y, y - (bot - edge))
        dx = np.maximum(bx - bar_w / 2 + edge - x, x - (bx + bar_w / 2 - edge))
        dist = np.sqrt(np.maximum(dx, 0) ** 2 + np.maximum(dy, 0) ** 2)
        aa = 1.5 / (SS * size)
        alpha = np.clip((edge - dist) / aa, 0, 1) * (dist <= edge)
        alpha = np.where((dx <= 0) & (dy <= 0), 1.0, alpha)
        for k in range(3):
            img[..., k] = img[..., k] * (1 - alpha * fade) + c[k] * alpha * fade

    # 底部"纪要光带":三条横线,模拟纪要文字
    for j, (ly, lw, alpha0) in enumerate([(0.76, 0.30, 0.9), (0.82, 0.42, 0.65), (0.88, 0.24, 0.45)]):
        lx0 = 0.5 - lw / 2
        m = (y > ly) & (y < ly + 0.018) & (x > lx0) & (x < lx0 + lw)
        a = alpha0 * (0.9 + 0.1 * np.sin(x * 40))
        for k in range(3):
            c = (0.85, 0.88, 0.95)[k]
            img[..., k] = img[..., k] * (1 - m * a) + c * m * a
    return img


master = build(SIZE)
sizes = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}
for name, px in sizes.items():
    # master = SIZE*SS(2048) → 直接 box 双步下采样到 px
    factor = master.shape[0] // px
    small = master.reshape(px, factor, px, factor, 3).mean(axis=(1, 3)) if factor > 1 else master
    with open(os.path.join(ASSETSET, name), "wb") as f:
        f.write(srgb_bytes(small))
    print(name, px)
print("done ->", ASSETSET)
