#!/usr/bin/env python3
"""Схема раскладки экранов аркады — картинки для проверки пропорций.

Читает константы из core/Layout.gd (единственный источник координат) и рисует
схемы меню, «Трона», «Разортрона», аэрохоккея, «Неон-джампа», «Неон-тетриса»
и «Световых мечей». Нужен, чтобы видеть сетку
без запуска Godot: поля, шапка, сцена, панели, кегли.

  python3 tools/layout_preview.py            # → tools/layout_*.png
  python3 tools/layout_preview.py --scale 1  # в полный размер 1920×1080
"""
import argparse
import os
import re
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("нужен Pillow: pip install pillow")
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
LAYOUT = os.path.join(os.path.dirname(HERE), "core", "Layout.gd")

BG = (5, 0, 20)
PANEL = (12, 4, 28)
LINE = (138, 92, 255)
DIM = (158, 168, 235)
TEXT = (225, 235, 255)
ACCENTS = [(0, 234, 255), (255, 61, 242), (115, 255, 89), (255, 199, 51),
           (168, 107, 255), (255, 115, 77)]


def load_consts():
    src = open(LAYOUT, encoding="utf-8").read()
    out = {}
    for m in re.finditer(r"^const (\w+) := Rect2\(([^)]*)\)", src, re.M):
        vals = [float(v.strip()) for v in m.group(2).split(",")]
        out[m.group(1)] = tuple(vals)
    for m in re.finditer(r"^const (\w+) := (-?[\d.]+)\s*(?:#.*)?$", src, re.M):
        out[m.group(1)] = float(m.group(2))
    for m in re.finditer(r"^const (T_\w+) := (\d+)", src, re.M):
        out[m.group(1)] = float(m.group(2))
    for m in re.finditer(r"^const (\w+) := Color\(([^)]*)\)", src, re.M):
        out[m.group(1)] = tuple(float(v.strip()) for v in m.group(2).split(","))
    return out


C = load_consts()
S = 0.5   # масштаб по умолчанию


def sc(v):
    return v * S


def font(px):
    size = max(int(round(px * S)), 6)
    for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                 "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def text(d, xy, s, px, color=TEXT, anchor="ls"):
    # «ls» — как в Godot: позиция это базовая линия текста
    d.text((sc(xy[0]), sc(xy[1])), s, font=font(px), fill=color, anchor=anchor)


def rect(d, r, color=LINE, w=1):
    x, y, rw, rh = r
    d.rectangle([sc(x), sc(y), sc(x + rw), sc(y + rh)], outline=color, width=max(int(w), 1))


def fill(d, r, color):
    x, y, rw, rh = r
    d.rectangle([sc(x), sc(y), sc(x + rw), sc(y + rh)], fill=color)


def panel(d, r, label="", accent=LINE, fill_color=PANEL):
    fill(d, r, fill_color)
    rect(d, r, accent, 2)
    k = 14
    x, y, rw, rh = r
    for (px, py, dx, dy) in ((x, y, 1, 1), (x + rw, y, -1, 1), (x, y + rh, 1, -1), (x + rw, y + rh, -1, -1)):
        d.line([sc(px), sc(py), sc(px + dx * k), sc(py)], fill=accent, width=2)
        d.line([sc(px), sc(py), sc(px), sc(py + dy * k)], fill=accent, width=2)
    if label:
        pad = C.get("PAD", 16.0)
        text(d, (x + pad, y + pad + C["T_TINY"]), label.upper(), C["T_TINY"], DIM)


def header(d, title, subtitle, right_top, right_bottom, accent=TEXT):
    M = C["M"]
    text(d, (M, 88), title, C["T_DISPLAY"], accent)
    if subtitle:
        text(d, (M, 124), subtitle, C["T_SMALL"], DIM)
    if right_top:
        text(d, (C["W"] - M, 98), right_top, C["T_H2"], TEXT, anchor="rs")
    if right_bottom:
        text(d, (C["W"] - M, 128), right_bottom, C["T_SMALL"], DIM, anchor="rs")
    y = C["HEADER_H"]
    d.line([sc(M), sc(y), sc(C["W"] - M), sc(y)], fill=LINE, width=1)


def grid(d):
    """Колонки сетки — для наглядности."""
    for i in range(13):
        x = C["M"] + i * (C["COL"] + C["GUT"])
        d.line([sc(x), 0, sc(x), sc(C["H"])], fill=(40, 24, 80), width=1)


