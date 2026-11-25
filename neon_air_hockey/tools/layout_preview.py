#!/usr/bin/env python3
"""Схема раскладки экранов аркады — картинки для проверки пропорций.

Читает константы из core/Layout.gd (единственный источник координат) и рисует
схемы меню, «Трона», «Разортрона» и аэрохоккея. Нужен, чтобы видеть сетку
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
           "1 / 2 / 3 / 4 — выбрать · Enter — начать")
    cards = ["АЭРОХОККЕЙ", "ТРОН", "РАЗОРТРОН 2000", "НЕОН-ДЖАМП"]
    whos = ["ровно 2 игрока", "1–4 игрока", "1–6 игроков", "1–4 игрока"]
    hints = ["ракетки в своих половинах", "световой след не прощает",
             "гонка в закат до финиша", "прыгай выше всех"]
    for i in range(4):
        r = (C["MENU_CARD"][0] + i * C["MENU_CARD_STEP"],) + C["MENU_CARD"][1:]
        col = ACCENTS[i]
        panel(d, r, "", col)
        cx = r[0] + r[2] / 2
        g = (r[0] + 32, r[1] + 36, r[2] - 64, 150)
        rect(d, g, (30, 16, 62), 1)
        if i == 0:
            d.line([sc(g[0] + g[2] / 2), sc(g[1]), sc(g[0] + g[2] / 2), sc(g[1] + g[3])], fill=(90, 60, 170), width=2)
            d.ellipse([sc(g[0] + 40), sc(g[1] + g[3] / 2 - 22), sc(g[0] + 84), sc(g[1] + g[3] / 2 + 22)], outline=col, width=2)
            d.ellipse([sc(g[0] + g[2] - 84), sc(g[1] + g[3] / 2 - 22), sc(g[0] + g[2] - 40), sc(g[1] + g[3] / 2 + 22)],
                      outline=ACCENTS[1], width=2)
        elif i == 1:
            for j, c2 in enumerate((ACCENTS[0], ACCENTS[1])):
                d.line([sc(g[0] + 30), sc(g[1] + 30 + j * 40), sc(g[0] + g[2] - 30), sc(g[1] + 30 + j * 40)], fill=c2, width=3)
        else:
            if i == 2:
                d.line([sc(g[0] + 20), sc(g[1] + g[3]), sc(cx), sc(g[1] + 16)], fill=ACCENTS[0], width=2)
                d.line([sc(g[0] + g[2] - 20), sc(g[1] + g[3]), sc(cx), sc(g[1] + 16)], fill=ACCENTS[1], width=2)
            else:
                for j, c2 in enumerate((ACCENTS[0], ACCENTS[2], ACCENTS[0])):
                    py = g[1] + g[3] - 24 - j * 46
                    d.line([sc(g[0] + 12 + (0 if j % 2 == 0 else 60)), sc(py),
                            sc(g[0] + 96 + (0 if j % 2 == 0 else 60)), sc(py)], fill=c2, width=3)
                ox, oy = g[0] + g[2] - 70, g[1] + 40
                d.ellipse([sc(ox - 16), sc(oy - 16), sc(ox + 16), sc(oy + 16)], outline=ACCENTS[1], width=2)
        text(d, (cx, r[1] + 236), cards[i], C["T_H2"], TEXT, anchor="ms")
        text(d, (cx, r[1] + 268), whos[i], C["T_SMALL"], col, anchor="ms")
        text(d, (cx, r[1] + 294), hints[i], C["T_SMALL"], DIM, anchor="ms")
        bot = r[1] + r[3]
        for j in range(i):
            d.ellipse([sc(r[0] + 32 + j * 22), sc(bot - 72), sc(r[0] + 48 + j * 22), sc(bot - 56)], fill=ACCENTS[j])
        text(d, (r[0] + 32, bot - 24), ("%d голос" % i) if i else "нет голосов", C["T_SMALL"], TEXT)
        bx, by = r[0] + r[2] - 24 - 44, bot - 24 - 44
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
    text(d, (C["MENU_CARD"][0] + C["MENU_CARD"][2] / 2, C["MENU_MSG_Y"]),
         "", C["T_H2"], DIM, anchor="ma")
    footer_line(d, C["FOOT_Y"] + 34, "отклоните лицо к плитке и задержите — это ваш голос")
    return img


def screen_tron():
    img = Image.new("RGB", (int(sc(C["W"])), int(sc(C["H"]))), BG)
    d = ImageDraw.Draw(img)
    grid(d)
    header(d, "ТРОН", "раунд 1 · до 3 побед", "", "")
    sr = C["TRON_SCORES"]
    for i in range(4):
        cw = (sr[2] - 3 * 20) / 4
        px = sr[0] + i * (cw + 20)
        fill(d, (px, sr[1], cw, sr[3]), (10, 4, 24))
        rect(d, (px, sr[1], cw, sr[3]), ACCENTS[i], 2)
        d.ellipse([sc(px + 16), sc(sr[1] + 28), sc(px + 34), sc(sr[1] + 46)], fill=ACCENTS[i])
        text(d, (px + 48, sr[1] + 22), "ИГРОК %d" % (i + 1), C["T_SMALL"], TEXT)
        text(d, (px + 48, sr[1] + 44), "побед: 0", C["T_TINY"], DIM)
    a = C["TRON_ARENA"]
    fill(d, a, (8, 0, 26))
    step = 20
    x = a[0]
    while x < a[0] + a[2]:
        d.line([sc(x), sc(a[1]), sc(x), sc(a[1] + a[3])], fill=(40, 24, 90), width=1)
        x += step
    y = a[1]
    while y < a[1] + a[3]:
        d.line([sc(a[0]), sc(y), sc(a[0] + a[2]), sc(y)], fill=(40, 24, 90), width=1)
        y += step
    rect(d, a, LINE, 2)
    cam_panel(d, C["TRON_CAM"])
    hint_panel(d, C["TRON_HINT"], "hand")
    st = C["TRON_STATUS"]
    panel(d, st, "состояние", LINE)
    pad = C["PAD"]
    text(d, (st[0] + pad, st[1] + pad + C["T_TINY"] + 20), "ввод: лицо · данные 42 мс", C["T_TINY"], TEXT)
    text(d, (st[0] + pad, st[1] + pad + C["T_TINY"] + 42), "1..5 — режим · ESC — меню", C["T_TINY"], DIM)
    footer_line(d, C["FOOT_Y"] + 36, "отклоните лицо в сторону — мотоцикл повернёт · в след нельзя")
    return img


def screen_razor():
    img = Image.new("RGB", (int(sc(C["W"])), int(sc(C["H"]))), BG)
    d = ImageDraw.Draw(img)
    grid(d)
    header(d, "РАЗОРТРОН 2000", "дистанция 1200 м · трафик тормозит", "до финиша 980 м", "128 км/ч")
    bar = C["RAZOR_BAR"]
    fill(d, bar, (40, 24, 70))
    fill(d, (bar[0], bar[1], bar[2] * 0.35, bar[3]), ACCENTS[0])
    for i in range(3):
        cx = bar[0] + bar[2] * (0.35 + i * 0.12)
        d.ellipse([sc(cx - 5), sc(bar[1] + 1), sc(cx + 5), sc(bar[1] + 9)], fill=ACCENTS[i])
    road = C["RAZOR_ROAD"]
    horizon = 470
    vpx = 960
    near_y = 892
    half_near = 677
    half_far = 40
    d.polygon([sc(vpx - half_far), sc(horizon), sc(vpx + half_far), sc(horizon),
               sc(vpx + half_near), sc(near_y), sc(vpx - half_near), sc(near_y)], fill=(14, 4, 30))
    # солнце
    d.ellipse([sc(vpx - 150), sc(horizon - 190), sc(vpx + 150), sc(horizon + 110)], outline=(255, 80, 190), width=2)
    for i in range(6):
        yy = horizon - 60 + i * 26
        d.line([sc(vpx - 120), sc(yy), sc(vpx + 120), sc(yy)], fill=BG, width=3)
    for side in (-1, 1):
        d.line([sc(vpx + side * half_far), sc(horizon), sc(vpx + side * half_near), sc(near_y)],
               fill=ACCENTS[0] if side > 0 else ACCENTS[1], width=2)
    for k in range(9):
        t = k / 8.0
        yy = horizon + (near_y - horizon) * (t ** 2)
        hw = half_far + (half_near - half_far) * (t ** 2)
        d.line([sc(vpx - hw), sc(yy), sc(vpx + hw), sc(yy)], fill=(50, 30, 100), width=1)
    # машины
    for i in range(3):
        t = 0.55 + i * 0.14
        yy = horizon + (near_y - horizon) * (t ** 2)
        hw = half_far + (half_near - half_far) * (t ** 2)
        for lane in (-0.5, 0.0, 0.5):
            cx = vpx + lane * hw
            w2 = 10 + 60 * (t ** 2)
            fill(d, (cx - w2 / 2, yy - w2 * 0.7, w2, w2 * 0.7), (16, 6, 32))
            rect(d, (cx - w2 / 2, yy - w2 * 0.7, w2, w2 * 0.7), ACCENTS[i], 2)
    cam_panel(d, C["RAZOR_CAM"])
    board = C["RAZOR_BOARD"]
    panel(d, board, "гонка", LINE)
    pad = C["PAD"]
    top = board[1] + pad + C["T_TINY"] + 20
    for i in range(6):
        ry = top + i * 46
        if i >= 3:
            break
        fill(d, (board[0] + 10, ry - 12, board[2] - 20, 40), (i * 3, 2, 14))
        text(d, (board[0] + 18, ry), "%d" % (i + 1), C["T_SMALL"], ACCENTS[i])
        d.ellipse([sc(board[0] + 34), sc(ry + 2), sc(board[0] + 46), sc(ry + 14)], fill=ACCENTS[i])
        text(d, (board[0] + 54, ry), "ИГРОК %d" % (i + 1), C["T_SMALL"], TEXT)
        text(d, (board[0] + board[2] - 18, ry), "%d м" % (1200 - i * 90), C["T_TINY"], DIM, anchor="ra")
    hint_panel(d, C["RAZOR_HINT"], "face")
    text(d, (C["W"] - C["M"], C["FOOT_Y"] + 30), "наклон головы — руль · вперёд — газ · назад — тормоз",
         C["T_BODY"], DIM, anchor="ra")
    text(d, (C["W"] - C["M"], C["FOOT_Y"] + 66), "1..5 — режим ввода · ESC — меню", C["T_SMALL"], DIM, anchor="rs")
    return img


def screen_air():
    img = Image.new("RGB", (int(sc(C["W"])), int(sc(C["H"]))), BG)
    d = ImageDraw.Draw(img)
    grid(d)
    header(d, "АЭРОХОККЕЙ", "матч до 5 голов", "3 : 2", "игрок 1 · игрок 2")
    t = C["AIR_TABLE"]
    fill(d, t, (8, 0, 26))
    rect(d, t, LINE, 2)
    d.line([sc(t[0] + t[2] / 2), sc(t[1]), sc(t[0] + t[2] / 2), sc(t[1] + t[3])], fill=(90, 60, 170), width=2)
    d.ellipse([sc(t[0] + t[2] / 2 - 90), sc(t[1] + t[3] / 2 - 90),
               sc(t[0] + t[2] / 2 + 90), sc(t[1] + t[3] / 2 + 90)], outline=(90, 60, 170), width=2)
    gh = 120
    for side in (0, 1):
        gy = t[1] + t[3] / 2 - gh / 2
        gx = t[0] if side == 0 else t[0] + t[2] - 10
        fill(d, (gx, gy, 10, gh), ACCENTS[side])
    d.ellipse([sc(t[0] + 260), sc(t[1] + t[3] / 2 - 52), sc(t[0] + 364), sc(t[1] + t[3] / 2 + 52)],
              outline=ACCENTS[0], width=3)
    d.ellipse([sc(t[0] + t[2] - 364), sc(t[1] + t[3] / 2 - 52), sc(t[0] + t[2] - 260), sc(t[1] + t[3] / 2 + 52)],
              outline=ACCENTS[1], width=3)
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
                     ("jump", screen_jump)):
        path = os.path.join(HERE, "layout_%s.png" % name)
        fn().save(path)
        print("готово:", path)


if __name__ == "__main__":
    main()
