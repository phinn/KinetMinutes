#!/usr/bin/env python3
"""KinetMinutes ASC 商店截图 2560×1600 — 亮色暖纸白 v2
铁律:亮色(暖纸白)、设计过非裸截图、卖点亮、首图有焦点
版式(01 首图):暖纸底 → 左侧大标题+三卖点chips → 右侧真窗口截图(琥珀环,裁掉空白下半)
             → 截图旁叠一张「纪要卡」mock 补足信息密度
02-06:大标题版式(左 55% 截图 + 右侧功能卡)
输出 release/screenshots/{en,zh-Hans,zh-Hant,ja}/0N-*.png(2560×1600 sRGB)
前置:每个 locale 目录需有 raw-library.png(由 /tmp/km_shoot.py 生成)
用法: python3 tools/gen_asc_screenshots.py [en|zh-Hans|zh-Hant|ja|all]
"""
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(BASE, "release", "screenshots")

# ---- 亮色调色板(铁律:暖纸白,不暗底) ----
PAPER   = (247, 245, 240)   # 暖纸白主底
PAPER_2 = (255, 255, 255)   # 卡白
INK     = (32, 38, 48)      # 主文字(深墨蓝黑)
INK_SOFT= (108, 116, 130)   # 次文字
AMBER   = (214, 148, 58)    # 品牌琥珀(描边/强调)
AMBER_BG= (250, 239, 222)   # 琥珀浅底
WAVE    = (74, 138, 186)    # 蓝(音频/时间线)
WAVE_BG = (228, 239, 248)
GREEN   = (74, 130, 94)     # 绿(隐私/完成)
GREEN_BG= (227, 240, 231)
CARD_BG = (252, 251, 248)   # 卡底
LINE    = (226, 222, 214)   # 分隔线

F_CN = "/System/Library/Fonts/Hiragino Sans GB.ttc"
F_JP = "/System/Library/Fonts/Hiragino Sans GB.ttc"
F_LAT = "/System/Library/Fonts/Helvetica.ttc"

def font(size, latin=False):
    paths = [F_LAT] if latin else [F_CN, F_JP, F_LAT]
    for p in paths:
        try: return ImageFont.truetype(p, size)
        except Exception: continue
    return ImageFont.load_default()

def paper_bg(w, h):
    """暖纸白 + 极淡径向光晕(右上琥珀、左下蓝,各 5% 强度,防死白)"""
    im = Image.new("RGB", (w, h), PAPER)
    glow = Image.new("RGB", (w, h), PAPER)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([int(w*0.55), -int(h*0.4), int(w*1.3), int(h*0.35)], fill=AMBER_BG)
    gd.ellipse([-int(w*0.3), int(h*0.6), int(w*0.4), int(h*1.4)], fill=WAVE_BG)
    glow = glow.filter(ImageFilter.GaussianBlur(260))
    return Image.blend(im, glow, 0.55)

def trim_shot(shot):
    """裁掉截图四周桌面背景(以角落像素为基准色找 bbox)"""
    import PIL.ImageChops as IC
    rgb = shot.convert("RGB")
    bg = Image.new("RGB", rgb.size, rgb.getpixel((2, 2)))
    diff = IC.difference(rgb, bg).convert("L")
    bbox = diff.point(lambda p: 255 if p > 12 else 0).getbbox()
    if bbox:
        x0, y0, x1, y1 = bbox
        return rgb.crop((x0+4, y0+4, x1-4, y1-4))
    return rgb