def cam_panel(d, r, accent=ACCENTS[0]):
    panel(d, r, "камера", accent)
    fr = C.get("PAD", 16.0)
    w = r[2] - fr * 2
    h = w * 9 / 16
    y = r[1] + fr + C["T_TINY"] + 16
    fill(d, (r[0] + fr, y, w, h), (26, 8, 44))
    rect(d, (r[0] + fr, y, w, h), accent, 1)
    text(d, (r[0] + fr + 10, y + h - 12), "ВЫ В КАДРЕ", 15, (255, 255, 255))


def hint_panel(d, r, active="face", stacked=False):
    panel(d, r, "как управлять", ACCENTS[0])
    pad = C["PAD"]
    x, y, w, h = r[0] + pad, r[1] + pad + C["T_TINY"] + 16, r[2] - pad * 2, r[3] - pad * 2 - C["T_TINY"] - 16
    rows = ["БЛИЗКО — ЛИЦОМ", "ДАЛЕКО — РУКОЙ"]
    subs = ["поворачивайте голову — курсор идёт за носом",
            "поднимите руку и ведите ей — курсор за ладонью"]
    on = [active == "face", active == "hand"]
    rh = h / 2 - 5
    compact = rh < 46
    for i in range(2):
        ry = y + i * (rh + 10)
        col = ACCENTS[0] if i == 0 else ACCENTS[1]
        c = col if on[i] else (60, 60, 90)
        rect(d, (x, ry, w, rh), c, 2 if on[i] else 1)
        if compact:
            d.ellipse([sc(x + 10), sc(ry + rh / 2 - 13), sc(x + 36), sc(ry + rh / 2 + 13)], outline=c, width=2)
            text(d, (x + 48, ry + rh / 2 + 6), rows[i], C["T_SMALL"], TEXT if on[i] else DIM)
            continue
        if stacked:
            d.ellipse([sc(x + w / 2 - 18), sc(ry + 10), sc(x + w / 2 + 18), sc(ry + 46)], outline=c, width=2)
            text(d, (x + w / 2, ry + rh - 30), rows[i], C["T_SMALL"], TEXT if on[i] else DIM, anchor="ma")
        else:
            d.ellipse([sc(x + 14), sc(ry + rh / 2 - 18), sc(x + 50), sc(ry + rh / 2 + 18)], outline=c, width=2)
            text(d, (x + 62, ry + rh / 2 - 12), rows[i], C["T_SMALL"], TEXT if on[i] else DIM)
            if rh > 44:
                text(d, (x + 62, ry + rh / 2 + 8), subs[i], C["T_TINY"] - 1, DIM)


def footer_line(d, y, s, color=DIM, center=False):
    text(d, ((C["W"] / 2, y) if center else (C["M"], y)), s, C["T_BODY"], color,
         anchor="ms" if center else "ls")


# ---------------------------------------------------------------- экраны


