#!/usr/bin/env python3
"""Автопроверки Neon Air Hockey (Godot AR API v1).

Запускает игру с эмулятором трекинга и проверяет ключевые сценарии из
приёмочного списка. Нужен Godot 4.5.1 (подойдёт и редакторская сборка).

  python3 tools/run_checks.py --godot /путь/к/godot
  python3 tools/run_checks.py --godot godot --only protocol
  python3 tools/run_checks.py --godot godot --list

Код возврата 0 — все проверки прошли.
"""
import argparse
import re
import subprocess
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
        mock = subprocess.Popen(
            [sys.executable, "-u", "tools/mock_tracker.py"] + extra,
            cwd=GAME_DIR, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        threading.Thread(target=self._pump, args=(mock.stdout,), daemon=True).start()
        port = None
        for _ in range(200):
            m = re.search(r"--port=(\d+)", self.text())
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
    """Трекинг: 2 игрока, калибровка, движение ракетки за головой, жесты."""
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