def shot_in_card(canvas, shot, box, radius=28, ring_w=5):
    """截图贴进白卡:白卡(圆角+浅描边+投影)内等比缩放截图,顶部留 0(截图自带标题栏)"""
    x0, y0, bw, bh = box
    d = ImageDraw.Draw(canvas)
    # 投影
    sh = Image.new("RGBA", canvas.size, (0,0,0,0))
    ImageDraw.Draw(sh).rounded_rectangle([x0+8, y0+14, x0+bw+8, y0+bh+14], radius=radius, fill=(30,36,48,60))
    sh = sh.filter(ImageFilter.GaussianBlur(18))
    canvas.paste(Image.composite(sh.convert("RGB"), canvas, sh.split()[3]), (0,0))
    # 白卡
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+bw, y0+bh], radius=radius, fill=PAPER_2, outline=LINE, width=2)
    d.rounded_rectangle([x0, y0, x0+bw, y0+bh], radius=radius, outline=AMBER, width=ring_w)
    # 截图等比 fit(留 pad)
    pad = 4
    fw, fh = bw-2*pad, bh-2*pad
    ratio = min(fw/shot.width, fh/shot.height)
    im = shot.resize((int(shot.width*ratio), int(shot.height*ratio)), Image.LANCZOS)
    ix = x0+pad+(fw-im.width)//2
    iy = y0+pad+(fh-im.height)//2
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width-1, im.height-1], radius=radius-8, fill=255)
    canvas.paste(im, (ix, iy), mask)
    return canvas

def chip_row(d, x, y, texts, latin=True, dot_colors=None, size=36, gap=24):
    cx = x
    for i, t in enumerate(texts):
        f = font(size, latin)
        tw = int(d.textlength(t, font=f))
        col = (dot_colors or [WAVE, AMBER, GREEN])[i % 3]
        d.rounded_rectangle([cx, y, cx+tw+88, y+76], radius=38, fill=PAPER_2, outline=LINE, width=2)
        d.ellipse([cx+30, y+26, cx+58, y+54], fill=col)
        d.text((cx+78, y+38), t, font=f, fill=INK, anchor="lm")
        cx += tw + 88 + gap
    return cx

def steps(d, x, y, items, latin=False):
    """三步流程条: ① 录音 → ② 自动出纪要 → ③ 导出/回放"""
    cols = [AMBER, WAVE, GREEN]
    cur = x
    for i, (t, c) in enumerate(zip(items, cols)):
        tw = d.textlength(t, font=font(40)) + 150
        d.rounded_rectangle([cur, y, cur + tw, y + 88], radius=44, fill=(255, 255, 255), outline=(222, 218, 208), width=2)
        d.ellipse([cur + 22, y + 24, cur + 66, y + 68], fill=c)
        d.text((cur + 52, y + 22), str(i + 1), font=font(30, True), fill=(255, 255, 255))
        d.text((cur + 88, y + 22), t, font=font(40), fill=INK)
        cur += tw + 40


def minutes_card(canvas, x0, y0, w, h, T):
    """结构化纪要卡 mock:SUMMARY/DECISIONS/ACTION ITEMS 三段(亮色)"""
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=26, fill=CARD_BG, outline=LINE, width=2)
    y = y0 + 44
    d.text((x0+40, y), T['card_title'], font=font(44, T.get('latin', False)), fill=INK, anchor="lm")
    d.text((x0+w-40, y), T['card_dur'], font=font(32, T.get('latin', False)), fill=INK_SOFT, anchor="rm")
    y += 64
    d.line([(x0+40, y), (x0+w-40, y)], fill=LINE, width=2)
    y += 40
    for lbl, rows, col, bg in (
        (T['lbl_sum'], T['card_sum'], WAVE, WAVE_BG),
        (T['lbl_dec'], T['dec'], GREEN, GREEN_BG),
        (T['lbl_act'], [a[0] for a in T['act']], AMBER, AMBER_BG)):
        d.rounded_rectangle([x0+40, y-24, x0+40+len(lbl)*26+36, y+24], radius=18, fill=bg)
        d.text((x0+58, y), lbl, font=font(28, T.get('latin', False)), fill=col, anchor="lm")
        y += 56
        for r in rows:
            d.text((x0+56, y), "· " + r, font=font(34, T.get('latin', False)), fill=INK, anchor="lm")
            y += 52
        if isinstance(rows, list) and rows and isinstance(T['act'][0], tuple) and rows is [a[0] for a in T['act']][0:0]: pass
        y += 18
    # owner 行(仅 action)
    return canvas

