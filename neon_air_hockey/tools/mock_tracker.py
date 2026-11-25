#!/usr/bin/env python3
"""Эмулятор системы трекинга Godot AR API v2 — два игрока для Neon Air Hockey.

Запустите скрипт, затем выполните напечатанную команду из корня проекта
neon_air_hockey/ (замените `godot` на путь к Godot 4.5.1 при необходимости).

Игроки стоят на месте, а корпусом покачиваются влево-вправо (это единственная
ось управления), плюс периодически «прыгают» — жест приходит фазами
start / hold / end. body_height слегка меняется, имитируя шаг к камере.

Сценарии для приёмочных проверок:

  --leave T     правый игрок уходит из кадра на --gone-for секунд и возвращается
                с тем же track_id, затем помечается `reacquired`;
  --swap T      у правого игрока меняется track_id при том же slot (новый человек);
  --empty T     на --gone-for секунд список players пуст;
  --stale T     на --gone-for секунд пакеты не отправляются (данные устаревают);
  --drop T      на T-й секунде соединение закрывается (игра должна завершиться);
  --lost T      на --gone-for секунд игрок приходит со state="lost", но свежими
                измерениями (игра должна поставить паузу сразу);
  --reacquire T на --gone-for секунд игрок помечается state="lost", затем на
                0,3 с приходит с reacquired=true (возврат того же трека);
  --reacq-flag T на 0,3 с приходит reacquired=true при state="confirmed"
                (трекер сам сообщает о возврате, потеря не фиксировалась);
  --lose-head T на --gone-for секунд точка головы пропадает (head пустой,
                body_height = 0) — проверка фолбэка и «слепого» режима;
  --legacy      слать пакеты в стиле API v1: без head/body_height/frame_size/
                capabilities/tentative (проверка совместимости);
  --lowconf     жесты с confidence 0.45 — ниже порога игры 0.75;
  --video       слать JPEG-кадры ~10 к/с (нужен Pillow);
  --hold S      длительность удержания жеста (по умолчанию 0.6 с);
  --jump-every S период прыжков одного игрока (по умолчанию 3 с);
  --replay FILE проиграть трассу, записанную игрой (--record=FILE), вместо
                синтетических игроков; --speed N ускоряет/замедляет её;
  --still       не двигать лицо и силуэт (для замеров задержки);
  --step T --step-x PX  на T секунд нос резко уходит на PX пикселей вправо;
  --duration S  завершиться через S секунд (0 = бесконечно);
  --fps N       частота пакетов (по умолчанию 30).

Примеры: python3 tools/mock_tracker.py --leave 12 --video
         python3 tools/mock_tracker.py --lost 6 --gone-for 2
         python3 tools/mock_tracker.py --legacy
"""
import argparse
import json
import math
import socket
import struct
import sys
import time

FRAME_W, FRAME_H = 640, 360
FEET_Y = 0.75
BODY = 0.53


def walk_scale(t):
    """Рост в кадре: 5-7 с отошёл до 0.72, 7-12 далеко, 12-15 вернулся."""
    if 5.0 <= t < 7.0:
        return 1.0 - 0.28 * (t - 5.0) / 2.0
    if 7.0 <= t < 12.0:
        return 0.72
    if 12.0 <= t < 15.0:
        return 0.72 + 0.28 * (t - 12.0) / 3.0
    return 1.0


COLORS = [(0.1, 0.8, 1.0), (1.0, 0.25, 0.9), (0.45, 1.0, 0.35),
          (1.0, 0.78, 0.2), (0.66, 0.42, 1.0), (1.0, 0.45, 0.3)]


def slot_x(slot, count):
    """Расставляет игроков по кадру: 2 — по краям, 6 — в ряд."""
    if count <= 1:
        return 0.5
    return 0.06 + 0.88 * slot / float(count - 1)


def track_of(slot, last_right):
    if slot == 0:
        return 42
    if slot == 1:
        return last_right
    return 42 + slot * 10