def screen_menu():
    img = Image.new("RGB", (int(sc(C["W"])), int(sc(C["H"]))), BG)
    d = ImageDraw.Draw(img)
    grid(d)
    header(d, "NEON ARCADE", "неоновая аркада · голосование лицом", "в кадре: 2",
           "1..6 — выбрать · Enter — начать")
    cards = [("АЭРОХОККЕЙ", "ровно 2 игрока", "ракетки в своих половинах"),
             ("ТРОН", "1–4 игрока", "световой след не прощает"),
             ("РАЗОРТРОН 2000", "1–6 игроков", "гонка в закат до финиша"),
             ("НЕОН-ДЖАМП", "1–4 игрока", "прыгай выше всех"),
             ("НЕОН-ТЕТРИС", "1–4 игрока", "стакан на каждого · жест — сброс"),
             ("СВЕТОВЫЕ МЕЧИ", "ровно 2 игрока", "стойка — защита · жест — укол")]
    base = C["MENU_CARD"]
    for i, (title, who, hint) in enumerate(cards):
        r = (base[0] + (i % 3) * C["MENU_CARD_STEP"],
             base[1] + (i // 3) * C["MENU_ROW_STEP"], base[2], base[3])
        col = ACCENTS[i]
        panel(d, r, "", col)
        g = (r[0] + 24, r[1] + 51, 130, 130)
        rect(d, g, (30, 16, 62), 1)
        cxg, cyg = g[0] + g[2] / 2, g[1] + g[3] / 2
        if i == 0:
            d.line([sc(cxg), sc(g[1] + 12), sc(cxg), sc(g[1] + g[3] - 12)], fill=(90, 60, 170), width=2)
            d.ellipse([sc(g[0] + 20), sc(cyg - 20), sc(g[0] + 60), sc(cyg + 20)], outline=col, width=2)
            d.ellipse([sc(g[0] + g[2] - 60), sc(cyg - 20), sc(g[0] + g[2] - 20), sc(cyg + 20)],
                      outline=ACCENTS[1], width=2)
        elif i == 1:
            for j, c2 in enumerate((ACCENTS[0], ACCENTS[1])):
                d.line([sc(g[0] + 20), sc(cyg - 20 + j * 40), sc(g[0] + g[2] - 20), sc(cyg - 20 + j * 40)],
                       fill=c2, width=3)
        elif i == 2:
            d.line([sc(g[0] + 18), sc(g[1] + g[3] - 6), sc(cxg - 8), sc(g[1] + 34)], fill=ACCENTS[0], width=2)
            d.line([sc(g[0] + g[2] - 18), sc(g[1] + g[3] - 6), sc(cxg + 8), sc(g[1] + 34)], fill=ACCENTS[1], width=2)
            d.ellipse([sc(cxg - 20), sc(g[1] + 14), sc(cxg + 20), sc(g[1] + 54)], outline=ACCENTS[3], width=2)
        elif i == 3:
            for j, c2 in enumerate((ACCENTS[0], ACCENTS[2], ACCENTS[0])):
                py = g[1] + g[3] - 26 - j * 34
                d.line([sc(g[0] + 12 + (0 if j % 2 == 0 else 44)), sc(py),
                        sc(g[0] + 84 + (0 if j % 2 == 0 else 44)), sc(py)], fill=c2, width=3)
            ox, oy = g[0] + g[2] - 46, g[1] + 34
            d.ellipse([sc(ox - 13), sc(oy - 13), sc(ox + 13), sc(oy + 13)], outline=ACCENTS[1], width=2)
        elif i == 4:
            bw = 20
            bx, by = cxg - bw * 2, g[1] + g[3] - 14
            for k in range(4):
                fill(d, (bx + k * bw, by - bw, bw - 2, bw - 2), ACCENTS[0])
            for dx, dy in ((0, 3), (1, 3), (1, 4)):
                fill(d, (bx + dx * bw, by - (dy + 1) * bw, bw - 2, bw - 2), ACCENTS[1])
            d.line([sc(bx - 4), sc(by - bw * 5), sc(bx - 4), sc(by)], fill=(90, 60, 170), width=1)
            d.line([sc(bx + bw * 4 + 4), sc(by - bw * 5), sc(bx + bw * 4 + 4), sc(by)], fill=(90, 60, 170), width=1)
        else:
            d.line([sc(g[0] + 20), sc(g[1] + g[3] - 18), sc(g[0] + 72), sc(g[1] + 20)], fill=ACCENTS[0], width=4)
            d.line([sc(g[0] + g[2] - 20), sc(g[1] + g[3] - 18), sc(g[0] + g[2] - 72), sc(g[1] + 20)],
                   fill=ACCENTS[1], width=4)
            d.ellipse([sc(cxg - 16), sc(cyg - 16), sc(cxg + 16), sc(cyg + 16)], outline=ACCENTS[3], width=2)
        tx = r[0] + 174
        text(d, (tx, r[1] + 92), title, C["T_H2"], TEXT)
        text(d, (tx, r[1] + 122), who, C["T_SMALL"], col)
        text(d, (tx, r[1] + 150), hint, C["T_TINY"], DIM)
        bot = r[1] + r[3]
        for j in range(min(i, 2)):
            d.ellipse([sc(tx + j * 16), sc(r[1] + 170), sc(tx + 12 + j * 16), sc(r[1] + 182)], fill=ACCENTS[j])
        text(d, (tx, bot - 32), ("%d голос" % i) if i else "нет голосов", C["T_SMALL"], TEXT)
        bx, by = r[0] + r[2] - 24 - 44, bot - 68
        rect(d, (bx, by, 44, 44), col, 2)
        text(d, (bx + 22, by + 34), str(i + 1), C["T_H2"], col, anchor="ms")
    cam_panel(d, C["MENU_CAM"])
    hint_panel(d, C["MENU_HINT"], "face")
    # фишки игроков
    ch = C["MENU_CHIPS"]
    for i in range(2):
        px = ch[0] + 40 + i * 240
        d.ellipse([sc(px), sc(ch[1] + 12), sc(px + 32), sc(ch[1] + 44)], outline=ACCENTS[i], width=2)
        text(d, (px + 44, ch[1] + 24), "ИГРОК %d" % (i + 1), C["T_H2"], TEXT)
        text(d, (px + 44, ch[1] + 48), "не голосовал", C["T_SMALL"], DIM)
    footer_line(d, C["FOOT_Y"] + 34, "отклоните лицо к плитке и задержите — это ваш голос")
    return img


def screen_tetris():
    img = Image.new("RGB", (int(sc(C["W"])), int(sc(C["H"]))), BG)
    d = ImageDraw.Draw(img)
    grid(d)
    header(d, "НЕОН-ТЕТРИС", "четыре стакана · до 10 линий · жест — поворот, удержание — сброс",
           "раунд 1:12", "штраф за полный стакан: −300")
    a = C["TETRIS_AREA"]
    fill(d, a, (4, 0, 18))
    rect(d, a, LINE, 1)
    bw, step, bh = 328, 344, 720
    for i in range(4):
        r = (a[0] + i * step, a[1], bw, bh)
        panel(d, r, "", ACCENTS[i])
        text(d, (r[0] + 16, r[1] + 32), "ИГРОК %d" % (i + 1), C["T_H2"], TEXT)
        text(d, (r[0] + bw - 16, r[1] + 32), "%d" % (1240 - i * 380), C["T_H2"], ACCENTS[i], anchor="ra")
        fx, fy = r[0] + 24, r[1] + 56
        fill(d, (fx, fy, 280, 560), (2, 0, 12))
        for k in range(1, 10):
            d.line([sc(fx + k * 28), sc(fy), sc(fx + k * 28), sc(fy + 560)], fill=(36, 22, 80), width=1)
        for k in range(1, 20):
            d.line([sc(fx), sc(fy + k * 28), sc(fx + 280), sc(fy + k * 28)], fill=(36, 22, 80), width=1)
        rect(d, (fx, fy, 280, 560), (90, 60, 170), 1)
        # несколько лежащих клеток и падающая фигура
        for row in range(18, 20):
            for col in range(3 + i, 7 + i):
                fill(d, (fx + col * 28 + 2, fy + row * 28 + 2, 24, 24), ACCENTS[(col + row) % 4])
        for dx, dy in ((0, 0), (1, 0), (2, 0), (1, 1)):
            fill(d, (fx + (3 + i + dx) * 28 + 2, fy + (6 + dy) * 28 + 2, 24, 24), ACCENTS[i])
        text(d, (r[0] + 16, fy + 588), "линии %d" % (i + 2), C["T_SMALL"], TEXT)
        text(d, (r[0] + 16, fy + 614), "до 10", C["T_TINY"], DIM)
        text(d, (r[0] + bw - 16, fy + 588), "далее", C["T_TINY"], DIM, anchor="ra")
        for dx, dy in ((0, 0), (1, 0), (0, 1), (1, 1)):
            fill(d, (r[0] + bw - 70 + dx * 18, fy + 600 + dy * 18, 16, 16), ACCENTS[i])
    cam_panel(d, C["TETRIS_CAM"])
    hint_panel(d, C["TETRIS_HINT"], "face")
    st = C["TETRIS_STATUS"]
    panel(d, st, "состояние", LINE)
    pad = C["PAD"]
    ty = st[1] + pad + C["T_TINY"] + 14
    for i, (k, v) in enumerate((("ввод", "лицо"), ("данные", "42 мс"),
                                ("линий", "4"), ("штрафов", "1"))):
        text(d, (st[0] + pad, ty + i * 22), k, C["T_TINY"], DIM)
        text(d, (st[0] + pad + 108, ty + i * 22), v, C["T_TINY"], TEXT)
    footer_line(d, C["FOOT_Y"] + 36,
                "наклон влево-вправо — сдвиг · вниз — быстрее · жест — поворот · держите жест — сброс")
    footer_line(d, C["FOOT_Y"] + 72, "1..5 — режим ввода · ESC — меню")
    return img


def screen_saber():
    img = Image.new("RGB", (int(sc(C["W"])), int(sc(C["H"]))), BG)
    d = ImageDraw.Draw(img)
    grid(d)
    header(d, "СВЕТОВЫЕ МЕЧИ", "дуэль на двоих · рука вверх — блок · жест — выпад",
           "2 : 1", "раунд 0:42 · удар −25 из 100")
    a = C["SABER_ARENA"]
    fill(d, a, (6, 0, 24))
    fy = a[1] + a[3] - 120
    cx = a[0] + a[2] / 2
    # зал: дуги, центральная линия, разметка пола
    for i in range(4):
        r = 260 + i * 150
        d.arc([sc(cx - r), sc(fy + 60 - r), sc(cx + r), sc(fy + 60 + r)], 200, 340, fill=(70, 40, 130), width=2)
    d.line([sc(cx), sc(a[1] + 40), sc(cx), sc(fy + 8)], fill=(60, 40, 110), width=2)
    d.line([sc(a[0] + 24), sc(fy + 8), sc(a[0] + a[2] - 24), sc(fy + 8)], fill=ACCENTS[0], width=3)
    d.line([sc(a[0] + 24), sc(fy + 26), sc(a[0] + a[2] - 24), sc(fy + 26)], fill=(90, 60, 170), width=1)
    for i in range(13):
        x = a[0] + 24 + i * (a[2] - 48) / 12
        d.line([sc(x), sc(fy + 8), sc(x), sc(fy + 22)], fill=(90, 60, 170), width=1)
    for side in (0, 1):
        px = cx - 190 if side == 0 else cx + 190
        face = 1 if side == 0 else -1
        col = ACCENTS[side]
        # арка за бойцом
        d.arc([sc(px - 200), sc(fy + 10 - 200), sc(px + 200), sc(fy + 10 + 200)], 180, 360, fill=col, width=3)
        d.arc([sc(px - 150), sc(fy + 10 - 150), sc(px + 150), sc(fy + 10 + 150)], 180, 360, fill=col, width=2)
        # полоса здоровья, имя, счёт
        rect(d, (px - 130, fy - 432, 260, 16), (90, 60, 170), 1)
        fill(d, (px - 129, fy - 431, 250 - side * 90, 14), col)
        text(d, (px, fy - 452), "ИГРОК %d" % (side + 1), C["T_SMALL"], TEXT, anchor="ms")
        text(d, (px, fy - 408), "удары %d · блоки %d" % (2 - side, side), C["T_TINY"], DIM, anchor="ms")
        # ноги, корпус, голова
        d.line([sc(px - 44), sc(fy), sc(px), sc(fy - 160)], fill=col, width=6)
        d.line([sc(px + 44), sc(fy), sc(px), sc(fy - 160)], fill=col, width=6)
        d.line([sc(px), sc(fy - 160), sc(px), sc(fy - 320)], fill=col, width=7)
        d.line([sc(px - 16), sc(fy - 320), sc(px + 16), sc(fy - 320)], fill=col, width=5)
        d.ellipse([sc(px - 30), sc(fy - 398), sc(px + 30), sc(fy - 338)], outline=col, width=3)
        # рука и клинок
        wy = fy - 320 - (70 if side == 1 else 0)
        wx = px + face * 50
        d.line([sc(px), sc(fy - 320), sc(wx), sc(wy)], fill=col, width=5)
        d.line([sc(wx), sc(wy), sc(wx + face * 270), sc(wy)], fill=(240, 245, 255), width=4)
        d.ellipse([sc(wx + face * 270 - 7), sc(wy - 7), sc(wx + face * 270 + 7), sc(wy + 7)], fill=ACCENTS[3])
        if side == 1:
            d.arc([sc(px - 66), sc(fy - 390), sc(px + 66), sc(fy - 258)], 200, 340, fill=ACCENTS[3], width=4)
    # полоса оверлея
    rect(d, (cx - 430, fy + 14, 860, 98), LINE, 1)
    text(d, (cx, fy + 56), "БОЙ!", C["T_H1"], ACCENTS[3], anchor="ms")
    text(d, (cx, fy + 94), "поднимите руку — это стойка · жест — выпад", C["T_SMALL"], DIM, anchor="ms")
    rect(d, a, LINE, 2)
    cam_panel(d, C["SABER_CAM"])
    hint_panel(d, C["SABER_HINT"], "face")
    st = C["SABER_STATUS"]
    panel(d, st, "состояние", LINE)
    pad = C["PAD"]
    ty = st[1] + pad + C["T_TINY"] + 14
    for i, (k, v) in enumerate((("ввод", "лицо"), ("данные", "42 мс"),
                                ("попаданий", "3"), ("блоков", "1"))):
        text(d, (st[0] + pad, ty + i * 22), k, C["T_TINY"], DIM)
        text(d, (st[0] + pad + 108, ty + i * 22), v, C["T_TINY"], TEXT)
    footer_line(d, C["FOOT_Y"] + 36,
                "рука вверх — стойка (блок) · рука вперёд — клинок в соперника · жест — выпад")
    footer_line(d, C["FOOT_Y"] + 72, "1..5 — режим ввода · ESC — меню")
    return img


def screen_tron():
    img = Image.new("RGB", (int(sc(C["W"])), int(sc(C["H"]))), BG)
    d = ImageDraw.Draw(img)
    grid(d)
    header(d, "ТРОН", "световой след не прощает · 1–4 игрока", "раунд 1:2", "до 3 побед")
    a = C["TRON_ARENA"]
    fill(d, a, (4, 0, 18))
    rect(d, a, LINE, 2)
    # клетки арены 68×36 по 20 px
    for i in range(1, 68):
        d.line([sc(a[0] + i * 20), sc(a[1]), sc(a[0] + i * 20), sc(a[1] + a[3])],
               fill=(30, 18, 66), width=1)
    for j in range(1, 36):
        d.line([sc(a[0]), sc(a[1] + j * 20), sc(a[0] + a[2]), sc(a[1] + j * 20)],
               fill=(30, 18, 66), width=1)
    # следы и мотоциклы
    trails = [((120, 120), (520, 120), (520, 400)), ((800, 520), (1160, 520)),
              ((300, 620), (300, 300), (700, 300)), ((1000, 180), (1260, 180), (1260, 440))]
    for i, pts in enumerate(trails):
        col = ACCENTS[i]
        for k in range(len(pts) - 1):
            d.line([sc(a[0] + pts[k][0]), sc(a[1] + pts[k][1]),
                    sc(a[0] + pts[k + 1][0]), sc(a[1] + pts[k + 1][1])], fill=col, width=4)
        hx, hy = pts[-1]
        d.rectangle([sc(a[0] + hx - 8), sc(a[1] + hy - 8), sc(a[0] + hx + 8), sc(a[1] + hy + 8)],
                    outline=col, width=3)
        text(d, (a[0] + hx, a[1] + hy - 24), "ИГРОК %d" % (i + 1), C["T_TINY"], DIM, anchor="ms")
    sr = C["TRON_SCORES"]
    for i in range(4):
        cw = (sr[2] - 3 * 20) / 4
        px = sr[0] + i * (cw + 20)
        fill(d, (px, sr[1], cw, sr[3]), (10, 4, 24))
        rect(d, (px, sr[1], cw, sr[3]), ACCENTS[i], 2)
        d.ellipse([sc(px + 16), sc(sr[1] + 28), sc(px + 34), sc(sr[1] + 46)], fill=ACCENTS[i])
        text(d, (px + 48, sr[1] + 22), "ИГРОК %d" % (i + 1), C["T_SMALL"], TEXT)
        text(d, (px + 48, sr[1] + 44), "побед: %d" % (i % 3), C["T_TINY"], DIM)
    cam_panel(d, C["TRON_CAM"])
    hint_panel(d, C["TRON_HINT"], "face")
    st = C["TRON_STATUS"]
    panel(d, st, "состояние", LINE)
    pad = C["PAD"]
    ty = st[1] + pad + C["T_TINY"] + 14
    for i, (k, v) in enumerate((("ввод", "лицо"), ("данные", "42 мс"),
                                ("поворотов", "18"), ("живых", "3"))):
        text(d, (st[0] + pad, ty + i * 20), k, C["T_TINY"], DIM)
        text(d, (st[0] + pad + 108, ty + i * 20), v, C["T_TINY"], TEXT)
    footer_line(d, C["FOOT_Y"] + 36, "наклон — поворот · жест — ускорение · врезался — выбыл")
    footer_line(d, C["FOOT_Y"] + 72, "1..5 — режим ввода · ESC — меню")
    return img


def screen_razor():
    img = Image.new("RGB", (int(sc(C["W"])), int(sc(C["H"]))), BG)
    d = ImageDraw.Draw(img)
    grid(d)
    header(d, "РАЗОРТРОН 2000", "гонка в закат · 1–6 игроков · до финиша 1200 м",
           "1-й: 940 м", "раунд 0:48")
    road = C["RAZOR_ROAD"]
    fill(d, road, (8, 0, 24))
    rect(d, road, LINE, 2)
    cx = road[0] + road[2] / 2
    hz = road[1] + 170
    # солнце на горизонте и две кромки шоссе
    d.ellipse([sc(cx - 90), sc(hz - 90), sc(cx + 90), sc(hz + 90)], outline=ACCENTS[1], width=3)
    for sx in (-1, 1):
        d.line([sc(cx + sx * 70), sc(hz), sc(cx + sx * 470), sc(road[1] + road[3])],
               fill=ACCENTS[0], width=3)
    for k in range(1, 8):
        yy = hz + (road[1] + road[3] - hz) * (k / 7.0) ** 1.8
        d.line([sc(cx), sc(yy), sc(cx), sc(yy + 8)], fill=(150, 110, 255), width=2)
    for i in range(4):
        px = cx - 150 + i * 100
        py = road[1] + road[3] - 80 - i * 26
        w2 = 54 + i * 5
        fill(d, (px - w2 / 2, py - w2 * 0.7, w2, w2 * 0.7), (16, 6, 32))
        rect(d, (px - w2 / 2, py - w2 * 0.7, w2, w2 * 0.7), ACCENTS[i], 2)
        d.ellipse([sc(px - w2 / 2 + 6), sc(py - 16), sc(px - w2 / 2 + 22), sc(py)],
                  fill=ACCENTS[i])
        d.ellipse([sc(px + w2 / 2 - 22), sc(py - 16), sc(px + w2 / 2 - 6), sc(py)],
                  fill=ACCENTS[i])
        text(d, (px, py - w2 * 0.7 - 12), "%d" % (i + 1), C["T_TINY"], ACCENTS[i], anchor="ms")
    cam_panel(d, C["RAZOR_CAM"])
    board = C["RAZOR_BOARD"]
    panel(d, board, "гонка", LINE)
    pad = C["PAD"]
    top = board[1] + pad + C["T_TINY"] + 20
    for i in range(3):
        ry = top + i * 46
        fill(d, (board[0] + 10, ry - 12, board[2] - 20, 40), (i * 3, 2, 14))
        text(d, (board[0] + 18, ry), "%d" % (i + 1), C["T_SMALL"], ACCENTS[i])
        d.ellipse([sc(board[0] + 34), sc(ry + 2), sc(board[0] + 46), sc(ry + 14)], fill=ACCENTS[i])
        text(d, (board[0] + 54, ry), "ИГРОК %d" % (i + 1), C["T_SMALL"], TEXT)
        text(d, (board[0] + board[2] - 18, ry), "%d м" % (1200 - i * 90), C["T_TINY"], DIM,
             anchor="ra")
    hint_panel(d, C["RAZOR_HINT"], "face")
    text(d, (C["W"] - C["M"], C["FOOT_Y"] + 30), "наклон головы — руль · вперёд — газ · назад — тормоз",
         C["T_BODY"], DIM, anchor="ra")
    text(d, (C["W"] - C["M"], C["FOOT_Y"] + 66), "1..5 — режим ввода · ESC — меню", C["T_SMALL"], DIM,
         anchor="ra")
    return img


def screen_air():
    img = Image.new("RGB", (int(sc(C["W"])), int(sc(C["H"]))), BG)
    d = ImageDraw.Draw(img)
    grid(d)
    header(d, "АЭРОХОККЕЙ", "матч до 5 голов", "3 : 2", "игрок 1 · игрок 2")
    t = C["AIR_TABLE"]
    fill(d, t, (8, 0, 26))
    rect(d, t, LINE, 2)
    d.line([sc(t[0] + t[2] / 2), sc(t[1]), sc(t[0] + t[2] / 2), sc(t[1] + t[3])],
           fill=(90, 60, 170), width=2)
    d.ellipse([sc(t[0] + t[2] / 2 - 90), sc(t[1] + t[3] / 2 - 90),
               sc(t[0] + t[2] / 2 + 90), sc(t[1] + t[3] / 2 + 90)], outline=(90, 60, 170), width=2)
    gh = 120
    for side in (0, 1):
        gy = t[1] + t[3] / 2 - gh / 2
        gx = t[0] if side == 0 else t[0] + t[2] - 10
        fill(d, (gx, gy, 10, gh), ACCENTS[side])
    d.ellipse([sc(t[0] + 260), sc(t[1] + t[3] / 2 - 52), sc(t[0] + 364), sc(t[1] + t[3] / 2 + 52)],
              outline=ACCENTS[0], width=3)
    d.ellipse([sc(t[0] + t[2] - 364), sc(t[1] + t[3] / 2 - 52),
               sc(t[0] + t[2] - 260), sc(t[1] + t[3] / 2 + 52)], outline=ACCENTS[1], width=3)
    cam_panel(d, C["AIR_CAM"])
    hint_panel(d, C["AIR_HINT"], "face", stacked=True)
    st = C["AIR_STATUS"]
    panel(d, st, "состояние", LINE)
    pad = C["PAD"]
    ty = st[1] + pad + C["T_TINY"] + 20
    text(d, (st[0] + pad, ty), "режим: авто", C["T_TINY"], TEXT)
    text(d, (st[0] + pad, ty + 22), "ввод: лицо", C["T_TINY"], TEXT)
    text(d, (st[0] + pad, ty + 44), "данные 42 мс", C["T_TINY"], DIM)
    footer_line(d, C["FOOT_Y"] + 36, "лицо — курсор в своей половине · прыжок — толчок")
    footer_line(d, C["FOOT_Y"] + 72, "1..5 — режим ввода · ESC — меню")
    return img


def screen_jump():
    img = Image.new("RGB", (int(sc(C["W"])), int(sc(C["H"]))), BG)
    d = ImageDraw.Draw(img)
    grid(d)
    header(d, "НЕОН-ДЖАМП",
           "раунд 1:12 · упал — минус 250 очков и возврат через 2 с", "", "")
    sr = C["JUMP_SCORES"]
    for i in range(4):
        cw = (sr[2] - 3 * 20) / 4
        px = sr[0] + i * (cw + 20)
        fill(d, (px, sr[1], cw, sr[3]), (10, 4, 24))
        rect(d, (px, sr[1], cw, sr[3]), ACCENTS[i], 2)
        d.ellipse([sc(px + 16), sc(sr[1] + 28), sc(px + 34), sc(sr[1] + 46)], fill=ACCENTS[i])
        text(d, (px + 48, sr[1] + 22), "ИГРОК %d" % (i + 1), C["T_SMALL"], TEXT)
        text(d, (px + 48, sr[1] + 44), "очков: %d" % (1240 - i * 380), C["T_TINY"], DIM)
    a = C["JUMP_ARENA"]
    fill(d, a, (6, 0, 22))
    step = 80
    x = a[0]
    while x <= a[0] + a[2]:
        d.line([sc(x), sc(a[1]), sc(x), sc(a[1] + a[3])], fill=(36, 22, 80), width=1)
        x += step
    y = a[1] + 40
    while y <= a[1] + a[3]:
        d.line([sc(a[0]), sc(y), sc(a[0] + a[2]), sc(y)], fill=(36, 22, 80), width=1)
        y += step
    for i in range(9):
        px = a[0] + 60 + ((i * 431) % int(a[2] - 160))
        py = a[1] + a[3] - 60 - i * 66
        col = ACCENTS[2] if i % 3 == 2 else (ACCENTS[3] if i % 4 == 3 else ACCENTS[0])
        fill(d, (px, py, 118, 12), (16, 10, 40))
        rect(d, (px, py, 118, 12), col, 2)
    for i in range(3):
        px = a[0] + 300 + i * 300
        py = a[1] + 200 + i * 120
        d.ellipse([sc(px - 18), sc(py - 18), sc(px + 18), sc(py + 18)], outline=ACCENTS[i], width=3)
        d.ellipse([sc(px - 6), sc(py - 21), sc(px - 1), sc(py - 16)], fill=ACCENTS[i])
        d.ellipse([sc(px + 2), sc(py - 21), sc(px + 7), sc(py - 16)], fill=ACCENTS[i])
        text(d, (px, py + 40), "ИГРОК %d" % (i + 1), C["T_TINY"], DIM, anchor="ms")
    rect(d, a, LINE, 2)
    cam_panel(d, C["JUMP_CAM"])
    hint_panel(d, C["JUMP_HINT"], "face")
    st = C["JUMP_STATUS"]
    panel(d, st, "состояние", LINE)
    pad = C["PAD"]
    ty = st[1] + pad + C["T_TINY"] + 14
    for i, (k, v) in enumerate((("ввод", "лицо"), ("данные", "42 мс"),
                                ("падений", "3"), ("платформ", "57"))):
        text(d, (st[0] + pad, ty + i * 22), k, C["T_TINY"], DIM)
        text(d, (st[0] + pad + 108, ty + i * 22), v, C["T_TINY"], TEXT)
    footer_line(d, C["FOOT_Y"] + 36,
                "наклоняйте лицо — человечек бежит вбок · прыгает сам · упал — вернёшься с минусом")
    footer_line(d, C["FOOT_Y"] + 72, "1..5 — режим ввода · ESC — меню")
    return img


def main():
    global S
    ap = argparse.ArgumentParser()
    ap.add_argument("--scale", type=float, default=0.5)
    args = ap.parse_args()
    S = args.scale
    for name, fn in (("menu", screen_menu), ("tron", screen_tron),
                     ("razor", screen_razor), ("air", screen_air),
                     ("jump", screen_jump), ("tetris", screen_tetris),
                     ("saber", screen_saber)):
        path = os.path.join(HERE, "layout_%s.png" % name)
        fn().save(path)
        print("готово:", path)


if __name__ == "__main__":
    main()
