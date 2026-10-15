#!/usr/bin/env python3
"""KinetMinutes ASC 商店截图 2560×1600 — 用落地页同款视觉重绘
深墨面板 + 顶部品牌/标语 + 真实 app 窗口截图(琥珀环框) + 右侧纪要卡 mock + 声波徽章
输出 release/screenshots/{en,zh-Hans,zh-Hant,ja}/01-library.png(2560×1600 sRGB)
用法: python3 tools/gen_asc_screenshots.py [en|zh-Hans|zh-Hant|ja|all]
"""
import os, sys
from PIL import Image, ImageDraw, ImageFont

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(BASE, "release", "screenshots")

INK = (13, 17, 26); INK_2 = (23, 30, 44)
AMBER = (232, 178, 90); WAVE = (94, 158, 196)
PAPER = (240, 238, 232); INK_SOFT = (150, 158, 175)
TERRA = (180, 84, 46); TERRA_SOFT = (243, 226, 216)
GREEN = (74, 124, 89)
CARD_BG = (247, 245, 240)

F_CN = "/System/Library/Fonts/Hiragino Sans GB.ttc"
F_JP = "/System/Library/Fonts/Hiragino Sans GB.ttc"   # 日文也走 Hiragino(含日汉字形),避免 latin 豆腐块反向坑
F_LAT = "/System/Library/Fonts/Helvetica.ttc"

def font(size, latin=False):
    paths = [F_LAT] if latin else [F_CN, F_JP, F_LAT]
    for p in paths:
        try: return ImageFont.truetype(p, size)
        except Exception: continue
    return ImageFont.load_default()

def ink_bg(w, h):
    im = Image.new("RGB", (w, h), INK)
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)], fill=tuple(int(INK[i] + (INK_2[i]-INK[i])*t) for i in range(3)))
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([int(w*0.60), -int(h*0.35), int(w*1.25), int(h*0.45)], fill=(38, 30, 18))
    glow = glow.filter(ImageFilter if False else __import__("PIL.ImageFilter", fromlist=["ImageFilter"]).GaussianBlur(220))
    im = Image.blend(im, Image.composite(glow, im, Image.new("L", (w, h), 110)), 0.55)
    return im

def shot_capture(canvas, shot, box, radius=26, ring_w=4):
    """圆角+描边裁切截图居中放入 box(等比留白填底色)"""
    x0, y0, bw, bh = box
    pad = 6
    im = shot.convert("RGB")
    ratio = max((bw-2*pad)/im.width, (bh-2*pad)/im.height)   # 等比填满 box(允许裁切溢出 box 内)
    im = im.resize((int(im.width*ratio)+1, int(im.height*ratio)+1), Image.LANCZOS)
    im = im.crop(((im.width-(bw-2*pad))//2, (im.height-(bh-2*pad))//2,
                  (im.width-(bw-2*pad))//2+(bw-2*pad), (im.height-(bh-2*pad))//2+(bh-2*pad)))
    mask = Image.new("L", (bw-2*pad, bh-2*pad), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, bw-2*pad-1, bh-2*pad-1], radius=radius, fill=255)
    canvas.paste(im, (x0+pad, y0+pad), mask)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0+pad, y0+pad, x0+bw-pad, y0+bh-pad], radius=radius,
                        outline=AMBER, width=ring_w)
    d.rounded_rectangle([x0, y0, x0+bw, y0+bh], radius=radius+pad,
                        outline=(40, 50, 66), width=2)

