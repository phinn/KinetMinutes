#!/usr/bin/env python3
"""KinetMinutes ASC 商店截图 2560×1600 — 1.3 版(基于 1.2 深墨设计语言重绘)
1.2 全部设计资产保留:ink 渐变底、手绘卡(纪要/时间线/隐私/导出)、声波徽章、琥珀环截图、chip
1.3 新增素材:模型库卡(Whisper 模型管理)、统计卡、快捷键卡、四语徽章
每语 8 张:01-library 02-minutes 03-timeline 04-privacy 05-chinese 06-export + 07-models 08-stats
输出 release/screenshots/{en,zh-Hans,zh-Hant,ja}/0*.png (2560×1600 sRGB)
"""
import sys, os, math
from PIL import Image, ImageDraw, ImageFilter

HERE  = os.path.dirname(os.path.abspath(__file__))
ROOT  = os.path.dirname(HERE)
OUT   = os.path.join(ROOT, "release", "screenshots")
W, H  = 2560, 1600

# ---- 调色板(与 1.2 完全一致)----
INK      = (13, 17, 28)     # 深墨底
INK_2    = (24, 30, 44)     # 渐变亮端
PAPER    = (246, 244, 238)  # 主文字(暖白)
CARD_BG  = (252, 251, 248)  # 卡底
AMBER    = (232, 165, 74)   # 品牌琥珀
AMBER_BG = (250, 239, 222)
WAVE     = (124, 156, 196)  # 声波蓝
GREEN    = (94, 156, 108)
TERRA    = (166, 106, 60)
TERRA_SOFT = (244, 232, 216)

F_CN = "/System/Library/Fonts/Hiragino Sans GB.ttc"
F_JP = "/System/Library/Fonts/Hiragino Sans GB.ttc"
F_LAT = "/System/Library/Fonts/Helvetica.ttc"

def font(size, latin=False):
    return ImageFont.truetype(F_LAT if latin else F_CN, size)
from PIL import ImageFont

def ink_bg(w, h):
    im = Image.new("RGB", (w, h), INK)
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)], fill=tuple(int(INK[i] + (INK_2[i]-INK[i])*t) for i in range(3)))
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([int(w*0.60), -int(h*0.35), int(w*1.25), int(h*0.45)], fill=(38, 30, 18))
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    im = Image.blend(im, Image.composite(glow, im, Image.new("L", (w, h), 110)), 0.55)
    return im

def shot_capture(canvas, shot, box, radius=26, ring_w=4):
    """圆角+描边裁切截图居中放入 box(等比放大填满 box,允许裁切溢出)"""
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

def check(d, x, y, col=GREEN, s=9, w=5):
    """手绘对勾(纯矢量,不用字体)"""
    d.line([(x, y), (x+s, y+s*1.2), (x+s*2.6, y-s*1.4)], fill=col, width=w)

def chip(d, x, y, w, text, latin, dot=WAVE):
    d.rounded_rectangle([x, y, x+w, y+80], radius=40, fill=(24, 32, 46), outline=(52, 62, 80), width=2)
    d.ellipse([x+30, y+28, x+54, y+52], fill=dot)
    d.text((x+76, y+40), text, font=font(36, latin), fill=PAPER, anchor="lm")

def chip_row(d, x, y, items, latin):
    cx = x
    for i, c in enumerate(items):
        tw = d.textlength(c, font=font(34, latin))
        w = int(tw + 110)
        chip(d, cx, y, w, c, latin, dot=[WAVE, AMBER, GREEN][i % 3])
        cx += w + 26

def head_block(d, y, head, sub, latin):
    d.text((120, y), head, font=font(92, latin), fill=PAPER, anchor="lm")
    d.text((120, y + 96), sub, font=font(48, latin), fill=AMBER, anchor="lm")

def trim_shot(shot):
    import PIL.ImageChops as IC
    rgb = shot.convert("RGB")
    bg = Image.new("RGB", rgb.size, rgb.getpixel((2, 2)))
    diff = IC.difference(rgb, bg).convert("L")
    bbox = diff.point(lambda p: 255 if p > 12 else 0).getbbox()
    if bbox:
        x0, y0, x1, y1 = bbox
        return rgb.crop((x0+4, y0+4, x1-4, y1-4))
    return rgb

