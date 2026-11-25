#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""KinetMinutes 1.4 商店截图合成器（2560×1600）

素材是 /tmp/km_shots/<locale>/01..06.png —— 由 app 的 KM_SNAPSHOT 钩子直接
渲染 contentView（Retina 2x），因此没有旧版 raw 的「侧栏被裁、焦点环、
英文界面里出现中文日期」这些问题。这里只做编排：

  左栏：品牌 + 两行标题 + 一句副题（+ 首图三条卖点）
  右栏：整窗截图，圆角 + 琥珀描边 + 投影，不裁侧边栏

用法：/usr/bin/python3 tools/gen_store_shots.py [locale...]
输出：release/screenshots-1.4/<locale>/0X-<shot>.png
"""
import os, re, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = "/tmp/km_shots"
OUT = os.path.join(ROOT, "release", "screenshots-1.4")

W, H = 2560, 1600
INK = (13, 17, 28)
INK_2 = (24, 30, 44)
PAPER = (246, 244, 238)
AMBER = (232, 165, 74)
MUTED = (148, 154, 170)

WIN_W = 1700
WIN_H = int(round(1560 * WIN_W / 2560.0))     # 1097
WIN_X, WIN_Y = (W - WIN_W) // 2, 470
TEXT_MAX = 1740

F_LAT = "/System/Library/Fonts/Helvetica.ttc"
F_HEI_M = "/System/Library/Fonts/STHeiti Medium.ttc"
F_HEI_L = "/System/Library/Fonts/STHeiti Light.ttc"
F_HIRA_W6 = "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
F_HIRA_W3 = "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"
F_KO = "/System/Library/Fonts/AppleSDGothicNeo.ttc"

# 每张图的截图来源（/tmp/km_shots/<loc>/<file>.png）与文案 key
SHOTS = [
    ("hero", "01"),
    ("actions", "02"),
    ("timeline", "03"),
    ("privacy", "04"),
    ("stats", "05"),
    ("settings", "06"),
]

# 每张图的取景：crop 用原始 2560×1560 像素坐标，w 是画布上的目标宽度。
# 详情卡片是整页高的，Summary 页内容只到卡片六成，下半是纯白。裁掉这段
# 空白后窗口变成「宽而矮」的真实窗口比例观感（四角完整，不是被切一半），
# 同时整体放大 30%，缩略图里文字才读得出来。
SHOT_CFG = {
    "hero":     dict(crop=(0, 0, 2560, 1560), w=1750, gap=70, r=18),
    "actions":  dict(crop=(0, 0, 2560, 1560), w=1750, gap=70, r=18),
    "timeline": dict(crop=(0, 0, 2560, 1560), w=1750, gap=70, r=18),
    "privacy":  dict(crop=(0, 0, 2560, 1560), w=1750, gap=70, r=18),
    "stats":    dict(crop=(0, 0, 2560, 1560), w=1750, gap=70, r=18),
    "settings": dict(crop=(0, 0, 2560, 1560), w=1750, gap=70, r=18),
}

REC = {
    "en": "Recording", "zh-Hans": "录音中", "zh-Hant": "錄音中", "ja": "録音中",
    "ko": "녹음 중", "fr": "Enregistrement", "de": "Aufnahme", "es": "Grabando",
}

COPY = {
    "en": dict(
        lat=True,
        head=[
            ("The meeting ends.", "The notes are ready."),
            ("Tasks, straight", "out of the call."),
            ("Jump to the", "exact moment."),
            ("Zero upload.", "By design."),
            ("See where", "the hours go."),
            ("Your models,", "your rules."),
        ],
        sub=[
            "Summary, decisions and action items — written on your Mac, offline.",
            "Owners, due dates and next steps, extracted automatically.",
            "Timestamped key moments. Click one to replay that part of the call.",
            "Audio, transcripts and notes stay on this Mac. Fully offline.",
            "Meetings, hours and words counted locally, never shared.",
            "Whisper model, retention and language — all on-device.",
        ],
    ),
    "zh-Hans": dict(
        lat=False,
        head=[
            ("会议结束，", "纪要已就位。"),
            ("待办自动", "从对话里拎出来。"),
            ("一键跳回", "那句话。"),
            ("零上传，", "架构如此。"),
            ("时间花在哪，", "一眼看清。"),
            ("模型与规则，", "都由你定。"),
        ],
        sub=[
            "摘要、决议与待办——在你自己的 Mac 上生成，不联网。",
            "负责人、截止时间与下一步，自动抽取，不用会后追问。",
            "带时间戳的关键节点，点一下就从那一刻重听。",
            "音频、逐字稿与纪要只留在本机，完全离线可用。",
            "会议数、时长与字数，本地统计，绝不上传。",
            "转写模型、音频保留与界面语言，全部本地设置。",
        ],
    ),
    "zh-Hant": dict(
        lat=False,
        head=[
            ("會議結束，", "紀要已就位。"),
            ("待辦自動", "從對話裡挑出來。"),
            ("一鍵跳回", "那句話。"),
            ("零上傳，", "架構如此。"),
            ("時間花在哪，", "一眼看清。"),
            ("模型與規則，", "都由你定。"),
        ],
        sub=[
            "摘要、決議與待辦——在你自己的 Mac 上產生，不連網。",
            "負責人、截止時間與下一步，自動擷取，不用會後追問。",
            "帶時間戳的關鍵節點，點一下就從那一刻重聽。",
            "音訊、逐字稿與紀要只留在本機，完全離線可用。",
            "會議數、時長與字數，本機統計，絕不上傳。",
            "轉寫模型、音訊保留與介面語言，全部本機設定。",
        ],
    ),
    "ja": dict(
        lat=False,
        head=[
            ("会議が終われば、", "議事録はもうできている。"),
            ("アクションは", "会議から自動で。"),
            ("あの一言へ", "ワンクリック。"),
            ("送信ゼロ。", "設計からそう。"),
            ("時間の使い方が", "一目でわかる。"),
            ("モデルも設定も、", "自分で決める。"),
        ],
        sub=[
            "要約・決定事項・アクションを、この Mac の中で。オフラインで。",
            "担当者・期限・次の一手を自動で抽出。後追いの確認は不要です。",
            "タイムスタンプ付きの要点。クリックすればその瞬間から再生します。",
            "音声・文字起こし・議事録はこの Mac の中だけ。完全オフライン。",
            "会議数・時間・文字数をローカルで集計。共有はしません。",
            "文字起こしモデル・音声の保持・表示言語をすべて端末内で。",
        ],
    ),
    "ko": dict(
        lat=False,
        head=[
            ("회의가 끝나면,", "회의록은 이미 완성."),
            ("할 일은", "회의에서 바로."),
            ("그 말로", "바로 점프."),
            ("업로드 제로.", "설계부터."),
            ("시간이 어디로", "가는지 한눈에."),
            ("모델도 설정도", "내 마음대로."),
        ],
        sub=[
            "요약·결정 사항·할 일을 이 Mac 안에서. 오프라인으로.",
            "담당자·마감일·다음 단계를 자동으로 추출합니다.",
            "타임스탬프가 붙은 핵심 지점. 클릭하면 그 순간부터 재생.",
            "오디오·받아쓰기·회의록은 이 Mac에만. 완전 오프라인.",
            "회의 수·시간·단어 수를 로컬에서 집계합니다.",
            "받아쓰기 모델·보관 기간·언어를 모두 기기에서.",
        ],
    ),
    "fr": dict(
        lat=True,
        head=[
            ("La réunion finit.", "Les notes sont prêtes."),
            ("Les actions,", "tirées de l'échange."),
            ("Revenez", "au bon moment."),
            ("Zéro envoi.", "Par conception."),
            ("Où passent", "vos heures."),
            ("Vos modèles,", "vos règles."),
        ],
        sub=[
            "Résumé, décisions et actions — écrits sur votre Mac, hors ligne.",
            "Responsables, échéances et prochaines étapes, extraits automatiquement.",
            "Moments clés horodatés. Un clic et la lecture reprend à cet instant.",
            "Audio, transcriptions et notes restent sur ce Mac. Hors ligne.",
            "Réunions, heures et mots comptés en local, jamais partagés.",
            "Modèle Whisper, conservation et langue — tout sur l'appareil.",
        ],
    ),
    "de": dict(
        lat=True,
        head=[
            ("Das Meeting endet.", "Die Notizen stehen."),
            ("Aufgaben,", "direkt aus dem Gespräch."),
            ("Zurück zum", "richtigen Moment."),
            ("Kein Upload.", "Von Grund auf."),
            ("Wohin die", "Stunden gehen."),
            ("Deine Modelle,", "deine Regeln."),
        ],
        sub=[
            "Zusammenfassung, Entscheidungen und Aufgaben — auf deinem Mac, offline.",
            "Verantwortliche, Fristen und nächste Schritte — automatisch extrahiert.",
            "Zeitgestempelte Schlüsselmomente. Ein Klick springt genau dorthin.",
            "Audio, Transkripte und Notizen bleiben auf diesem Mac. Offline.",
            "Meetings, Stunden und Wörter lokal gezählt, nie geteilt.",
            "Whisper-Modell, Aufbewahrung und Sprache — alles auf dem Gerät.",
        ],
    ),
    "es": dict(
        lat=True,
        head=[
            ("La reunión termina.", "Las notas ya están."),
            ("Tareas,", "directas de la llamada."),
            ("Vuelve al", "momento exacto."),
            ("Cero subidas.", "Por diseño."),
            ("Dónde van", "tus horas."),
            ("Tus modelos,", "tus reglas."),
        ],
        sub=[
            "Resumen, decisiones y tareas — escritos en tu Mac, sin conexión.",
            "Responsables, fechas y próximos pasos, extraídos automáticamente.",
            "Momentos clave con marca de tiempo. Un clic y sigue desde ahí.",
            "Audio, transcripciones y notas se quedan en este Mac. Sin conexión.",
            "Reuniones, horas y palabras contadas en local, nunca compartidas.",
            "Modelo Whisper, retención e idioma — todo en el dispositivo.",
        ],
    ),
}


def font(loc, size, bold=False):
    """每个语言挑一套字形完整的字体：韩文/繁中曾因字体回退变成方框。"""
    if loc == "ko":
        f = ImageFont.truetype(F_KO, size, index=0)
        return f
    if loc == "ja":
        return ImageFont.truetype(F_HIRA_W6 if bold else F_HIRA_W3, size, index=0)
    if loc.startswith("zh"):
        return ImageFont.truetype(F_HEI_M if bold else F_HEI_L, size, index=0)
    return ImageFont.truetype(F_LAT, size, index=1 if bold else 0)


def draw_text(d, xy, text, loc, size, bold=False, fill=PAPER):
    f = font(loc, size, bold)
    kw = {}
    if loc == "ko" and bold:
        kw["stroke_width"] = max(1, size // 26)   # AppleSDGothic 只有一个字重
        kw["stroke_fill"] = fill
    d.text(xy, text, font=f, fill=fill, **kw)
    return f


def text_len(text, loc, size, bold=False):
    f = font(loc, size, bold)
    return f.getlength(text)


def fit_size(loc, lines, maxw, start=62, floor=38):
    size = start
    while size > floor and any(text_len(l, loc, size, True) > maxw for l in lines):
        size -= 2
    return size


def wrap(text, loc, size, maxw):
    f = font(loc, size, False)
    out, cur = [], ""
    for ch in text:
        if f.getlength(cur + ch) <= maxw or not cur:
            cur += ch
        else:
            if " " in cur and not ("\u3000" <= ch <= "\u9fff"):
                i = cur.rfind(" ")
                out.append(cur[:i])
                cur = cur[i + 1:] + ch
            else:
                out.append(cur)
                cur = ch
    if cur:
        out.append(cur)
    return out


def ink_bg(w, h):
    im = Image.new("RGB", (w, h), INK)
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)],
               fill=tuple(int(INK[i] + (INK_2[i] - INK[i]) * t) for i in range(3)))
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([int(w * 0.48), int(h * 0.30), int(w * 1.16), int(h * 1.10)],
               fill=(44, 33, 18))
    gd.ellipse([int(w * -0.40), int(h * -0.42), int(w * 0.52), int(h * 0.30)],
               fill=(20, 24, 34))
    glow = glow.filter(ImageFilter.GaussianBlur(230))
    return Image.blend(im, glow, 0.62)


def draw_center(d, y, text, loc, size, bold=False, fill=PAPER):
    w = int(text_len(text, loc, size, bold))
    draw_text(d, ((W - w) // 2, y), text, loc, size, bold, fill)


def brand(canvas, loc, top):
    tile = Image.new("RGBA", (44, 44), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile)
    td.rounded_rectangle([0, 0, 43, 43], radius=11, fill=AMBER + (46,))
    for i, bh in enumerate((12, 24, 17)):
        x = 13 + i * 7
        td.rounded_rectangle([x, 22 - bh // 2, x + 3, 22 + bh // 2], radius=1.5, fill=AMBER + (255,))
    name = "KinetMinutes"
    x = (W - 44 - 16 - int(text_len(name, loc, 30, True))) // 2
    canvas.paste(tile, (x, top), tile)
    draw_text(ImageDraw.Draw(canvas), (x + 58, top + 4), name, loc, 30, True, AMBER)


def paste_window(canvas, shot_path, cfg, y):
    raw = Image.open(shot_path).convert("RGB").crop(cfg["crop"])
    win_w = cfg["w"]
    win_h = int(round(win_w * raw.height / raw.width))
    raw = raw.resize((win_w, win_h), Image.LANCZOS)
    win_x = (W - win_w) // 2

    shadow = Image.new("RGBA", (win_w + 160, win_h + 160), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([80, 96, 80 + win_w, 96 + win_h], radius=30, fill=(0, 0, 0, 190))
    shadow = shadow.filter(ImageFilter.GaussianBlur(46))
    canvas.paste(shadow, (win_x - 80, y - 80), shadow)

    mask = Image.new("L", (win_w, win_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, win_w - 1, win_h - 1],
                                           radius=cfg.get("r", 18), fill=255)
    canvas.paste(raw, (win_x, y), mask)

    ring = Image.new("RGBA", (win_w + 8, win_h + 8), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle([0, 0, win_w + 7, win_h + 7],
                                           radius=cfg.get("r", 18) + 4,
                                           outline=AMBER + (110,), width=2)
    canvas.paste(ring, (win_x - 4, y - 4), ring)
    return win_x, win_w, win_h


def recording_pill(canvas, loc, right, top):
    """窗口右上角的「正在录音」胶囊，给首图一个会议正在发生的锚点。"""
    label = REC.get(loc, "Recording")
    t = "00:32:18"
    f_lab = font(loc, 21, True)
    f_time = ImageFont.truetype(F_LAT, 21, index=0)
    pad, dot, gap = 18, 11, 12
    w = int(pad + dot + gap + f_lab.getlength(label) + 10 + f_time.getlength(t) + pad)
    h = 46
    pill = Image.new("RGBA", (w + 40, h + 40), (0, 0, 0, 0))
    pd = ImageDraw.Draw(pill)
    pd.rounded_rectangle([20, 20, 20 + w, 20 + h], radius=h // 2, fill=(24, 28, 38, 246))
    pd.rounded_rectangle([20, 20, 20 + w, 20 + h], radius=h // 2,
                         outline=(255, 255, 255, 30), width=1)
    cy = 20 + h // 2
    pd.ellipse([20 + pad, cy - dot // 2, 20 + pad + dot, cy + dot // 2], fill=(235, 96, 82, 255))
    tx = 20 + pad + dot + gap
    pd.text((tx, cy), label, font=f_lab, fill=(240, 242, 246), anchor="lm")
    pd.text((tx + f_lab.getlength(label) + 10, cy), t, font=f_time, fill=AMBER, anchor="lm")
    canvas.paste(pill, (right - w - 20, top - 20), pill)


def build(loc, shot, src_name):
    cfg = COPY[loc]
    idx = [s[0] for s in SHOTS].index(shot)
    frame = SHOT_CFG[shot]
    canvas = ink_bg(W, H)
    d = ImageDraw.Draw(canvas)

    lines = cfg["head"][idx]
    size = fit_size(loc, lines, TEXT_MAX, start=84, floor=48)
    sub_size = 28
    sub_lines = wrap(cfg["sub"][idx], loc, sub_size, 1500)

    # 横向满宽的标题 + 居中窗口：标题可以给到 80pt 以上，截图占画布 78% 宽。
    brand(canvas, loc, 78)
    y = 150
    for line in lines:
        draw_center(d, y, line, loc, size, True, PAPER)
        y += int(size * 1.14)

    y += 16
    for line in sub_lines:
        draw_center(d, y, line, loc, sub_size, False, MUTED)
        y += int(sub_size * 1.50)

    win_y = min(max(y + frame["gap"] - 24, 430), 520)
    win_x, win_w, win_h = paste_window(canvas,
                                       os.path.join(SRC, loc, src_name + ".png"),
                                       frame, win_y)
    if shot == "hero":
        recording_pill(canvas, loc, win_x + win_w - 26, win_y + 24)

    outdir = os.path.join(OUT, loc)
    os.makedirs(outdir, exist_ok=True)
    dest = os.path.join(outdir, "%02d-%s.png" % (idx + 1, shot))
    canvas.save(dest)
    print("%-8s %-9s <- %s  (win %dx%d @%d)" % (loc, shot, src_name, win_w, win_h, win_y))


if __name__ == "__main__":
    for loc in (sys.argv[1:] or list(COPY)):
        for shot, src in SHOTS:
            build(loc, shot, src)