def wave_badge(d, cx, cy, w, h, col=WAVE):
    d.rounded_rectangle([cx-w//2, cy-h//2, cx+w//2, cy+h//2], radius=h//2,
                        fill=(20, 30, 40), outline=col, width=3)
    import random
    rnd = random.Random(7)
    x = cx - w//2 + 30
    while x < cx + w//2 - 30:
        bh = rnd.randint(10, h-26)
        d.rounded_rectangle([x, cy-bh//2, x+6, cy+bh//2], radius=3, fill=col)
        x += 13

def minutes_card(canvas, x0, y0, w, h, T):
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=24, fill=CARD_BG,
                        outline=(226, 221, 210), width=2)
    d.rounded_rectangle([x0, y0, x0+w, y0+96], radius=24, fill=(240, 236, 226))
    d.rectangle([x0, y0+70, x0+w, y0+96], fill=(240, 236, 226))
    latin = T.get('latin', False)
    d.text((x0+34, y0+48), T['card_title'], font=font(32, latin), fill=(40, 36, 30), anchor="lm")
    dw = d.textlength(T['card_dur'], font=font(22, latin))
    d.rounded_rectangle([x0+w-34-dw-36, y0+26, x0+w-34, y0+70], radius=22, fill=TERRA_SOFT)
    d.text((x0+w-52, y0+48), T['card_dur'], font=font(22, latin), fill=TERRA, anchor="rm")
    ix = x0 + 34; pad = 34
    y = y0 + 128
    def label(txt, yy):
        d.text((ix, yy), txt, font=font(22, latin), fill=TERRA, anchor="lm")
        return yy + 40
    def lines(arr, yy):
        for s in arr:
            d.text((ix, yy), s, font=font(27, latin), fill=(60, 54, 46), anchor="lm"); yy += 42
        return yy
    y = label("SUMMARY" if latin else T['lbl_sum'], y)
    y = lines(T['card_sum'], y); y += 16
    y = label("DECISIONS" if latin else T['lbl_dec'], y)
    for s in T['dec']:
        d.line([(ix+2, y+10), (ix+10, y+18), (ix+25, y-4)], fill=GREEN, width=5)
        d.text((ix+40, y+2), s, font=font(27, latin), fill=(60, 54, 46), anchor="lm"); y += 42
    y += 16
    y = label("ACTION ITEMS" if latin else T['lbl_act'], y)
    for txt, owner in T['act']:
        d.rounded_rectangle([ix, y-14, ix+28, y+14], radius=8, outline=(120, 112, 100), width=3)
        d.text((ix+44, y+2), txt, font=font(27, latin), fill=(60, 54, 46), anchor="lm")
        tw = d.textlength(txt, font=font(27, latin))
        ow = d.textlength(owner, font=font(22, latin))
        while tw + ow + 100 > w - pad*2 - 44 and len(txt) > 4:
            txt = txt[:-1]; tw = d.textlength(txt + "…", font=font(27, latin))
        if tw + ow + 100 > w - pad*2 - 44:
            txt += "…"
            d.text((ix+44, y+2), txt, font=font(27, latin), fill=(60, 54, 46), anchor="lm")
        bx = min(int(ix + 44 + tw + 28), x0 + w - pad - ow - 26)
        d.rounded_rectangle([bx, y-18, bx+ow+26, y+18], radius=18, fill=TERRA_SOFT)
        d.text((bx+13, y+2), owner, font=font(22, latin), fill=TERRA, anchor="lm")
        y += 46
    # 底部时间轴小条
    ty = y0 + h - 40
    d.line([(ix, ty), (x0+w-pad, ty)], fill=(216, 210, 198), width=3)
    for frac, col in ((0.12, WAVE), (0.45, AMBER), (0.8, GREEN)):
        px = ix + int((x0+w-pad-ix) * frac)
        d.ellipse([px-7, ty-7, px+7, ty+7], fill=col)

TEXTS = {
 'en': dict(latin=True, brand="KinetMinutes",
    sub="Meeting notes, written while you talk.",
    chips=["Zero upload, ever", "Works fully offline", "Auto-detects meetings"],
    shot_cap="Library — every meeting, searchable",
    card_title="Q4 Planning", card_dur="32 min",
    card_sum=("Ship recorder v2 this week;", "onboarding cut to one step"),
    dec=["Local-only by default", "Pro is one-time, no sub"],
    act=[("Send review notes", "Phinn · Fri"), ("Fix FTS5 search bug", "Kai · Mon")],
    foot="macOS 14+ · Apple Silicon · Free to start",
    lbl_sum="SUMMARY", lbl_dec="DECISIONS", lbl_act="ACTION ITEMS"),
 'zh-Hans': dict(latin=False, brand="KinetMinutes",
    sub="你只管开会，纪要它来写。",
    chips=["录音不出你的 Mac", "全程离线可用", "自动检测会议开录"],
    shot_cap="会议库 — 全部会议，全文可搜",
    card_title="Q4 规划会", card_dur="32 分钟",
    card_sum=("录制器 v2 本周上线；", "引导页砍到一步"),
    dec=["默认纯本地运行", "Pro 买断制，无订阅"],
    act=[("周五前发审核材料", "沈 · 周五"), ("修复 FTS5 搜索", "凯 · 周一")],
    foot="macOS 14+ · Apple Silicon · 免费开始",
    lbl_sum="摘要", lbl_dec="决议", lbl_act="待办"),
 'zh-Hant': dict(latin=False, brand="KinetMinutes",
    sub="你只管開會，紀要它來寫。",
    chips=["錄音不出你的 Mac", "全程離線可用", "自動偵測會議開錄"],
    shot_cap="會議庫 — 全部會議，全文可搜",
    card_title="Q4 規劃會", card_dur="32 分鐘",
    card_sum=("錄製器 v2 本週上線；", "引導頁砍到一步"),
    dec=["預設純本機執行", "Pro 買斷制，無訂閱"],
    act=[("週五前寄審核材料", "沈 · 週五"), ("修復 FTS5 搜尋", "凱 · 週一")],
    foot="macOS 14+ · Apple Silicon · 免費開始",
    lbl_sum="摘要", lbl_dec="決議", lbl_act="待辦"),
 'ja': dict(latin=False, brand="KinetMinutes",
    sub="話しながら、議事録ができる。",
    chips=["録音は Mac の外に出ない", "完全オフライン動作", "会議を自動検出して録音"],
    shot_cap="ライブラリ — 全記録を全文検索",
    card_title="Q4 企画会議", card_dur="32 分",
    card_sum=("レコーダー v2 を今週公開；", "オンボーディングを1ステップに"),
    dec=["完全ローカル動作", "Pro は買い切り、サブスク無し"],
    act=[("金曜までに審査資料を送る", "沈 · 金"), ("FTS5 検索を修正", "カイ · 月")],
    foot="macOS 14+ · Apple Silicon · 無料で開始",
    lbl_sum="要約", lbl_dec="決定事項", lbl_act="アクション"),
}

def trim_shot(shot):
    """裁掉截图四周的桌面背景/空白(以角落像素为基准色找 bbox)"""
    import PIL.ImageChops as IC
    rgb = shot.convert("RGB")
    bg = Image.new("RGB", rgb.size, rgb.getpixel((2, 2)))
    diff = IC.difference(rgb, bg).convert("L")
    bbox = diff.point(lambda p: 255 if p > 12 else 0).getbbox()
    if bbox:
        # 收 4px,避免残留阴影边
        x0, y0, x1, y1 = bbox
        return rgb.crop((x0+4, y0+4, x1-4, y1-4))
    return rgb

def gen(loc):
    T = TEXTS[loc]
    W, H = 2560, 1600
    im = ink_bg(W, H)

    # 顶部:品牌 + 声波徽章
    d = ImageDraw.Draw(im)
    d.text((120, 128), T['brand'], font=font(56, True), fill=PAPER, anchor="lm")
    d.text((120, 210), T['sub'], font=font(64, T.get('latin', False)), fill=AMBER, anchor="lm")
    wave_badge(d, W - 420, 170, 300, 84)

    # 主截图区:左侧 app 真窗口(带窗口栏弧角),右侧纪要卡
    shot = trim_shot(Image.open(os.path.join(OUT, loc, "raw-library.png")))
    box = (120, 300, 1620, 1150)
    shot_capture(im, shot, box)

    x, w = 1760, 680
    d = ImageDraw.Draw(im)
    for i, c in enumerate(T['chips']):
        chip(d, x, 360 + i*110, w, c, T.get('latin', False), dot=[WAVE, AMBER, GREEN][i])
    minutes_card(im, x, 760, w, 700, T)

    d = ImageDraw.Draw(im)
    d.text((W - 120, 1490), T['foot'] + "   ·   " + T['shot_cap'],
           font=font(28, T.get('latin', False)), fill=(196, 206, 228), anchor="rm",
           stroke_width=4, stroke_fill=(13, 17, 28))
    out = os.path.join(OUT, loc, "01-library.png")
    im.save(out)
    print("saved", out)

def chip(d, x, y, w, text, latin, dot=WAVE):
    d.rounded_rectangle([x, y, x+w, y+80], radius=40, fill=(24, 32, 46), outline=(52, 62, 80), width=2)
    d.ellipse([x+30, y+28, x+54, y+52], fill=dot)
    d.text((x+76, y+40), text, font=font(36, latin), fill=PAPER, anchor="lm")

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    locs = {'all': ['en', 'zh-Hans', 'zh-Hant', 'ja']}.get(which, [which])
    for loc in locs:
        gen(loc)
    print("done")
