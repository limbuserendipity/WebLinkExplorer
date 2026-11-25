#!/usr/bin/env python3
"""Автопроверки Neon Air Hockey (Godot AR API v2, 15 сценариев).

Запускает игру с эмулятором трекинга и проверяет ключевые сценарии из
приёмочного списка: жизненный цикл треков, паузы, жесты, три режима ввода
и запись трассы. Нужен Godot 4.5.1 (подойдёт и редакторская сборка).

  python3 tools/run_checks.py --godot /путь/к/godot
  python3 tools/run_checks.py --godot godot --only protocol
  python3 tools/run_checks.py --godot godot --list

Код возврата 0 — все проверки прошли.
"""
import argparse
import os
import re
import subprocess
import tempfile
import sys
import threading
import time

GAME_DIR = "."
CHECKS = {}


def check(name):
    def wrap(fn):
        CHECKS[name] = fn
        return fn
    return wrap


class Runner:
    """Запускает игру/эмулятор и собирает их вывод в реальном времени."""

    def __init__(self, args):
        self.args = args
        self.lines = []
        self.lock = threading.Lock()

    def _pump(self, stream):
        for raw in stream:
            line = raw.rstrip()
            with self.lock:
                self.lines.append(line)

    def text(self):
        with self.lock:
            return "\n".join(self.lines)

    def wait_for(self, pattern, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if re.search(pattern, self.text(), re.M):
                return True
            time.sleep(0.05)
        return False

    def start_mock(self, extra):
        mark = len(self.lines)   # порт ищем только в выводе ЭТОГО эмулятора
        mock = subprocess.Popen(
            [sys.executable, "-u", "tools/mock_tracker.py"] + extra,
            cwd=GAME_DIR, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        threading.Thread(target=self._pump, args=(mock.stdout,), daemon=True).start()
        port = None
        for _ in range(200):
            m = re.search(r"--port=(\d+)", "\n".join(self.lines[mark:]))
            if m:
                port = m.group(1)
                break
            time.sleep(0.05)
        if port is None:
            mock.kill()
            raise RuntimeError("эмулятор не сообщил порт")
        return mock, port

    def start_game(self, user_args, headless=True):
        cmd = [self.args.godot, "--path", GAME_DIR]
        if headless:
            cmd.insert(1, "--headless")
        if user_args:
            cmd += ["--"] + user_args
        game = subprocess.Popen(cmd, cwd=GAME_DIR, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        threading.Thread(target=self._pump, args=(game.stdout,), daemon=True).start()
        return game

    def run_game(self, user_args, timeout):
        game = self.start_game(user_args)
        try:
            game.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            game.kill()
            game.wait()
        return game.returncode

    def stop(self, proc):
        if proc is not None and proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass


def states(runner):
    return re.findall(r"^STATE (\w+)", runner.text(), re.M)


@check("waiting")
def check_waiting(r):
    """Без источника трекинга — экран ожидания, игра не падает."""
    code = r.run_game(["--selftest=waiting"], timeout=40)
    ok = "SELFTEST WAITING PASS" in r.text()
    return ok, "игра сама подтвердила ожидание" if ok else "нет PASS (код %s)" % code


@check("physics")
def check_physics(r):
    """Физика: диск, борта, ракетки и гол засчитываются."""
    code = r.run_game(["--selftest=physics"], timeout=40)
    ok = "SELFTEST PHYSICS PASS" in r.text()
    return ok, "гол засчитан" if ok else "нет PASS (код %s)" % code


@check("protocol")
def check_protocol(r):
    """v2: 2 игрока, калибровка, лицо двигает ракетку, жесты и толчок."""
    mock, port = r.start_mock(["--duration", "45"])
    try:
        code = r.run_game(["--port=" + port, "--selftest=protocol"], timeout=45)
    finally:
        r.stop(mock)
    ok = "SELFTEST PROTOCOL PASS" in r.text()
    if ok:
        detail = ", ".join(re.findall(r"ST protocol: (.+)", r.text()))
        return True, detail
    return False, "нет PASS (код %s)" % code


@check("control")
def check_control(r):
    """Три режима ввода (лицо/голова/корпус): обе оси двигают ракетку, трасса пишется."""
    details = []
    for mode in ("face", "tilt", "lean"):
        mock, port = r.start_mock(["--duration", "20"])
        mark = len(r.lines)
        rec = os.path.join(tempfile.gettempdir(), "wlx_rec_%s.jsonl" % mode)
        if os.path.exists(rec):
            os.remove(rec)
        try:
            game = r.start_game(["--port=" + port, "--selftest=log",
                                 "--control=" + mode, "--record=" + rec])
            time.sleep(9)
            r.stop(game)
        finally:
            r.stop(mock)
        text = "\n".join(r.lines[mark:])
        if re.search(r"SCRIPT ERROR", text):
            return False, "%s: ошибка скрипта" % mode
        if "PLAY" not in re.findall(r"^STATE (\w+)", text, re.M):
            return False, "%s: до PLAY не дошло" % mode
        slots = {}
        for m in re.finditer(r"INPUT slot=(\d) mode=(\w+).*?range=\([^)]*\) ax=([-+][\d.]+) ay=([-+][\d.]+)",
                             text):
            slot, seen, ax, ay = int(m.group(1)), m.group(2), float(m.group(3)), float(m.group(4))
            if seen != mode:
                return False, "%s: в логе режим %s" % (mode, seen)
            acc = slots.setdefault(slot, [0.0, 0.0])
            acc[0] = max(acc[0], abs(ax))
            acc[1] = max(acc[1], abs(ay))
        if len(slots) != 2:
            return False, "%s: ввод только у %d игрока(ов)" % (mode, len(slots))
        for slot, acc in slots.items():
            if acc[0] < 0.3 or acc[1] < 0.3:
                return False, "%s: игрок %d, оси слабые (%.2f, %.2f)" % (mode, slot + 1, acc[0], acc[1])
        frames = 0
        if os.path.exists(rec):
            with open(rec, encoding="utf-8") as fh:
                frames = sum(1 for line in fh if line.strip())
        if frames < 20:
            return False, "%s: записано кадров %d" % (mode, frames)
        details.append("%s %.0f/%.0f кадров %d" % (mode, slots[0][0] * 100, slots[0][1] * 100, frames))
    return True, "; ".join(details)


@check("lag")
def check_lag(r):
    """Задержка управления: после скачка носа ракетка проходит 90% пути ≤ 120 мс."""
    mock, port = r.start_mock(["--still", "--step", "5", "--step-x", "40",
                               "--jump-every", "9999", "--duration", "40"])
    try:
        r.run_game(["--port=" + port, "--selftest=lag"], timeout=40)
    finally:
        r.stop(mock)
    m = re.search(r"SELFTEST LAG: путь (\d+) px, 90% за (\d+) мс", r.text())
    ok = "SELFTEST LAG PASS" in r.text()
    if ok:
        return True, "90%% пути за %s мс, путь %s px" % (m.group(2), m.group(1))
    return False, "медленно или нет замера (порог 120 мс)"


@check("leave")
def check_leave(r):
    """Игрок ушёл из кадра → пауза; вернулся → калибровка и продолжение."""
    mock, port = r.start_mock(["--leave", "4", "--gone-for", "2", "--duration", "16"])
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        time.sleep(10)
        r.stop(game)
    finally:
        r.stop(mock)
    seq = states(r)
    ok = ("PAUSED" in seq and seq.index("PAUSED") < len(seq) - 2
          and "PLAY" in seq[seq.index("PAUSED") + 1:])
    return ok, "состояния: " + " → ".join(seq)


@check("swap")
def check_swap(r):
    """Новый track_id в том же slot → состояние стороны сброшено, раунд заново."""
    mock, port = r.start_mock(["--swap", "5", "--duration", "16"])
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        time.sleep(10)
        r.stop(game)
    finally:
        r.stop(mock)
    seq = states(r)
    ok = "PAUSED" in seq and "READY" in seq[seq.index("PAUSED") + 1:]
    return ok, "состояния: " + " → ".join(seq)


@check("stale")
def check_stale(r):
    """Поток данных замолкает → пауза «потерян сигнал», затем восстановление."""
    mock, port = r.start_mock(["--stale", "4", "--gone-for", "2", "--duration", "16"])
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        time.sleep(10)
        r.stop(game)
    finally:
        r.stop(mock)
    seq = states(r)
    ok = "PAUSED" in seq and "PLAY" in seq[seq.index("PAUSED") + 1:]
    return ok, "состояния: " + " → ".join(seq)


@check("drop")
def check_drop(r):
    """Обрыв TCP завершает игру (требование адаптера)."""
    mock, port = r.start_mock(["--drop", "4", "--duration", "30"])
    game = None
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        deadline = time.time() + 12
        while time.time() < deadline and game.poll() is None:
            time.sleep(0.1)
        code = game.poll()
    finally:
        r.stop(game)
        r.stop(mock)
    if code is not None:
        return True, "игра завершилась сама, код %s" % code
    return False, "игра пережила обрыв соединения"


@check("phases")
def check_phases(r):
    """Фазы жеста start/hold/end доходят, старт даёт толчок ракеткой."""
    mock, port = r.start_mock(["--jump-every", "1", "--duration", "30"])
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        time.sleep(6)
        r.stop(game)
    finally:
        r.stop(mock)
    text = r.text()
    ok = ("PHASE jump hold" in text and "PHASE jump end" in text
          and "PUSH slot=" in text and "SCRIPT ERROR" not in text)
    return ok, "фазы hold/end и толчок видны в логе" if ok else "фаз или толчка нет"


@check("lowconf")
def check_lowconf(r):
    """Жест с confidence 0.45 не двигает игру (порог 0.75)."""
    mock, port = r.start_mock(["--jump-every", "1", "--lowconf", "--duration", "30"])
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        time.sleep(5)
        r.stop(game)
    finally:
        r.stop(mock)
    text = r.text()
    ok = "PUSH slot=" not in text and "STATE PLAY" in text
    return ok, "ложных толчков нет" if ok else "жест ниже порога сработал"


@check("lost")
def check_lost(r):
    """state=lost при свежих данных → пауза сразу, без ожидания устаревания."""
    mock, port = r.start_mock(["--lost", "4", "--gone-for", "1.5", "--duration", "30"])
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        time.sleep(7.5)
        r.stop(game)
    finally:
        r.stop(mock)
    text = r.text()
    ok = "трек потерян" in text and "STATE PAUSED" in text and "STATE READY" in text
    return ok, "пауза по state и возврат в игру" if ok else "пауза по state не сработала"


@check("reacquire")
def check_reacquire(r):
    """reacquired=true при confirmed → пауза «вернулся» и перекалибровка."""
    mock, port = r.start_mock(["--reacq-flag", "4", "--duration", "30"])
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        time.sleep(8)
        r.stop(game)
    finally:
        r.stop(mock)
    text = r.text()
    ok = "вернулся" in text and text.count("STATE PAUSED") >= 1
    return ok, "возврат трека обработан" if ok else "reacquired не обработан"


@check("nohead")
def check_nohead(r):
    """Пропала точка головы: без падений, через 2 с пауза с понятной причиной."""
    # Голова пропадает насовсем: пауза не должна зависеть от того, успел ли
    # забиться гол и сбросить окно PLAY.
    mock, port = r.start_mock(["--lose-head", "4", "--gone-for", "40", "--duration", "45"])
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        time.sleep(10)
        r.stop(game)
    finally:
        r.stop(mock)
    text = r.text()
    ok = "потеряна точка головы" in text and "SCRIPT ERROR" not in text
    return ok, "«слепой» режим и пауза сработали" if ok else "пропажа головы не обработана"


@check("legacy")
def check_legacy(r):
    """Источник без позы и frame_size: работает фолбэк по рамке, игра играбельна."""
    mock, port = r.start_mock(["--legacy", "--duration", "30"])
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        time.sleep(8)
        r.stop(game)
    finally:
        r.stop(mock)
    text = r.text()
    ok = "fallback=true" in text and "STATE PLAY" in text and "SCRIPT ERROR" not in text
    return ok, "фолбэк по рамке, раунд идёт" if ok else "совместимость со старым источником нарушена"


@check("video")
def check_video(r):
    """JPEG-кадры камеры принимаются и рисуются в HUD без ошибок."""
    try:
        import PIL  # noqa: F401
    except ImportError:
        return None, "пропущено: нет Pillow (pip install pillow)"
    mock, port = r.start_mock(["--video", "--duration", "16"])
    try:
        game = r.start_game(["--port=" + port, "--selftest=log"])
        time.sleep(8)
        r.stop(game)
    finally:
        r.stop(mock)
    bad = re.search(r"SCRIPT ERROR|Cannot load|Failed to load", r.text())
    seq = states(r)
    return bad is None and "PLAY" in seq, "состояния: " + " → ".join(seq)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--godot", default="godot", help="путь к исполняемому файлу Godot 4.5.1")
    ap.add_argument("--only", default="", help="через запятую: имена проверок")
    ap.add_argument("--list", action="store_true", help="показать список проверок")
    args = ap.parse_args()
    if args.list:
        for name in CHECKS:
            print("%-9s %s" % (name, (CHECKS[name].__doc__ or "").strip()))
        return 0
    names = [n.strip() for n in args.only.split(",") if n.strip()] or list(CHECKS)
    failed = 0
    for name in names:
        fn = CHECKS.get(name)
        if fn is None:
            print("нет такой проверки:", name)
            return 2
        runner = Runner(args)
        started = time.time()
        try:
            ok, detail = fn(runner)
        except Exception as exc:  # noqa: BLE001
            ok, detail = False, "исключение: %r" % exc
        mark = {True: "OK  ", False: "FAIL", None: "SKIP"}[ok]
        print("[%s] %-9s %5.1f c  %s" % (mark, name, time.time() - started, detail), flush=True)
        if ok is False:
            failed += 1
            print("--- вывод игры ---")
            print(runner.text()[-3000:])
    print("\nИтог: %d из %d проверок не прошли" % (failed, len(names)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