# ---- 1.2 四大卡片(原样保留)----
def minutes_card(canvas, x0, y0, w, h, T):
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=24, fill=CARD_BG, outline=(226, 221, 210), width=2)
    d.rounded_rectangle([x0, y0, x0+w, y0+96], radius=24, fill=(240, 236, 226))
    d.rectangle([x0, y0+70, x0+w, y0+96], fill=(240, 236, 226))
    latin = T.get('latin', False)
    d.text((x0+34, y0+48), T['card_title'], font=font(32, latin), fill=(40, 36, 30), anchor="lm")
    dw = d.textlength(T['card_dur'], font=font(22, latin))
    d.rounded_rectangle([x0+w-34-dw-36, y0+26, x0+w-34, y0+70], radius=22, fill=TERRA_SOFT)
    d.text((x0+w-52, y0+48), T['card_dur'], font=font(22, latin), fill=TERRA, anchor="rm")
    ix = x0 + 34; pad = 34
    y = y0 + 128
    d.text((ix, y), T['lbl_sum'], font=font(22, latin), fill=TERRA, anchor="lm"); y += 40
    for s in T['card_sum']:
        d.text((ix, y), s, font=font(27, latin), fill=(60, 54, 46), anchor="lm"); y += 42
    y += 16
    d.text((ix, y), T['lbl_dec'], font=font(22, latin), fill=TERRA, anchor="lm"); y += 40
    for s in T['dec']:
        check(d, ix+2, y+2, GREEN, 9, 5)
        d.text((ix+40, y+2), s, font=font(27, latin), fill=(60, 54, 46), anchor="lm"); y += 42
    y += 16
    d.text((ix, y), T["lbl_act"], font=font(22, latin), fill=TERRA, anchor="lm"); y += 40
    for txt, owner in T['act']:
        d.rounded_rectangle([ix, y-14, ix+28, y+14], radius=8, outline=(120, 112, 100), width=3)
        d.text((ix+44, y+2), txt, font=font(27, latin), fill=(60, 54, 46), anchor="lm")
        tw = d.textlength(txt, font=font(27, latin))
        ow = d.textlength(owner, font=font(22, latin))
        bx = min(int(ix + 44 + tw + 28), x0 + w - pad - ow - 26)
        d.rounded_rectangle([bx, y-18, bx+ow+26, y+18], radius=18, fill=TERRA_SOFT)
        d.text((bx+13, y+2), owner, font=font(22, latin), fill=TERRA, anchor="lm")
        y += 46
    ty = y0 + h - 40
    d.line([(ix, ty), (x0+w-pad, ty)], fill=(216, 210, 198), width=3)
    for frac, col in ((0.12, WAVE), (0.45, AMBER), (0.8, GREEN)):
        px = ix + int((x0+w-pad-ix) * frac)
        d.ellipse([px-7, ty-7, px+7, ty+7], fill=col)

def timeline_card(canvas, x0, y0, w, h, T):
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=24, fill=CARD_BG, outline=(226, 221, 210), width=2)
    latin = T.get('latin', False)
    d.text((x0+34, y0+52), T['tl_title'], font=font(32, latin), fill=(40, 36, 30), anchor="lm")
    for i, (ts, who, txt, col) in enumerate(T['tl_rows']):
        yy = y0 + 130 + i * 108
        d.rounded_rectangle([x0+30, yy-20, x0+128, yy+20], radius=12, fill=(232, 226, 214))
        d.text((x0+79, yy+1), ts, font=font(24, True), fill=(90, 82, 70), anchor="mm")
        d.ellipse([x0+152, yy-8, x0+168, yy+8], fill=col)
        d.text((x0+186, yy), who, font=font(27, latin), fill=(40, 36, 30), anchor="lm")
        d.text((x0+186, yy+40), txt, font=font(23, latin), fill=(110, 100, 88), anchor="lm")

