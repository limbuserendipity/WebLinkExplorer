#!/usr/bin/env python3
"""Эмулятор системы трекинга Godot AR API v1 — два игрока для Neon Air Hockey.

Запустите скрипт, затем выполните напечатанную команду из корня проекта
neon_air_hockey/ (замените `godot` на путь к Godot 4.5.1 при необходимости).

Игроки двигают "головой" (верхней центральной точкой рамки) по синусоиде,
периодически подают жест jump. Сценарии для приёмочных проверок:

  --leave T    на T-й секунде правый игрок уходит из кадра на --gone-for секунд
               и возвращается с ТЕМ ЖЕ track_id (проверка паузы и возврата);
  --swap T     на T-й секунде у правого игрока меняется track_id при том же
               slot (новый человек — игра должна сбросить его состояние);
  --empty T    на T-й секунде список players пуст на --gone-for секунд;
  --stale T    на T-й секунде пакеты не отправляются --gone-for секунд
               (соединение живо, данные устаревают);
  --drop T     на T-й секунде соединение закрывается (игра должна завершиться);
  --lowconf    жесты с confidence 0.45 (ниже порога 0.75 из примера документа);
  --video      слать JPEG-кадры ~10 к/с (нужен Pillow; без него — предупреждение);
  --duration S завершиться через S секунд (0 = бесконечно).

Пример: python3 tools/mock_tracker.py --leave 12 --video
"""
import argparse
import json
import math
import socket
import struct
import sys
import time


def make_player(slot, track_id, cx, top, color, n):
    w, h = 0.16, 0.55
    return {
        "slot": slot, "track_id": track_id, "age_ticks": 0,
        "color": color, "rect": [cx - w / 2, top, w, h],
        "feet": [[cx - 0.05, top + h - 0.02], [cx + 0.05, top + h - 0.02]],
        "feet_confidence": 0.92, "mask_slot": 0, "sample_id": n,
    }


def render_jpeg(players, pil):
    Image, ImageDraw = pil
    img = Image.new("RGB", (320, 180), (8, 4, 24))
    d = ImageDraw.Draw(img)
    for p in players:
        x, y, w, h = p["rect"]
        box = [x * 320, y * 180, (x + w) * 320, (y + h) * 180]
        c = tuple(int(v * 255) for v in p["color"])
        d.rectangle(box, outline=c, width=2)
        d.ellipse([box[0] + w * 160 - 4, box[1] - 4, box[0] + w * 160 + 4, box[1] + 4], fill=c)
    import io
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=70)
    return buf.getvalue()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--rate", type=float, default=30.0)
    ap.add_argument("--duration", type=float, default=0.0)
    ap.add_argument("--gone-for", type=float, default=3.0)
    ap.add_argument("--leave", type=float, default=None)
    ap.add_argument("--swap", type=float, default=None)
    ap.add_argument("--empty", type=float, default=None)
    ap.add_argument("--stale", type=float, default=None)
    ap.add_argument("--drop", type=float, default=None)
    ap.add_argument("--lowconf", action="store_true")
    ap.add_argument("--video", action="store_true")
    args = ap.parse_args()

    pil = None
    if args.video:
        try:
            from PIL import Image, ImageDraw
            pil = (Image, ImageDraw)
        except ImportError:
            print("mock: Pillow не найден, видео отправляться не будет (pip install pillow)", flush=True)

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.port))
    server.listen(1)
    port = server.getsockname()[1]
    print(f"godot --path . -- --port={port}", flush=True)
    print(f"mock: жду игру на 127.0.0.1:{port} (rate={args.rate:g}/s)", flush=True)
    connection, _ = server.accept()
    print("mock: игра подключилась", flush=True)

    n = 0
    event_id = 0
    t0 = time.monotonic()
    last_jump = [0, 0]
    swapped = False
    dropped = False
    try:
        with connection:
            while True:
                t = time.monotonic() - t0
                if args.duration and t >= args.duration:
                    print("mock: время вышло, закрываю соединение", flush=True)
                    break
                if args.drop is not None and t >= args.drop:
                    print(f"mock: [{t:5.1f}s] обрыв соединения (--drop)", flush=True)
                    break
                if args.stale is not None and args.stale <= t < args.stale + args.gone_for:
                    if not dropped:
                        print(f"mock: [{t:5.1f}s] пауза потока (--stale)", flush=True)
                        dropped = True
                    time.sleep(1 / args.rate)
                    continue
                dropped = False

                track_right = 77
                if args.swap is not None and t >= args.swap:
                    track_right = 177
                    if not swapped:
                        print(f"mock: [{t:5.1f}s] правый slot 1 получает новый track_id 177 (--swap)", flush=True)
                        swapped = True

                players = []
                if not (args.empty is not None and args.empty <= t < args.empty + args.gone_for):
                    cx0 = 0.28 + 0.07 * math.sin(2 * math.pi * t / 4.0)
                    top0 = 0.18 + 0.05 * math.sin(2 * math.pi * t / 5.3)
                    players.append(make_player(0, 42, cx0, top0, [0.1, 0.8, 1.0], n))
                    if not (args.leave is not None and args.leave <= t < args.leave + args.gone_for):
                        cx1 = 0.72 + 0.07 * math.sin(2 * math.pi * t / 4.6 + 1.7)
                        top1 = 0.18 + 0.05 * math.sin(2 * math.pi * t / 6.1 + 0.9)
                        players.append(make_player(1, track_right, cx1, top1, [1.0, 0.25, 0.9], n))
                    elif args.leave is not None and not getattr(main, "_leave_logged", False):
                        print(f"mock: [{t:5.1f}s] правый игрок ушёл (--leave), вернётся через {args.gone_for:g} с", flush=True)
                        main._leave_logged = True

                gestures = []
                conf = 0.45 if args.lowconf else 0.95
                for i, p in enumerate(players):
                    period = 2.4 if i == 0 else 3.1
                    k = int((t + (0.0 if i == 0 else 1.1)) / period)
                    if k > last_jump[i]:
                        last_jump[i] = k
                        event_id += 1
                        gestures.append({"id": event_id, "slot": p["slot"], "track_id": p["track_id"],
                                         "action": "jump", "confidence": conf})

                images = b""
                frame_age = None
                if pil and n % 3 == 0:
                    images = render_jpeg(players, pil)
                    frame_age = 0.0

                packet = {"frame_id": n, "tracking_age": 0.0, "frame_age": frame_age,
                          "players": players, "gestures": gestures}
                body = json.dumps(packet).encode("utf-8")
                connection.sendall(struct.pack("!II", len(body), len(images)) + body + images)
                n += 1
                time.sleep(1 / args.rate)
    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
        print("mock: игра закрыла соединение", flush=True)
    finally:
        server.close()
    print("mock: завершён", flush=True)


if __name__ == "__main__":
    main()