def minutes_card2(canvas, x0, y0, w, h, T):
    """纪要卡 v2:带 owner/pill 的 action 区"""
    minutes_card(canvas, x0, y0, h=h, w=w, T=T)
    return canvas

def timeline_card(canvas, x0, y0, w, h, T):
    """带时间戳的关键发言卡"""
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=26, fill=CARD_BG, outline=LINE, width=2)
    d.text((x0+40, y0+52), T['tl_title'], font=font(40, T.get('latin', False)), fill=INK, anchor="lm")
    y = y0 + 120
    for t, who, what, col in T['tl_rows']:
        d.rounded_rectangle([x0+40, y-26, x0+40+150, y+26], radius=16, fill=WAVE_BG)
        d.text((x0+115, y), t, font=font(30, True), fill=WAVE, anchor="mm")
        d.text((x0+220, y), who + " — " + what, font=font(32, T.get('latin', False)), fill=INK, anchor="lm")
        y += 96
    d.text((x0+40, y0+h-48), T['tl_hint'], font=font(30, T.get('latin', False)), fill=INK_SOFT, anchor="lm")

def privacy_card(canvas, x0, y0, w, h, T):
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=26, fill=GREEN_BG, outline=GREEN, width=3)
    y = y0 + 64
    d.text((x0+w//2, y), "🔒", font=font(72), fill=GREEN, anchor="mm")
    y += 90
    for (row,) in T['pv_rows']:
        d.text((x0+w//2, y), "✓  " + row, font=font(36, T.get('latin', False)), fill=INK, anchor="mm")
        y += 84
    d.text((x0+w//2, y0+h-56), T['chips'][0], font=font(30, T.get('latin', False)), fill=GREEN, anchor="mm")

def export_card(canvas, x0, y0, w, h, T):
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([x0, y0, x0+w, y0+h], radius=26, fill=CARD_BG, outline=LINE, width=2)
    y = y0 + 56
    for (tag, col), (name, sub) in zip(T['ex_rows'], T['ex_names']):
        d.rounded_rectangle([x0+40, y-34, x0+40+96, y+34], radius=18, fill=PAPER_2, outline=col, width=3)
        d.text((x0+88, y), tag, font=font(30, True), fill=col, anchor="mm")
        d.text((x0+168, y-14), name, font=font(36, T.get('latin', False)), fill=INK, anchor="lm")
        d.text((x0+168, y+30), sub, font=font(28, T.get('latin', False)), fill=INK_SOFT, anchor="lm")
        y += 128
    y += 20
    chip_row(d, x0+40, y, T['ex_chips'], T.get('latin', False), [AMBER, GREEN], size=30)

def head_block(d, y, head, sub, latin):
    d.text((120, y), head, font=font(96, latin), fill=INK, anchor="lm")
    d.text((120, y+104), sub, font=font(48, latin), fill=AMBER, anchor="lm")

# ---- 文案(四语,沿用 v1 卖点) ----
TEXTS = {
 'en': dict(latin=True, brand="KinetMinutes",
    sub="Meeting notes, written while you talk.",
    chips=["Zero upload, ever", "Works fully offline", "Auto-detects meetings"],
    steps=["Record", "Auto minutes", "Export & replay"],
    feat_line="Works offline · Zero upload · Pro is one-time purchase",
    card_title="Q4 Planning", card_dur="32 min",
    card_sum=("Ship recorder v2 this week;", "onboarding cut to one step"),
    dec=["Local-only by default", "Pro is one-time, no sub"],
    act=[("Send review notes", "Phinn · Fri"), ("Fix FTS5 search bug", "Kai · Mon")],
    foot="macOS 14+ · Apple Silicon · Free to start",
    lbl_sum="SUMMARY", lbl_dec="DECISIONS", lbl_act="ACTION ITEMS",
    tl_title="Timeline — key moments", tl_hint="Click a timestamp to jump to the recording",
    tl_rows=[("03:12", "Phinn", "Ship scope: cut onboarding step", WAVE),
             ("14:05", "Kai", "FTS5 bug — root-caused, fix Mon", AMBER),
             ("26:40", "Mia", "Pro pricing: one-time, confirmed", GREEN)],
    pv_rows=[("Audio stays on this Mac",), ("Works with Wi-Fi off",), ("Delete everything, anytime",)],
    cn_chips=["Mandarin + English mixed", "Local Whisper", "Auto punctuation & paragraphs"],
    ex_rows=[("MD", AMBER), ("TXT", WAVE), ("SRT", GREEN)],
    ex_names=[("Markdown export", "Notion · Obsidian ready"), ("Plain text", "universal, clean"),
              ("Subtitles", "timestamped transcript")],
    ex_chips=["Pro · one-time", "No subscription"]),
 'zh-Hans': dict(latin=False, brand="KinetMinutes",
    sub="你只管开会，纪要它来写。",
    chips=["录音不出你的 Mac", "全程离线可用", "自动侦测会议开录"],
    steps=["录音", "自动出纪要", "导出/回放"],
    feat_line="全程离线 · 数据不出 Mac · Pro 一次性买断",
    card_title="Q4 规划会", card_dur="32 分钟",
    card_sum=("录制器 v2 本周上线；", "引导页砍到一步"),
    dec=["默认纯本地运行", "Pro 买断制，无订阅"],
    act=[("周五前发审核材料", "沈 · 周五"), ("修复 FTS5 搜索", "凯 · 周一")],
    foot="macOS 14+ · Apple Silicon · 免费开始",
    lbl_sum="摘要", lbl_dec="决议", lbl_act="待办",
    tl_title="时间线 — 关键发言", tl_hint="点时间戳，直接跳到录音原文",
    tl_rows=[("03:12", "沈", "上线范围：砍掉引导步骤", WAVE),
             ("14:05", "凯", "FTS5 搜索已定位，周一修", AMBER),
             ("26:40", "缪", "Pro 定价：买断制，定了", GREEN)],
    pv_rows=[("音频只存在这台 Mac",), ("断网照样完整使用",), ("随时一键全部删除",)],
    cn_chips=["普通话 + 中英混说", "本地 Whisper", "标点/分段自动整理"],
    ex_rows=[("MD", AMBER), ("TXT", WAVE), ("SRT", GREEN)],
    ex_names=[("Markdown 导出", "适配 Notion · Obsidian"), ("纯文本", "干净、通用"),
              ("字幕导出", "带时间戳的逐字稿")],
    ex_chips=["Pro · 一次性买断", "无订阅"]),
 'zh-Hant': dict(latin=False, brand="KinetMinutes",
    sub="你只管開會，紀要它來寫。",
    chips=["錄音不出你的 Mac", "全程離線可用", "自動偵測會議開錄"],
    steps=["錄音", "自動出紀要", "匯出/回放"],
    feat_line="全程離線 · 資料不出 Mac · Pro 一次性買斷",
    card_title="Q4 規劃會", card_dur="32 分鐘",
    card_sum=("錄製器 v2 本週上線；", "引導頁砍到一步"),
    dec=["預設純本機執行", "Pro 買斷制，無訂閱"],
    act=[("週五前寄審核材料", "沈 · 週五"), ("修復 FTS5 搜尋", "凱 · 週一")],
    foot="macOS 14+ · Apple Silicon · 免費開始",
    lbl_sum="摘要", lbl_dec="決議", lbl_act="待辦",
    tl_title="時間軸 — 關鍵發言", tl_hint="點時間戳，直接跳到錄音原文",
    tl_rows=[("03:12", "沈", "上線範圍：砍掉引導步驟", WAVE),
             ("14:05", "凱", "FTS5 搜尋已定位，週一修", AMBER),
             ("26:40", "繆", "Pro 定價：買斷制，定了", GREEN)],
    pv_rows=[("音訊只存在這台 Mac",), ("斷網照樣完整使用",), ("隨時一鍵全部刪除",)],
    cn_chips=["普通話 + 中英混說", "本地 Whisper", "標點/分段自動整理"],
    ex_rows=[("MD", AMBER), ("TXT", WAVE), ("SRT", GREEN)],
    ex_names=[("Markdown 匯出", "適配 Notion · Obsidian"), ("純文字", "乾淨、通用"),
              ("字幕匯出", "帶時間戳的逐字稿")],
    ex_chips=["Pro · 一次性買斷", "無訂閱"]),
 'ja': dict(latin=False, brand="KinetMinutes",
    sub="話しながら、議事録ができる。",
    chips=["録音は Mac の外に出ない", "完全オフライン動作", "会議を自動検出して録音"],
    steps=["録音", "自動で議事録", "書き出し/再生"],
    feat_line="完全オフライン · データは Mac の外に出ない · Pro は買い切り",
    card_title="Q4 企画会議", card_dur="32 分",
    card_sum=("レコーダー v2 を今週公開；", "オンボーディングを1ステップに"),
    dec=["完全ローカル動作", "Pro は買い切り、サブスク無し"],
    act=[("金曜までに審査資料を送る", "沈 · 金"), ("FTS5 検索を修正", "カイ · 月")],
    foot="macOS 14+ · Apple Silicon · 無料で開始",
    lbl_sum="要約", lbl_dec="決定事項", lbl_act="アクション",
    tl_title="タイムライン — キー発言", tl_hint="時刻をクリックして録音の該当箇所へ",
    tl_rows=[("03:12", "シェン", "スコープ確定：導入を1工程に", WAVE),
             ("14:05", "カイ", "FTS5 の原因特定、月曜修正", AMBER),
             ("26:40", "ミア", "Pro 価格：買い切りで確定", GREEN)],
    pv_rows=[("音声はこの Mac だけに",), ("Wi-Fi オフでも動作",), ("いつでも一括削除",)],
    cn_chips=["標準語 + 中英混在", "ローカル Whisper", "句読点・段落を自動整形"],
    ex_rows=[("MD", AMBER), ("TXT", WAVE), ("SRT", GREEN)],
    ex_names=[("Markdown 書き出し", "Notion · Obsidian 対応"), ("プレーンテキスト", "清潔で万能"),
              ("字幕書き出し", "タイムスタンプ付き")],
    ex_chips=["Pro · 買い切り", "サブスク無し"]),
}

SHOTS = {
 'en': [
  dict(fid="01-library", head="Every meeting, written up.", sub="Summary · Decisions · Action items", cap="Library — everything searchable"),
  dict(fid="02-minutes", head="Notes, not transcripts.", sub="Decision and owner, at a glance", cap="Structured minutes, one per meeting"),
  dict(fid="03-timeline", head="Jump back to any moment.", sub="Timestamped key statements", cap="Tap a moment, hear the tape"),
  dict(fid="04-privacy", head="Your audio never leaves.", sub="100% on-device · offline OK", cap="No cloud. No upload. Ever."),
  dict(fid="05-chinese", head="Built for Chinese meetings.", sub="Mandarin + English mixed speech", cap="Local Whisper, tuned for 中文"),
  dict(fid="06-export", head="Own your notes.", sub="Markdown · TXT · SRT", cap="Exports to Notion / Obsidian"),
 ],
 'zh-Hans': [
  dict(fid="01-library", head="你只管开会，纪要它来写。", sub="摘要 · 决议 · 待办", cap="会议库 — 全部会议，全文可搜"),
  dict(fid="02-minutes", head="纪要，不是逐字稿。", sub="决议和负责人，一眼看清", cap="每场会，一张结构化纪要"),
  dict(fid="03-timeline", head="关键时刻，随时回放。", sub="带时间戳的关键发言", cap="点时间点，直达录音原文"),
  dict(fid="04-privacy", head="录音不出你的 Mac。", sub="100% 本地运行 · 断网可用", cap="零上传，音频不出设备"),
  dict(fid="05-chinese", head="为中文会议而生。", sub="普通话 + 中英混说深度优化", cap="本地 Whisper，中文优先"),
  dict(fid="06-export", head="纪要归你所有。", sub="Markdown · TXT · SRT", cap="一键导出 Notion / Obsidian"),
 ],
 'zh-Hant': [
  dict(fid="01-library", head="你只管開會，紀要它來寫。", sub="摘要 · 決議 · 待辦", cap="會議庫 — 全部會議，全文可搜"),
  dict(fid="02-minutes", head="紀要，不是逐字稿。", sub="決議和負責人，一眼看清", cap="每場會，一張結構化紀要"),
  dict(fid="03-timeline", head="關鍵時刻，隨時回放。", sub="帶時間戳的關鍵發言", cap="點時間點，直達錄音原文"),
  dict(fid="04-privacy", head="錄音不出你的 Mac。", sub="100% 本機運行 · 離線可用", cap="零上傳，音訊不出裝置"),
  dict(fid="05-chinese", head="為中文會議而生。", sub="普通話 + 中英混說深度優化", cap="本地 Whisper，中文優先"),
  dict(fid="06-export", head="紀要歸你所有。", sub="Markdown · TXT · SRT", cap="一鍵匯出 Notion / Obsidian"),
 ],
 'ja': [
  dict(fid="01-library", head="話しながら、議事録ができる。", sub="要約 · 決定事項 · アクション", cap="ライブラリ — 全記録を全文検索"),
  dict(fid="02-minutes", head="文字起こしではなく、議事録。", sub="決定事項と担当者をひと目で", cap="会議ごとに構造化メモ"),
  dict(fid="03-timeline", head="発言にすぐ戻れる。", sub="タイムスタンプ付きキー発言", cap="時刻をタップして録音へ"),
  dict(fid="04-privacy", head="録音は Mac の外に出ない。", sub="100% ローカル · オフライン可", cap="送信ゼロ、端末の外へ出ません"),
  dict(fid="05-chinese", head="中国語会議に強い。", sub="標準語 + 中英混在に最適化", cap="ローカル Whisper、中国語優先"),
  dict(fid="06-export", head="メモはあなたのもの。", sub="Markdown · TXT · SRT", cap="Notion / Obsidian へ書き出し"),
 ],
}

W, H = 2560, 1600

def crop_lower_blank(shot):
    """裁掉窗口下半的大片空白:从底部向上找首个非纯白行,再留 60px 呼吸"""
    rgb = shot.convert("RGB")
    px = rgb.load()
    y1 = rgb.height - 1
    def row_is_blank(y):
        # 行内采样 12 点,全接近纯白视为空白
        for xi in range(16, rgb.width-16, max(8, (rgb.width-32)//12)):
            r, g, b = px[xi, y][:3]
            if r < 248 or g < 248 or b < 248:
                return False
        return True
    while y1 > rgb.height//2 and row_is_blank(y1):
        y1 -= 1
    return rgb.crop((0, 0, rgb.width, min(rgb.height, y1+70)))

def gen(loc, spec=None):
    T = TEXTS[loc]
    latin = T.get('latin', False)
    shot_raw = Image.open(os.path.join(OUT, loc, "raw-library.png"))
    shot = crop_lower_blank(trim_shot(shot_raw))

    if spec is None or spec['fid'] == "01-library":
        # ---------- 01 首图:左文案右截图,纪要卡叠压截图右下 ----------
        im = paper_bg(W, H)
        d = ImageDraw.Draw(im)
        # 品牌
        d.rounded_rectangle([120, 96, 120+56, 96+56], radius=14, fill=AMBER)
        d.text((120+28, 96+28), "K", font=font(34, True), fill=PAPER_2, anchor="mm")
        d.text((200, 124), T['brand'] if not latin else "KinetMinutes", font=font(40, True), fill=INK, anchor="lm")
        # 大标题+副标题(左上)
        head_block(d, 420, SHOTS[loc][0]['head'], SHOTS[loc][0]['sub'], latin)
        # 三卖点 chips
        chip_row(d, 120, 730, T['chips'], latin)
        # 三步流程条
        steps(d, 120, 838, T['steps'], latin)
        # foot 提前画(截图卡与纪要卡都不越过它)
        d.text((120, H-64), T['foot'], font=font(30, latin), fill=INK_SOFT, anchor="lm")
        # 主视觉:窗口横贯底部(裁上半 61% = 标题栏+列表+纪要精华),铺满宽度
        sw, shh = shot.size
        crop_h = int(shh * 0.61)
        bar = shot.crop((0, 0, sw, crop_h)).convert("RGB")
        # 底部 16% 渐隐融入纸底(避免行中间硬切)
        fade = Image.new("L", bar.size, 0)
        fd = ImageDraw.Draw(fade)
        fh = int(bar.size[1] * 0.16)
        for i in range(fh):
            fd.line([(0, bar.size[1] - fh + i), (bar.size[0], bar.size[1] - fh + i)], fill=int(255 * i / fh))
        paper = Image.new("RGB", bar.size, PAPER)
        bar = Image.composite(paper, bar, fade)
        win_w, win_x, win_y = 2320, 120, 1000
        scale_h = int(win_w * crop_h / sw)
        shot_in_card(im, bar, (win_x, win_y, win_w, scale_h + 16))
        # Q4 纪要卡(右上,三段完整:摘要/决议/待办)
        mw, mh = 680, 650
        mcard = Image.new("RGB", (mw, mh), CARD_BG)
        minutes_card(mcard, 0, 0, mw, mh, T)
        mx, my = 1660, 150
        # 阴影 + 贴
        sh = Image.new("RGBA", im.size, (0,0,0,0))
        ImageDraw.Draw(sh).rounded_rectangle([mx+4, my+16, mx+mw+12, my+mh+24], radius=26, fill=(30,36,48,70))
        sh = sh.filter(ImageFilter.GaussianBlur(16))
        im.paste(Image.composite(sh.convert("RGB"), im, sh.split()[3]), (0,0))
        im.paste(mcard, (mx, my))
        ImageDraw.Draw(im).rounded_rectangle([mx, my, mx+mw, my+mh], radius=26, outline=AMBER, width=4)
        out = os.path.join(OUT, loc, "01-library.png")
        im.save(out)
        print("saved", out)
        if spec is None:
            return

    # ---------- 02-06:大标题版式(左 55% 截图 + 右功能卡) ----------
    s = spec
    im = paper_bg(W, H)
    d = ImageDraw.Draw(im)
    # 顶部品牌行
    d.rounded_rectangle([120, 80, 120+48, 80+48], radius=12, fill=AMBER)
    d.text((120+24, 80+24), "K", font=font(30, True), fill=PAPER_2, anchor="mm")
    d.text((190, 104), "KinetMinutes", font=font(36, True), fill=INK, anchor="lm")
    # 大标题
    d.text((120, 320), s['head'], font=font(92, latin), fill=INK, anchor="lm")
    d.text((120, 430), s['sub'], font=font(46, latin), fill=AMBER, anchor="lm")

    if s['fid'] == "05-chinese":
        # 全宽截图 + 上方 cn chips
        chip_row(d, 120, 560, T['cn_chips'], latin, [WAVE, AMBER, GREEN], size=34)
        shot_in_card(im, shot, (140, 690, 2280, 830))
    else:
        box2 = (120, 560, 1500, 950)
        shot_in_card(im, shot, box2)
        x = 1700
        if s['fid'] == "02-minutes":
            minutes_card(im, x, 600, 740, 900, T)
        elif s['fid'] == "03-timeline":
            timeline_card(im, x, 640, 740, 760, T)
        elif s['fid'] == "04-privacy":
            privacy_card(im, x, 600, 740, 900, T)
        elif s['fid'] == "06-export":
            export_card(im, x, 620, 740, 860, T)

    d.text((W-120, H-64), T['foot'], font=font(30, latin), fill=INK_SOFT, anchor="rm")
    out2 = os.path.join(OUT, loc, s['fid'] + ".png")
    im.save(out2)
    print("saved", out2)

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    locs = {'all': ['en', 'zh-Hans', 'zh-Hant', 'ja']}.get(which, [which])
    for loc in locs:
        gen(loc)  # 01
        for spec in SHOTS[loc][1:]:
            gen(loc, spec)  # 02-06
    print("done")