def privacy_card(canvas, x0, y0, w, h, T):
    """1.2 原版:Mac 图形 + 断云 + 手绘对勾承诺"""
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=24, fill=CARD_BG, outline=(226, 221, 210), width=2)
    latin = T.get('latin', False)
    cx = x0 + w // 2
    # Mac 图形
    d.rounded_rectangle([cx-150, y0+70, cx+150, y0+250], radius=14, fill=(52, 46, 40), outline=(30, 26, 22), width=3)
    d.rounded_rectangle([cx-132, y0+88, cx+132, y0+232], radius=8, fill=(28, 32, 44))
    # 屏内声波
    wx = cx - 108
    import random
    rnd = random.Random(11)
    while wx < cx + 96:
        bh = rnd.randint(12, 100)
        d.rounded_rectangle([wx, y0+160-bh//2, wx+6, y0+160+bh//2], radius=3, fill=WAVE)
        wx += 17
    d.rounded_rectangle([cx-190, y0+250, cx+190, y0+278], radius=10, fill=(40, 35, 30))
    # 断网标记:云端+斜杠
    cy = y0 + 380
    d.ellipse([cx+120, cy-60, cx+220, cy+40], fill=(228, 222, 212), outline=(180, 172, 158), width=3)
    d.ellipse([cx+150, cy-90, cx+230, cy-10], fill=(228, 222, 212), outline=(180, 172, 158), width=3)
    d.line([(cx+70, cy+50), (cx+260, cy-110)], fill=TERRA, width=14)
    for i, row in enumerate(T['pv_rows']):
        txt = row[0] if isinstance(row, tuple) else row
        yy = y0 + 470 + i * 62
        d.ellipse([x0+40, yy-16, x0+72, yy+16], fill=(226, 238, 228))
        check(d, x0+49, yy+1, GREEN, 6, 4)
        d.text((x0+94, yy+1), txt, font=font(30, latin), fill=(60, 54, 46), anchor="lm")

def export_card(canvas, x0, y0, w, h, T):
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=24, fill=CARD_BG, outline=(226, 221, 210), width=2)
    latin = T.get('latin', False)
    for i, (ext, col) in enumerate(T['ex_rows']):
        yy = y0 + 110 + i * 150
        d.rounded_rectangle([x0+40, yy-44, x0+190, yy+44], radius=18, fill=(30, 36, 48))
        d.text((x0+115, yy+2), ext, font=font(38, True), fill=col, anchor="mm")
        d.text((x0+230, yy-24), T['ex_names'][i][0], font=font(30, latin), fill=(60, 54, 46), anchor="lm")
        d.text((x0+230, yy+20), T['ex_names'][i][1], font=font(23, latin), fill=(130, 120, 106), anchor="lm")

# ---- 1.3 新卡:模型库卡(Whisper 模型管理)----
def models_card(canvas, x0, y0, w, h, T):
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=24, fill=CARD_BG, outline=(226, 221, 210), width=2)
    latin = T.get('latin', False)
    d.text((x0+34, y0+52), T['md_title'], font=font(32, latin), fill=(40, 36, 30), anchor="lm")
    for i, (name, size, col, downloaded, active) in enumerate(T['md_rows']):
        yy = y0 + 130 + i * 108
        d.rounded_rectangle([x0+30, yy-34, x0+w-30, yy+62], radius=16,
                            fill=(240, 236, 226) if active else CARD_BG,
                            outline=AMBER if active else (226, 221, 210), width=3 if active else 2)
        d.ellipse([x0+58, yy-12, x0+82, yy+12], fill=col)
        d.text((x0+104, yy-10), name, font=font(30, True), fill=(40, 36, 30), anchor="lm")
        d.text((x0+104, yy+28), size, font=font(22, latin), fill=(130, 120, 106), anchor="lm")
        if active:
            bw_ = d.textlength(T['md_active'], font=font(22, latin))
            bx = x0 + w - 64 - bw_
            d.rounded_rectangle([bx, yy-16, bx+bw_+28, yy+16], radius=18, fill=AMBER_BG)
            d.text((bx+14, yy+1), T['md_active'], font=font(22, latin), fill=TERRA, anchor="lm")
        else:
            bw_ = d.textlength(T['md_get'], font=font(22, latin))
            bx = x0 + w - 64 - bw_
            d.rounded_rectangle([bx, yy-16, bx+bw_+28, yy+16], radius=18, outline=(150, 142, 128), width=2)
            d.text((bx+14, yy+1), T['md_get'], font=font(22, latin), fill=(110, 100, 88), anchor="lm")