def make_player(args, slot, track_id, cx, t, n, color):
    """Один игрок: голова качается влево-вправо, ноги стоят."""
    if args.far:
        scale = 0.45                   # игрок далеко: рамка ~0.28 высоты кадра
    elif args.walk:
        scale = walk_scale(t)          # игрок отходит и возвращается
    elif args.still:
        scale = 1.0
    else:
        scale = 1.0 + 0.05 * math.sin(2 * math.pi * t / 7.0 + slot)
    body = BODY * scale
    head_y = FEET_Y - body
    sway = 0.0 if args.still else 0.09 * math.sin(2 * math.pi * t / (4.0 + 0.6 * slot) + slot * 1.7)
    if args.legacy:
        cx += sway          # без позы двигаем весь силуэт: рамка и есть вход
    head_x = cx + sway
    # лицо: наклон головы набок (roll) и поворот (yaw), чтобы работал режим tilt
    roll = 0.0 if args.still else 0.18 * math.sin(2 * math.pi * t / (3.3 + 0.4 * slot) + slot)
    yaw = 0.0 if args.still else 0.35 * math.sin(2 * math.pi * t / (4.6 + 0.5 * slot) + slot * 2.1)
    eye_d = 0.035
    axis = (math.cos(roll), math.sin(roll))
    perp = (-math.sin(roll), math.cos(roll))
    nose_x = head_x + axis[0] * yaw * eye_d
    nod = 0.0 if args.still else 0.06 * math.sin(2 * math.pi * t / (5.2 + 0.3 * slot) + slot * 1.3)
    nose_y = head_y + axis[1] * yaw * eye_d + perp[1] * eye_d * 0.22 + nod
    if args.step is not None and t >= args.step:
        nose_x += args.step_x / FRAME_W      # резкий скачок носа для замера задержки
        nose_y += args.step_y / FRAME_H
    eye_l = [round(head_x - axis[0] * eye_d / 2, 4), round(head_y - axis[1] * eye_d / 2, 4), 0.9]
    eye_r = [round(head_x + axis[0] * eye_d / 2, 4), round(head_y + axis[1] * eye_d / 2, 4), 0.9]
    feet = [[cx - 0.05, FEET_Y], [cx + 0.05, FEET_Y]]
    top = head_y - 0.04
    height = FEET_Y - top
    row = {
        "slot": slot, "track_id": track_id, "age_ticks": 0, "color": color,
        "rect": [round(cx - 0.10, 4), round(top, 4), 0.20, round(height, 4)],
        "feet": feet, "feet_confidence": 0.93, "mask_slot": 0, "sample_id": n,
    }
    if args.legacy:
        return row
    head = {"p": [round(nose_x, 4), round(nose_y, 4)], "conf": 0.96}
    if args.lose_head is not None and args.lose_head <= t < args.lose_head + args.gone_for:
        head = {}
        body = 0.0
    shoulders = [[round(head_x - 0.075, 4), round(head_y + 0.10, 4), 0.95],
                 [round(head_x + 0.075, 4), round(head_y + 0.10, 4), 0.94]]
    hips = [[round(cx - 0.06, 4), round(FEET_Y - body * 0.45, 4), 0.9],
            [round(cx + 0.06, 4), round(FEET_Y - body * 0.45, 4), 0.9]]
    wx = 0.0
    wy = 0.0
    if args.wave:
        # машем руками: то одна, то другая уходит в сторону — проверка ввода рукой
        wx = 0.09 * math.sin(2 * math.pi * t / 2.6 + slot)
        wy = 0.08 * math.sin(2 * math.pi * t / 3.4 + slot + 1.1)
    wrists = [[round(head_x - 0.11 - wx, 4), round(head_y + 0.16 - wy, 4), 0.8],
              [round(head_x + 0.11 + wx, 4), round(head_y + 0.16 - wy, 4), 0.8]]
    ankles = [[feet[0][0], feet[0][1], 0.91], [feet[1][0], feet[1][1], 0.91]]
    keypoints = [
        [round(nose_x, 4), round(nose_y, 4), 0.97],                  # нос
        eye_l,                                                      # глаз Л
        eye_r,                                                      # глаз П
        [round(head_x - axis[0] * 0.045, 4), round(head_y - axis[1] * 0.045, 4), 0.7],
        [round(head_x + axis[0] * 0.045, 4), round(head_y + axis[1] * 0.045, 4), 0.7],
        shoulders[0], shoulders[1],
        [round(head_x - 0.10, 4), round(head_y + 0.20, 4), 0.8],    # локоть Л
        [round(head_x + 0.10, 4), round(head_y + 0.20, 4), 0.8],    # локоть П
        wrists[0], wrists[1],
        hips[0], hips[1],
        [round(cx - 0.06, 4), round(FEET_Y - body * 0.22, 4), 0.85],  # колено Л
        [round(cx + 0.06, 4), round(FEET_Y - body * 0.22, 4), 0.85],  # колено П
        ankles[0], ankles[1],
    ]
    if slot == 1:
        keypoints[3] = None    # проверяем, что null в позе не ломает игру
    row.update({
        "head": head, "body_height": round(body, 4),
        "shoulders": shoulders, "hips": hips, "wrists": wrists, "ankles": ankles,
        "keypoints": keypoints, "state": "confirmed", "lost_since": -1.0,
        "reacquired": False, "reacquired_sample_id": -1,
    })
    return row


