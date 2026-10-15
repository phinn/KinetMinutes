#!/usr/bin/env python3
"""KinetMinutes 落地页素材 — 照 KinetBrief CPP 打法程序化排版
输出 docs/assets/:
  hero-{en,zh-Hans,zh-Hant}.png  1720×1080 深墨面板 + 真截图 + 特性 chip + 纪要卡 mock
  og.png / og-zh.png             1200×630 分享卡
用法: python3 tools/gen_landing_creative.py [en|zh-Hans|zh-Hant|all]
"""
import os, sys, random, math
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(BASE, "docs", "assets")
os.makedirs(OUT, exist_ok=True)

SRC = {loc: os.path.join(BASE, "release", "screenshots", loc, "01-library.png")
       for loc in ("en", "zh-Hans")}

INK = (13, 17, 26); INK_2 = (23, 30, 44)
AMBER = (232, 178, 90); WAVE = (94, 158, 196)
PAPER = (240, 238, 232); INK_SOFT = (140, 148, 165)
TERRA = (180, 84, 46); TERRA_SOFT = (243, 226, 216)   # 站点主题色,纪要卡内用
GREEN = (74, 124, 89)

F_CN = "/System/Library/Fonts/Hiragino Sans GB.ttc"
F_LAT = "/System/Library/Fonts/Helvetica.ttc"

def font(size, latin=False):
    for p in ([F_LAT] if latin else [F_CN, F_LAT]):
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
    gd.ellipse([int(w*0.55), -int(h*0.2), int(w*1.35), int(h*0.45)], fill=(60, 44, 18))
    gd.ellipse([-int(w*0.2), int(h*0.6), int(w*0.35), int(h*1.2)], fill=(18, 34, 48))
    glow = glow.filter(ImageFilter.GaussianBlur(int(w*0.12)))
    im = ImageChops.add(im, glow)
    d = ImageDraw.Draw(im)
    rnd = random.Random(9)
    for k in range(3):
        yy = int(h * (0.93 + k * 0.022))
        pts = [(x, yy + int(30*(k+1)/3*math.sin(x/150+k))) for x in range(0, w, 24)]
        d.line(pts, fill=WAVE, width=3)
    return im