# ---- 1.3 新卡:统计卡(会议统计)----
def stats_card(canvas, x0, y0, w, h, T):
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=24, fill=CARD_BG, outline=(226, 221, 210), width=2)
    latin = T.get('latin', False)
    d.text((x0+34, y0+52), T['st_title'], font=font(32, latin), fill=(40, 36, 30), anchor="lm")
    # 2×2 大数字网格
    for i, (num, unit, col) in enumerate(T['st_cells']):
        gx = x0 + 34 + (i % 2) * (w // 2 - 20)
        gy = y0 + 120 + (i // 2) * 200
        d.rounded_rectangle([gx, gy, gx + w//2 - 54, gy + 176], radius=18, fill=(240, 236, 226))
        d.text((gx + 30, gy + 74), num, font=font(64, True), fill=col, anchor="lm")
        d.text((gx + 30, gy + 138), unit, font=font(24, latin), fill=(110, 100, 88), anchor="lm")
    # 底部迷你条形图:近 7 天会议数
    import random
    rnd = random.Random(23)
    bx0, by0 = x0 + 34, y0 + h - 90
    d.text((bx0, by0 - 44), T['st_foot'], font=font(22, latin), fill=(130, 120, 106), anchor="lm")
    for i in range(7):
        bh_ = rnd.randint(18, 62)
        d.rounded_rectangle([bx0 + i*100, by0 - bh_, bx0 + i*100 + 62, by0], radius=8,
                            fill=WAVE if i == 5 else (216, 210, 198))

# ---- 文案 ----
SHOTS = {
 'en': [
  dict(fid="01-library", head="Every meeting, written up.", sub="Summary · Decisions · Action items", cap="Library — everything searchable"),
  dict(fid="02-minutes", head="Notes, not transcripts.", sub="Decision and owner, at a glance", cap="Structured minutes, one per meeting"),
  dict(fid="03-timeline", head="Jump back to any moment.", sub="Timestamped key statements", cap="Tap a moment, hear the tape"),
  dict(fid="04-privacy", head="Your audio never leaves.", sub="100% on-device · offline OK", cap="No cloud. No upload. Ever."),
  dict(fid="05-chinese", head="Built for Chinese meetings.", sub="Mandarin + English mixed speech", cap="Local Whisper, tuned for 中文"),
  dict(fid="06-export", head="Own your notes.", sub="Markdown · TXT · SRT", cap="Exports to Notion / Obsidian"),
  dict(fid="07-models", head="Your model, your choice.", sub="Whisper models, one click away", cap="large-v3-turbo · medium · small"),
 ],
 'zh-Hans': [
  dict(fid="01-library", head="你只管开会，纪要它来写。", sub="摘要 · 决议 · 待办", cap="会议库 — 全部会议，全文可搜"),
  dict(fid="02-minutes", head="纪要，不是逐字稿。", sub="决议和负责人，一眼看清", cap="每场会，一张结构化纪要"),
  dict(fid="03-timeline", head="关键时刻，随时回放。", sub="带时间戳的关键发言", cap="点时间点，直达录音原文"),
  dict(fid="04-privacy", head="录音不出你的 Mac。", sub="100% 本地运行 · 断网可用", cap="零上传，音频不出设备"),
  dict(fid="05-chinese", head="为中文会议而生。", sub="普通话 + 中英混说深度优化", cap="本地 Whisper，中文优先"),
  dict(fid="06-export", head="纪要归你所有。", sub="Markdown · TXT · SRT", cap="一键导出 Notion / Obsidian"),
  dict(fid="07-models", head="模型随心换。", sub="Whisper 模型库，一键下载管理", cap="large-v3-turbo · medium · small"),
 ],
 'zh-Hant': [
  dict(fid="01-library", head="你只管開會，紀要它來寫。", sub="摘要 · 決議 · 待辦", cap="會議庫 — 全部會議，全文可搜"),
  dict(fid="02-minutes", head="紀要，不是逐字稿。", sub="決議和負責人，一眼看清", cap="每場會，一張結構化紀要"),
  dict(fid="03-timeline", head="關鍵時刻，隨時回放。", sub="帶時間戳的關鍵發言", cap="點時間點，直達錄音原文"),
  dict(fid="04-privacy", head="錄音不出你的 Mac。", sub="100% 本機運算 · 離線可用", cap="零上傳，音訊不出裝置"),
  dict(fid="05-chinese", head="為中文會議而生。", sub="普通話 + 中英混說深度優化", cap="本地 Whisper，中文優先"),
  dict(fid="06-export", head="紀要歸你所有。", sub="Markdown · TXT · SRT", cap="一鍵匯出 Notion / Obsidian"),
  dict(fid="07-models", head="模型隨心換。", sub="Whisper 模型庫，一鍵下載管理", cap="large-v3-turbo · medium · small"),
 ],
 'ja': [
  dict(fid="01-library", head="話しながら、議事録ができる。", sub="要約 · 決定事項 · アクション", cap="ライブラリ — 全記録を全文検索"),
  dict(fid="02-minutes", head="文字起こしではなく、議事録。", sub="決定事項と担当者をひと目で", cap="会議ごとに構造化メモ"),
  dict(fid="03-timeline", head="発言にすぐ戻れる。", sub="タイムスタンプ付きキー発言", cap="時刻をタップして録音へ"),
  dict(fid="04-privacy", head="録音は Mac の外に出ない。", sub="100% ローカル · オフライン可", cap="送信ゼロ、端末の外へ出ません"),
  dict(fid="05-chinese", head="中国語会議に強い。", sub="標準語 + 中英混在に最適化", cap="ローカル Whisper、中国語優先"),
  dict(fid="06-export", head="メモはあなたのもの。", sub="Markdown · TXT · SRT", cap="Notion / Obsidian へ書き出し"),
  dict(fid="07-models", head="モデルを自由に。", sub="Whisper モデル管理、ワンクリック", cap="large-v3-turbo · medium · small"),
 ],
}

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
    lbl_sum="SUMMARY", lbl_dec="DECISIONS", lbl_act="ACTION ITEMS",
    tl_title="Timeline — key moments",
    tl_rows=[("03:12", "Phinn", "Ship scope: cut onboarding step", WAVE),
             ("14:05", "Kai", "FTS5 bug — root-caused, fix Mon", AMBER),
             ("26:40", "Mia", "Pro pricing: one-time, confirmed", GREEN)],
    pv_rows=[("Audio stays on this Mac",), ("Works with Wi-Fi off",), ("Delete everything, anytime",)],
    cn_chips=["Mandarin + English mixed", "Local Whisper", "Auto punctuation & paragraphs"],
    ex_rows=[("MD", AMBER), ("TXT", WAVE), ("SRT", GREEN)],
    ex_names=[("Markdown export", "Notion · Obsidian ready"), ("Plain text", "Clean and universal"),
              ("Subtitle export", "Timestamped")],
    md_title="Whisper models", md_active="In use", md_get="Download",
    md_rows=[("large-v3-turbo", "1.6 GB · highest accuracy", AMBER, False, True),
             ("medium", "1.5 GB · balanced", WAVE, False, False),
             ("small", "466 MB · fast", GREEN, True, False)],
    st_title="Meeting insights", st_foot="This week",
    st_cells=[("12", "meetings this month", AMBER), ("4.6h", "recorded", WAVE),
              ("38k", "words transcribed", GREEN), ("9", "action items captured", TERRA)],
    ),
 'zh-Hans': dict(brand="KinetMinutes",
    sub="你只管开会，纪要它来写。",
    chips=["零上传，永不出设备", "完全离线可用", "自动检测会议"],
    shot_cap="会议库 — 每场会议全文可搜",
    card_title="Q4 规划会", card_dur="32 分钟",
    card_sum=("本周上线录音 v2；", "新用户引导缩到一步"),
    dec=["默认本地运行", "Pro 买断制，无订阅"],
    act=[("周五前发送评审材料", "小沈 · 周五"), ("修复 FTS5 搜索", "阿凯 · 周一")],
    foot="macOS 14+ · Apple Silicon · 免费开始",
    lbl_sum="摘要", lbl_dec="决议", lbl_act="待办",
    tl_title="时间线 — 关键发言",
    tl_rows=[("03:12", "小沈", "范围确定：引导缩到一步", WAVE),
             ("14:05", "阿凯", "FTS5 已定位根因，周一修", AMBER),
             ("26:40", "Mia", "Pro 定价：确定买断", GREEN)],
    pv_rows=[("音频只留在这台 Mac",), ("断网也能用",), ("随时一键全删",)],
    cn_chips=["中英混说优化", "本地 Whisper", "自动标点与分段"],
    ex_rows=[("MD", AMBER), ("TXT", WAVE), ("SRT", GREEN)],
    ex_names=[("导出 Markdown", "Notion · Obsidian 直接用"), ("纯文本", "干净通用"),
              ("导出字幕", "带时间戳")],
    md_title="Whisper 模型库", md_active="使用中", md_get="下载",
    md_rows=[("large-v3-turbo", "1.6 GB · 最高精度", AMBER, False, True),
             ("medium", "1.5 GB · 均衡之选", WAVE, False, False),
             ("small", "466 MB · 极速", GREEN, True, False)],
    st_title="会议统计", st_foot="本周",
    st_cells=[("12", "本月会议", AMBER), ("4.6h", "累计录音", WAVE),
              ("3.8万", "转写字数", GREEN), ("9", "捕获待办", TERRA)],
    ),
 'zh-Hant': dict(brand="KinetMinutes",
    sub="你只管開會，紀要它來寫。",
    chips=["零上傳，永不離開裝置", "完全離線可用", "自動偵測會議"],
    shot_cap="會議庫 — 每場會議全文可搜",
    card_title="Q4 規劃會", card_dur="32 分鐘",
    card_sum=("本週上線錄音 v2；", "新使用者引導縮到一步"),
    dec=["預設本機運算", "Pro 買斷制，無訂閱"],
    act=[("週五前寄出審查資料", "小沈 · 週五"), ("修復 FTS5 搜尋", "阿凱 · 週一")],
    foot="macOS 14+ · Apple Silicon · 免費開始",
    lbl_sum="摘要", lbl_dec="決議", lbl_act="待辦",
    tl_title="時間軸 — 關鍵發言",
    tl_rows=[("03:12", "小沈", "範圍確定：引導縮到一步", WAVE),
             ("14:05", "阿凱", "FTS5 已定位根因，週一修", AMBER),
             ("26:40", "Mia", "Pro 定價：確定買斷", GREEN)],
    pv_rows=[("音訊只留在這台 Mac",), ("離線也能用",), ("隨時一鍵全刪",)],
    cn_chips=["中英混說優化", "本地 Whisper", "自動標點與分段"],
    ex_rows=[("MD", AMBER), ("TXT", WAVE), ("SRT", GREEN)],
    ex_names=[("匯出 Markdown", "Notion · Obsidian 直接用"), ("純文字", "乾淨通用"),
              ("匯出字幕", "帶時間戳")],
    md_title="Whisper 模型庫", md_active="使用中", md_get="下載",
    md_rows=[("large-v3-turbo", "1.6 GB · 最高精度", AMBER, False, True),
             ("medium", "1.5 GB · 均衡之選", WAVE, False, False),
             ("small", "466 MB · 極速", GREEN, True, False)],
    st_title="會議統計", st_foot="本週",
    st_cells=[("12", "本月會議", AMBER), ("4.6h", "累計錄音", WAVE),
              ("3.8萬", "轉寫字數", GREEN), ("9", "擷取待辦", TERRA)],
    ),
 'ja': dict(brand="KinetMinutes",
    sub="話しながら、議事録ができる。",
    chips=["録音は Mac の外に出ない", "完全オフライン動作", "会議を自動検出して録音"],
    shot_cap="ライブラリ — 全記録を全文検索",
    card_title="Q4 企画会議", card_dur="32 分",
    card_sum=("レコーダー v2 を今週公開；", "オンボーディングを1ステップに"),
    dec=["完全ローカル動作", "Pro は買い切り、サブスク無し"],
    act=[("金曜までに審査資料を送る", "沈 · 金"), ("FTS5 検索を修正", "カイ · 月")],
    foot="macOS 14+ · Apple Silicon · 無料で開始",
    lbl_sum="要約", lbl_dec="決定事項", lbl_act="アクション",
    tl_title="タイムライン — キー発言",
    tl_rows=[("03:12", "シェン", "スコープ確定：導入を1工程に", WAVE),
             ("14:05", "カイ", "FTS5 の原因特定、月曜修正", AMBER),
             ("26:40", "ミア", "Pro 価格：買い切りで確定", GREEN)],
    pv_rows=[("音声はこの Mac だけに",), ("Wi-Fi オフでも動作",), ("いつでも一括削除",)],
    cn_chips=["標準語 + 中英混在", "ローカル Whisper", "句読点・段落を自動整形"],
    ex_rows=[("MD", AMBER), ("TXT", WAVE), ("SRT", GREEN)],
    ex_names=[("Markdown 書き出し", "Notion · Obsidian 対応"), ("プレーンテキスト", "清潔で万能"),
              ("字幕書き出し", "タイムスタンプ付き")],
    md_title="Whisper モデル", md_active="使用中", md_get="入手",
    md_rows=[("large-v3-turbo", "1.6 GB · 最高精度", AMBER, False, True),
             ("medium", "1.5 GB · バランス", WAVE, False, False),
             ("small", "466 MB · 高速", GREEN, True, False)],
    st_title="会議インサイト", st_foot="今週",
    st_cells=[("12", "今月の会議", AMBER), ("4.6h", "録音時間", WAVE),
              ("3.8万", "文字起こし字数", GREEN), ("9", "抽出アクション", TERRA)],
    ),
}

def brand_head(d, T, latin):
    d.text((120, 120), T['brand'], font=font(44, True), fill=PAPER, anchor="lm")
    wave_badge(d, W - 420, 170, 300, 84)

def gen(loc, spec=None):
    T = TEXTS[loc]
    latin = T.get('latin', False)
    specs = SHOTS[loc]
    s = spec or specs[0]

    im = ink_bg(W, H)
    d = ImageDraw.Draw(im)
    brand_head(d, T, latin)

    shot = trim_shot(Image.open(os.path.join(OUT, loc, "raw-library.png")))

    if s['fid'] == "01-library":
        d.text((120, 210), T['sub'], font=font(64, latin), fill=AMBER, anchor="lm")
        # 主截图 + 纪要卡 + chips(1.2 原版式)
        box = (120, 300, 1620, 1150)
        shot_capture(im, shot, box)
        x, w = 1760, 680
        for i, c in enumerate(T['chips']):
            chip(d, x, 360 + i*110, w, c, latin, dot=[WAVE, AMBER, GREEN][i])
        minutes_card(im, x, 760, w, 700, T)
        d = ImageDraw.Draw(im)
        d.text((W - 120, 1490), T['foot'] + "   ·   " + T['shot_cap'],
               font=font(28, latin), fill=(196, 206, 228), anchor="rm",
               stroke_width=4, stroke_fill=INK)
    elif s['fid'] == "05-chinese":
        d.text((120, 120), T['brand'], font=font(44, True), fill=PAPER, anchor="lm")
        head_block(d, 250, s['head'], s['sub'], latin)
        box2 = (140, 520, 2420, 1500)
        shot_capture(im, shot, box2)
        chip_row(d, 140, 415, T['cn_chips'], latin)
        d.text((W - 120, 1560), T['foot'] + "   ·   " + s['cap'],
               font=font(28, latin), fill=(196, 206, 228), anchor="rm",
               stroke_width=4, stroke_fill=INK)
    else:
        # 02/03/04/06/07 大标题版式
        head_block(d, 250, s['head'], s['sub'], latin)
        if s['fid'] == "02-minutes":
            shot_capture(im, shot, (120, 430, 1560, 1470))
            minutes_card(im, 1680, 500, 760, 900, T)
            chip_row(d, 1680, 300, T['chips'][:2], latin)
        elif s['fid'] == "03-timeline":
            shot_capture(im, shot, (120, 430, 1560, 1470))
            timeline_card(im, 1680, 500, 760, 860, T)
            d.text((1680, 1440), s['cap'], font=font(32, latin), fill=(150, 196, 226), anchor="lm")
        elif s['fid'] == "04-privacy":
            shot_capture(im, shot, (120, 430, 1560, 1470))
            privacy_card(im, 1680, 430, 760, 1050, T)
        elif s['fid'] == "06-export":
            shot_capture(im, shot, (120, 430, 1560, 1470))
            export_card(im, 1680, 500, 760, 880, T)
            chip_row(d, 1680, 320, T['chips'][:2], latin)
        elif s['fid'] == "07-models":
            shot_capture(im, shot, (120, 430, 1560, 1470))
            models_card(im, 1680, 500, 760, 830, T)
            # 底部一句话说明
            d.text((1680, 1400), s['cap'], font=font(30, latin), fill=(150, 196, 226), anchor="lm")
        d.text((W - 120, 1560), T['foot'] + "   ·   " + s['cap'],
               font=font(28, latin), fill=(196, 206, 228), anchor="rm",
               stroke_width=4, stroke_fill=INK)

    out = os.path.join(OUT, loc, s['fid'] + ".png")
    im.save(out)
    print("saved", out)

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    locs = {'all': ['en', 'zh-Hans', 'zh-Hant', 'ja']}.get(which, [which])
    for loc in locs:
        for spec in SHOTS[loc]:
            gen(loc, spec)
    print("done")