def render_jpeg(players, pil):
    Image, ImageDraw = pil
    img = Image.new("RGB", (320, 180), (8, 4, 24))
    d = ImageDraw.Draw(img)
    for p in players:
        x, y, w, h = p["rect"]
        box = [x * 320, y * 180, (x + w) * 320, (y + h) * 180]
        c = tuple(int(v * 255) for v in p["color"])
        d.rectangle(box, outline=c, width=2)
        head = p.get("head", {})
        if head:
            hx, hy = head["p"]
            d.ellipse([hx * 320 - 4, hy * 180 - 4, hx * 320 + 4, hy * 180 + 4], fill=c)
    import io
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=70)
    return buf.getvalue()


def replay_trace(connection, args):
    """Проигрывает трассу записи: те же данные, те же интервалы."""
    records = []
    with open(args.replay, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    print(f"mock v2: реплей {len(records)} кадров из {args.replay}", flush=True)
    n = 0
    event_id = 0
    t_prev = 0.0
    try:
        for rec in records:
            wait = (float(rec.get("t", 0.0)) - t_prev) / max(args.speed, 0.05)
            if wait > 0:
                time.sleep(min(wait, 0.25))
            t_prev = float(rec.get("t", 0.0))
            rows = []
            for row in rec.get("players", []):
                head = row.get("head") or []
                rows.append({
                    "slot": int(row["slot"]), "track_id": int(row["track_id"]),
                    "age_ticks": 0, "color": row.get("color", [0.5, 0.5, 1.0]),
                    "rect": row.get("rect", [0.0, 0.0, 0.0, 0.0]),
                    "feet": row.get("feet", []),
                    "feet_confidence": float(row.get("feet_confidence", 0.0)),
                    "mask_slot": 0, "sample_id": n,
                    "head": {"p": [head[0], head[1]], "conf": head[2]} if len(head) == 3 else {},
                    "body_height": float(row.get("body_height", 0.0)),
                    "keypoints": row.get("keypoints", []),
                    "state": row.get("state", "confirmed"), "lost_since": -1.0,
                    "reacquired": False, "reacquired_sample_id": -1,
                })
            gestures, phases = [], []
            for ev in rec.get("events", []):
                event_id += 1
                item = {"id": event_id, "slot": int(ev.get("slot", 0)),
                        "track_id": int(ev.get("track_id", -1)),
                        "action": str(ev.get("action", "jump")),
                        "phase": str(ev.get("phase", "start")),
                        "confidence": float(ev.get("confidence", 0.0)),
                        "at": round(t_prev, 3), "duration": 0.0}
                if item["phase"] == "start":
                    gestures.append(item)
                else:
                    phases.append(item)
            packet = {"frame_id": n, "tracking_age": 0.02, "frame_age": None,
                      "capabilities": ["pose", "track_state", "gesture_phases"],
                      "frame_size": [FRAME_W, FRAME_H],
                      "capture_time": round(t_prev, 3), "tracking_time": round(t_prev + 0.02, 3),
                      "players": rows, "tentative_players": [],
                      "gestures": gestures, "gesture_phases": phases}
            body = json.dumps(packet).encode("utf-8")
            connection.sendall(struct.pack("!II", len(body), 0) + body)
            n += 1
            if args.duration and t_prev >= args.duration:
                break
    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
        print("mock v2: игра закрыла соединение", flush=True)
    print("mock v2: реплей завершён, кадров:", n, flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("--duration", type=float, default=0.0)
    ap.add_argument("--gone-for", type=float, default=3.0)
    ap.add_argument("--leave", type=float, default=None)
    ap.add_argument("--swap", type=float, default=None)
    ap.add_argument("--empty", type=float, default=None)
    ap.add_argument("--stale", type=float, default=None)
    ap.add_argument("--drop", type=float, default=None)
    ap.add_argument("--lost", type=float, default=None)
    ap.add_argument("--reacquire", type=float, default=None)
    ap.add_argument("--reacq-flag", type=float, default=None)
    ap.add_argument("--lose-head", type=float, default=None)
    ap.add_argument("--legacy", action="store_true")
    ap.add_argument("--lowconf", action="store_true")
    ap.add_argument("--video", action="store_true")
    ap.add_argument("--hold", type=float, default=0.6)
    ap.add_argument("--jump-every", type=float, default=3.0)
    ap.add_argument("--replay", default="")
    ap.add_argument("--still", action="store_true")
    ap.add_argument("--count", type=int, default=2, help="сколько игроков в кадре (1..6)")
    ap.add_argument("--far", action="store_true", help="игрок далеко: рамка ~0.28 кадра")
    ap.add_argument("--wave", action="store_true", help="игрок машет руками (ввод рукой)")
    ap.add_argument("--walk", action="store_true",
                    help="игрок отходит от камеры на 5-7 с и возвращается на 12-15 с")
    ap.add_argument("--step", type=float, default=None)
    ap.add_argument("--step-x", type=float, default=40.0)
    ap.add_argument("--step-y", type=float, default=0.0)
    ap.add_argument("--speed", type=float, default=1.0)
    args = ap.parse_args()

    pil = None
    if args.video:
        try:
            from PIL import Image, ImageDraw
            pil = (Image, ImageDraw)
        except ImportError:
            print("mock: Pillow не найден, видео отправляться не будет", flush=True)

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.port))
    server.listen(1)
    port = server.getsockname()[1]
    print(f"godot --path . -- --port={port}", flush=True)
    print(f"mock v2: жду игру на 127.0.0.1:{port} (fps={args.fps:g})", flush=True)
    connection, _ = server.accept()
    print("mock v2: игра подключилась", flush=True)
    if args.replay:
        replay_trace(connection, args)
        server.close()
        return

    n = 0
    event_id = 0
    t0 = time.monotonic()
    last_right = 77
    swapped = False
    leave_logged = False
    stale_logged = False
    jumps = {i: {"next": 1.0 + 0.3 * i, "active": False, "t0": 0.0, "last_hold": 0.0}
             for i in range(args.count)}
    reacquire_until = -1.0
    reacquire_logged = False
    reacquire_done = False
    reacq_flag_logged = False
    try:
        with connection:
            while True:
                t = time.monotonic() - t0
                if args.duration and t >= args.duration:
                    print("mock v2: время вышло", flush=True)
                    break
                if args.drop is not None and t >= args.drop:
                    print(f"mock v2: [{t:5.1f}s] обрыв соединения (--drop)", flush=True)
                    break
                if args.stale is not None and args.stale <= t < args.stale + args.gone_for:
                    if not stale_logged:
                        print(f"mock v2: [{t:5.1f}s] пауза потока (--stale)", flush=True)
                        stale_logged = True
                    time.sleep(1 / args.fps)
                    continue
                stale_logged = False

                if args.swap is not None and t >= args.swap:
                    last_right = 177
                    if not swapped:
                        print(f"mock v2: [{t:5.1f}s] правый slot 1 получает track_id 177", flush=True)
                        swapped = True

                right_gone = args.leave is not None and args.leave <= t < args.leave + args.gone_for
                if right_gone and not leave_logged:
                    print(f"mock v2: [{t:5.1f}s] правый игрок ушёл, вернётся через "
                          f"{args.gone_for:g} с", flush=True)
                    leave_logged = True
                if args.leave is not None and t >= args.leave + args.gone_for and leave_logged:
                    reacquire_until = t + 0.3
                    leave_logged = False

                players = []
                tentatives = []
                empty_now = args.empty is not None and args.empty <= t < args.empty + args.gone_for
                if not empty_now:
                    for slot in range(args.count):
                        if slot == 1 and right_gone:
                            if not args.legacy:
                                tentatives.append({"track_id": last_right,
                                                   "state": "tentative", "sample_id": n,
                                                   "rect": [0.62, 0.20, 0.18, 0.55]})
                            continue
                        players.append(make_player(args, slot, track_of(slot, last_right),
                                                   slot_x(slot, args.count), t, n,
                                                   COLORS[slot % len(COLORS)]))
                # состояние и возврат
                if args.lost is not None and args.lost <= t < args.lost + args.gone_for:
                    for row in players:
                        row["state"] = "lost"
                        row["lost_since"] = round(t - args.lost, 3)
                if args.reacquire is not None:
                    if args.reacquire <= t < args.reacquire + args.gone_for:
                        for row in players:
                            row["state"] = "lost"
                            row["lost_since"] = round(t - args.reacquire, 3)
                        if not reacquire_logged:
                            print(f"mock v2: [{t:5.1f}s] трек потерян (--reacquire)", flush=True)
                            reacquire_logged = True
                    elif t >= args.reacquire + args.gone_for and t < args.reacquire + args.gone_for + 0.3:
                        reacquire_until = t + 0.05
                        if not reacquire_done:
                            print(f"mock v2: [{t:5.1f}s] трек вернулся (reacquired=true)", flush=True)
                            reacquire_done = True
                for row in players:
                    if row.get("track_id") == last_right and t < reacquire_until:
                        row["reacquired"] = True
                        row["reacquired_sample_id"] = n
                if args.reacq_flag is not None and args.reacq_flag <= t < args.reacq_flag + 0.3:
                    for row in players:
                        row["reacquired"] = True
                        row["reacquired_sample_id"] = n
                    if not reacq_flag_logged:
                        print(f"mock v2: [{t:5.1f}s] reacquired=true при confirmed (--reacq-flag)",
                              flush=True)
                        reacq_flag_logged = True

                # жесты фазами
                gestures, phases = [], []
                conf = 0.45 if args.lowconf else 0.95
                for row in players:
                    js = jumps[row["slot"]]
                    if js["active"]:
                        if t - js["t0"] <= args.hold:
                            if t - js["last_hold"] >= 0.09:
                                js["last_hold"] = t
                                event_id += 1
                                phases.append({"id": event_id, "slot": row["slot"],
                                               "track_id": row["track_id"], "action": "jump",
                                               "phase": "hold", "confidence": conf,
                                               "at": round(t, 3), "duration": round(t - js["t0"], 3)})
                        else:
                            js["active"] = False
                            event_id += 1
                            phases.append({"id": event_id, "slot": row["slot"],
                                           "track_id": row["track_id"], "action": "jump",
                                           "phase": "end", "confidence": conf,
                                           "at": round(t, 3), "duration": round(t - js["t0"] + 0.05, 3)})
                    elif t >= js["next"]:
                        js["next"] = t + args.jump_every
                        js["active"] = True
                        js["t0"] = t
                        js["last_hold"] = t
                        event_id += 1
                        ev = {"id": event_id, "slot": row["slot"], "track_id": row["track_id"],
                              "action": "jump", "confidence": conf, "at": round(t, 3),
                              "duration": 0.0}
                        if not args.legacy:
                            ev["phase"] = "start"
                        gestures.append(ev)

                images = b""
                frame_age = None
                if pil and n % 3 == 0:
                    images = render_jpeg(players, pil)
                    frame_age = 0.0

                packet = {"frame_id": n, "tracking_age": 0.02 + 0.001 * (n % 5),
                          "frame_age": frame_age, "players": players, "gestures": gestures}
                if not args.legacy:
                    packet.update({
                        "capabilities": ["pose", "track_state", "gesture_phases"]
                                        + (["video"] if pil else []),
                        "frame_size": [FRAME_W, FRAME_H],
                        "capture_time": round(t, 3), "tracking_time": round(t + 0.02, 3),
                        "tentative_players": tentatives,
                        "gesture_phases": phases,
                    })
                body = json.dumps(packet).encode("utf-8")
                connection.sendall(struct.pack("!II", len(body), len(images)) + body + images)
                n += 1
                time.sleep(1 / args.fps)
    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
        print("mock v2: игра закрыла соединение", flush=True)
    finally:
        server.close()
    print("mock v2: завершён, пакетов:", n, flush=True)


if __name__ == "__main__":
    main()