def place_shot(canvas, shot, box, radius=28, ring=AMBER, ring_w=4):
    x0, y0, x1, y1 = box; bw, bh = x1-x0, y1-y0
    ratio = min(bw/shot.width, bh/shot.height)
    im = shot.resize((int(shot.width*ratio)+1, int(shot.height*ratio)+1), Image.LANCZOS)
    im = im.crop(((im.width-bw)//2, 0, (im.width-bw)//2+bw, bh))
    mask = Image.new("L", (bw, bh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, bw, bh], radius=radius, fill=255)
    canvas.paste(im, box[:2], mask)
    ImageDraw.Draw(canvas).rounded_rectangle(box, radius=radius, outline=ring, width=ring_w)

def wave_badge(d, cx, cy, w=240, h=76, col=WAVE):
    d.rounded_rectangle([cx-w//2, cy-h//2, cx+w//2, cy+h//2], radius=h//2,
                        fill=(20, 30, 40), outline=col, width=3)
    rnd = random.Random(5)
    x = cx - w//2 + 34
    while x < cx + w//2 - 34:
        bh = rnd.randint(12, h-30)
        d.rounded_rectangle([x, cy-bh//2, x+6, cy+bh//2], radius=3, fill=col)
        x += 14

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
    og_line=("Meeting notes,", "written while you talk."), og_sub="Zero upload · On-device AI · macOS",
    og_shot_cap=None),
 'zh-Hans': dict(latin=False, brand="KinetMinutes",
    sub="你只管开会，纪要它来写。",
    chips=["录音不出你的 Mac", "全程离线可用", "自动检测会议开录"],
    shot_cap="会议库 — 全部会议，全文可搜",
    card_title="Q4 规划会", card_dur="32 分钟",
    card_sum=("录制器 v2 本周上线；", "引导页砍到一步"),
    dec=["默认纯本地运行", "Pro 买断制，无订阅"],
    act=[("周五前发审核材料", "沈 · 周五"), ("修复 FTS5 搜索", "凯 · 周一")],
    foot="macOS 14+ · Apple Silicon · 免费开始",
    og_line=("你只管开会，", "纪要它来写。"), og_sub="纯本地 · 端侧 AI · macOS",
    og_shot_cap=None),
 'zh-Hant': dict(latin=False, brand="KinetMinutes",
    sub="你只管開會，紀要它來寫。",
    chips=["錄音不出你的 Mac", "全程離線可用", "自動偵測會議開錄"],
    shot_cap="會議庫 — 全部會議，全文可搜",
    card_title="Q4 規劃會", card_dur="32 分鐘",
    card_sum=("錄製器 v2 本週上線；", "引導頁砍到一步"),
    dec=["預設純本機執行", "Pro 買斷制，無訂閱"],
    act=[("週五前寄審核材料", "沈 · 週五"), ("修復 FTS5 搜尋", "凱 · 週一")],
    foot="macOS 14+ · Apple Silicon · 免費開始",
    og_line=("你只管開會，", "紀要它來寫。"), og_sub="純本機 · 端側 AI · macOS",
    og_shot_cap=None),
 'ja': dict(latin=False, brand="KinetMinutes",
    sub="話しながら、議事録ができる。",
    chips=["録音は Mac の外に出ない", "完全オフライン動作", "会議を自動検出して録音"],
    shot_cap="ライブラリ — 全会議を全文検索",
    card_title="Q4 企画会議", card_dur="32 分",
    card_sum=("レコーダー v2 を今週リリース。", "オンボーディングを1ステップに"),
    dec=["デフォルトで完全ローカル", "Pro は買い切り・サブスクなし"],
    act=[("審査資料を金曜までに送付", "沈 · 金"), ("FTS5 検索を修正", "凯 · 月")],
    foot="macOS 14+ · Apple Silicon · 無料で開始",
    og_line=("話しながら、", "議事録ができる。"), og_sub="ローカル完結 · オンデバイス AI · macOS",
    og_shot_cap=None),
}

def chip(d, x, y, w, text, latin, dot=WAVE):
    d.rounded_rectangle([x, y, x+w, y+64], radius=32, fill=(20, 30, 40), outline=(50, 60, 76), width=2)
    d.ellipse([x+26, y+24, x+40, y+38], fill=dot)
    d.text((x+58, y+32), text, font=font(26, latin), fill=PAPER, anchor="lm")

def minutes_card(d, x0, y0, w, h, T):
    latin = T['latin']
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=28, fill=PAPER)
    pad = 30; ix = x0 + pad; iw = w - pad*2
    # 标题行
    d.ellipse([ix, y0+40, ix+16, y0+56], fill=WAVE)
    d.text((ix+28, y0+48), T['card_title'], font=font(30, latin), fill=(43, 38, 32), anchor="lm")
    d.text((x0+w-pad, y0+50), T['card_dur'], font=font(22, latin), fill=(140, 132, 120), anchor="rm")
    y = y0 + 96
    def label(txt, yy):
        d.text((ix, yy), txt, font=font(20, T['latin']), fill=TERRA, anchor="lm")
        return yy + 34
    def lines(arr, yy, col=(60, 54, 46)):
        for s in arr:
            d.text((ix, yy), s, font=font(24, latin), fill=col, anchor="lm"); yy += 33
        return yy
    y = label("SUMMARY" if latin else "摘要", y)
    y = lines(T['card_sum'], y); y += 12
    y = label("DECISIONS" if latin else "决议", y)
    for s in T['dec']:
        d.line([(ix+2, y+8), (ix+8, y+14), (ix+19, y-2)], fill=GREEN, width=4)
        d.text((ix+30, y), s, font=font(24, latin), fill=(60, 54, 46), anchor="lm"); y += 33
    y += 12
    y = label("ACTION ITEMS" if latin else "待办", y)
    for txt, owner in T['act']:
        d.rounded_rectangle([ix, y-11, ix+22, y+11], radius=6, outline=(120, 112, 100), width=3)
        d.text((ix+34, y), txt, font=font(24, latin), fill=(60, 54, 46), anchor="lm")
        tw = d.textlength(txt, font=font(24, latin))
        ow = d.textlength(owner, font=font(19, latin))
        while tw + ow + 80 > w - pad*2 - 34 and len(txt) > 4:   # 文字压徽章 → 截断加省略号
            txt = txt[:-1]; tw = d.textlength(txt + "…", font=font(24, latin))
        if tw + ow + 80 > w - pad*2 - 34:
            txt += "…"
            d.text((ix+34, y), txt, font=font(24, latin), fill=(60, 54, 46), anchor="lm")
        bx = min(int(ix + 34 + tw + 24), x0 + w - pad - ow - 22)
        d.rounded_rectangle([bx, y-14, bx+ow+22, y+14], radius=14, fill=TERRA_SOFT)
        d.text((bx+ow+11, y), owner, font=font(19, latin), fill=TERRA, anchor="rm")
        y += 36
    # 时间线
    y += 8
    d.line([(ix, y), (ix+iw, y)], fill=(224, 216, 200), width=3)
    step = iw // 5
    for k in range(6):
        cx = ix + k*step
        if k < 3: d.ellipse([cx-7, y-7, cx+7, y+7], fill=AMBER, outline=PAPER, width=2)
        else: d.ellipse([cx-7, y-7, cx+7, y+7], outline=(180, 170, 155), width=3)

def gen_hero(loc):
    T = TEXTS[loc]; W, H = 1720, 1080
    im = ink_bg(W, H); d = ImageDraw.Draw(im)
    d.text((90, 92), T['brand'], font=font(42, True), fill=PAPER, anchor="lm")
    d.text((90, 164), T['sub'], font=font(34, T['latin']), fill=AMBER, anchor="lm")
    wave_badge(d, 90 + int(d.textlength(T['sub'], font=font(34, T['latin']))) + 170, 164)
    shot = Image.open(SRC['en'] if T['latin'] else SRC.get(loc, SRC['en'])).convert("RGB")
    place_shot(im, shot, (90, 240, 1110, 878))
    d = ImageDraw.Draw(im)
    d.text((90, 924), T['shot_cap'], font=font(24, T['latin']), fill=(210, 218, 236), anchor="lm", stroke_width=4, stroke_fill=(13, 17, 28))
    x, w = 1170, 460
    for i, c in enumerate(T['chips']):
        chip(d, x, 240 + i*82, w, c, T['latin'], dot=[WAVE, AMBER, GREEN][i])
    minutes_card(d, x, 500, w, 500, T)
    d = ImageDraw.Draw(im)
    d.text((1630, 1032), T['foot'], font=font(24, T['latin']), fill=(196, 206, 228), anchor="rm", stroke_width=4, stroke_fill=(13, 17, 28))
    p = os.path.join(OUT, f"hero-{loc}.png"); im.save(p); print("saved", p)

def gen_og(loc):
    T = TEXTS[loc]; W, H = 1200, 630
    im = ink_bg(W, H); d = ImageDraw.Draw(im)
    d.text((70, 84), T['brand'], font=font(38, True), fill=PAPER, anchor="lm")
    f_big = font(72, T['latin'])
    d.text((70, 240), T['og_line'][0], font=f_big, fill=PAPER, anchor="lm")
    d.text((70, 330), T['og_line'][1], font=f_big, fill=AMBER, anchor="lm")
    d.text((70, 430), T['og_sub'], font=font(30, T['latin']), fill=INK_SOFT, anchor="lm")
    shot = Image.open(SRC['en'] if loc == 'en' else SRC['zh-Hans']).convert("RGB")
    place_shot(im, shot, (730, 150, 1130, 400), radius=20, ring_w=3)
    d = ImageDraw.Draw(im)
    d.text((70, 560), "phinn.github.io/KinetMinutes", font=font(24, True), fill=AMBER, anchor="lm")
    p = os.path.join(OUT, "og.png" if loc == 'en' else "og-zh.png")
    im.save(p); print("saved", p)

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    locs = {'all': ['en', 'zh-Hans', 'zh-Hant', 'ja']}.get(which, [which])
    for loc in locs:
        gen_hero(loc)
        gen_og(loc)
    print("done")
