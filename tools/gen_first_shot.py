#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""KinetMinutes 商店首图 v2（2560×1600）

为什么不用整窗截图：release/screenshots/*/raw-library.png 本身就是一张坏裁切
——左侧边栏切在词中间、搜索框留着焦点环、英文界面里日期是中文、正文下面
还有三分之二的空白。整窗塞进去等于把这三处缺陷放大成首图主体。

所以这里只取正文「分段标签 + OVERVIEW + KEY POINTS」那一条横带：不含日期、
不含侧栏、不含焦点环，且几乎不放大（1.24x），文字是清楚的。

用法：/usr/bin/python3 tools/gen_first_shot.py [locale...]
输出：release/screenshots-1.4/<locale>/01-first.png
"""
import os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "release", "screenshots")
OUT = os.path.join(ROOT, "release", "screenshots-1.4")

W, H = 2560, 1600
INK = (13, 17, 28)
INK_2 = (24, 30, 44)
PAPER = (246, 244, 238)
AMBER = (232, 165, 74)
MUTED = (146, 152, 168)
F_CJK = "/System/Library/Fonts/Hiragino Sans GB.ttc"
F_LAT = "/System/Library/Fonts/Helvetica.ttc"

BAND_W = 2260          # 正文带目标宽度
BAND_X = (W - BAND_W) // 2
BAND_Y = 1000   # 横带的垂直中心轴（各语高度不同，统一按中心对齐）

COPY = {
    "en": dict(
        head=["The meeting ends.", "The notes are ready."],
        sub="Summary, decisions and action items — written on your Mac, offline.",
        foot="macOS 14+  ·  Apple Silicon  ·  100% on-device  ·  no upload, no account",
        lat=True,
    ),
    "zh-Hans": dict(
        head=["会开完了，", "纪要已经在了。"],
        sub="摘要、决议、待办——在你自己的 Mac 上生成，不联网。",
        foot="macOS 14+  ·  Apple Silicon  ·  100% 本地运行  ·  零上传，不需账号",
        lat=False,
    ),
    "zh-Hant": dict(
        head=["會開完了，", "紀要已經在了。"],
        sub="摘要、決議、待辦——在你自己的 Mac 上產生，不連網。",
        foot="macOS 14+  ·  Apple Silicon  ·  100% 本機執行  ·  零上傳，不需帳號",
        lat=False,
    ),
    "ja": dict(
        head=["会議が終われば、", "議事録はもうできている。"],
        sub="要約・決定事項・アクションを、この Mac の中で。オフラインで。",
        foot="macOS 14+  ·  Apple Silicon  ·  100% オンデバイス  ·  送信なし、アカウント不要",
        lat=False,
    ),
}


def ink_bg(w, h):
    im = Image.new("RGB", (w, h), INK)
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)], fill=tuple(int(INK[i] + (INK_2[i] - INK[i]) * t) for i in range(3)))
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([int(w * 0.55), -int(h * 0.38), int(w * 1.30), int(h * 0.42)], fill=(40, 31, 18))
    glow = glow.filter(ImageFilter.GaussianBlur(240))
    return Image.blend(im, Image.composite(glow, im, Image.new("L", (w, h), 110)), 0.55)


def font(size, latin, bold=False):
    if latin:
        return ImageFont.truetype(F_LAT, size, index=1 if bold else 0)
    # Hiragino Sans GB: index 0 = W3, index 2 = W6（index 1 是 .Interface 变体，不是粗体）
    return ImageFont.truetype(F_CJK, size, index=2 if bold else 0)


def measure(raw):
    """返回正文带裁切框：(left, top, right, bottom)。top 取日期行之下。"""
    a = np.asarray(Image.open(raw).convert("RGB")).astype(int)
    nw = (a.sum(axis=2) < 700)
    nw[:10, :] = False          # 顶边那条描边
    pane = nw[:, 556:]          # 只右侧正文栏，左侧栏整块丢弃
    rows = np.where(pane.any(axis=1))[0]
    runs, prev = [], None
    for y in rows:
        if prev is None or y - prev > 6:
            runs.append([y, y])
        else:
            runs[-1][1] = y
        prev = y
    if len(runs) < 4:
        raise SystemExit("正文块识别失败: %s" % runs)
    top = runs[1][1] + 22       # runs[1] 是日期行，从它下面开始
    bottom = runs[-1][1] + 26
    # 右边界：正文自然右缘 +30；但 en/zh 不能越过 Rename 按钮左缘（2375，
    # 否则按钮被切一半），ja 的正文一直排到 2537、只有连按钮一起收（2556）
    # 才不会切断句子。两种情况都不许切字。
    seg = nw[250:560, :]
    cs = np.where(seg.any(axis=0))[0]
    cs = cs[cs > 556]
    text_right = int(cs.max())
    # 右边界一律收到 2340（Rename 按钮左缘 2375 之前），而不是贴着文字右缘：
    # 中文正文只到 1728，贴边裁会让卡片只有一半宽、右半幅空掉；按 2340 裁则
    # 卡内自带界面留白，四语卡片宽度一致，放大率仍只有 1.27x（不糊）。
    # 只有 ja 正文排到 2537，必须连按钮一起收到 2556 才不会切断句子。
    right = 2556 if text_right > 2340 else 2340
    return 556, top, right, bottom


def build(loc):
    cfg = COPY[loc]
    raw = os.path.join(SRC, loc, "raw-library.png")
    left, top, right, bottom = measure(raw)
    crop = Image.open(raw).convert("RGB").crop((left, top, right, bottom))

    # 不强行按固定宽度放大：中文正文比英文短，硬拉到 2260 会变成 1.87x 糊字。
    # 统一用「每语各自接近 1.3x」的放大率，宽度随内容走，再水平居中。
    # 放大率夹在 1.10–1.35：中文正文短，硬拉到 2260 会变 1.88x 糊字；
    # 日文正文长，2260 只需 1.13x。宁可宽度不齐，也不要糊。
    scale = min(max(BAND_W / crop.width, 1.10), 1.35)
    band_w = int(round(crop.width * scale))
    band_h = int(round(crop.height * scale))
    band_x = 150
    crop = crop.resize((band_w, band_h), Image.LANCZOS)

    canvas = ink_bg(W, H)
    radius = 24
    mask = Image.new("L", (band_w, band_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, band_w - 1, band_h - 1], radius=radius, fill=255)
    ring = Image.new("RGB", (band_w + 12, band_h + 12), AMBER)
    ring_mask = Image.new("L", ring.size, 0)
    ImageDraw.Draw(ring_mask).rounded_rectangle([0, 0, ring.width - 1, ring.height - 1], radius=radius + 6, fill=255)
    band_y = BAND_Y - band_h // 2
    canvas.paste(ring, (band_x - 6, band_y - 6), ring_mask)
    canvas.paste(crop, (band_x, band_y), mask)

    d = ImageDraw.Draw(canvas)
    bx = BAND_X
    d.text((bx, 235), "KinetMinutes", font=font(46, cfg["lat"], bold=True), fill=AMBER)
    y = 315
    for line in cfg["head"]:
        d.text((bx, y), line, font=font(104, cfg["lat"], bold=True), fill=PAPER)
        y += 122
    d.text((bx, 603), cfg["sub"], font=font(38, cfg["lat"]), fill=MUTED)
    d.text((bx, 1327), cfg["foot"], font=font(32, cfg["lat"]), fill=MUTED)

    outdir = os.path.join(OUT, loc)
    os.makedirs(outdir, exist_ok=True)
    dest = os.path.join(outdir, "01-first.png")
    canvas.save(dest)
    print("%-8s crop=(%d,%d,%d,%d) %dx%d -> band %dx%d @x=%d  %s" % (
        loc, left, top, right, bottom, right - left, bottom - top, band_w, band_h, band_x, dest))


if __name__ == "__main__":
    for loc in (sys.argv[1:] or list(COPY)):
        build(loc)
