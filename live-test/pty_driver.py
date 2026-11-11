#!/usr/bin/env python3
"""Run an interactive Claude Code or Codex session in a pseudo-terminal and drive it from a FIFO.

The session gets a real TTY, so the tool treats it like a terminal tab and Context Guard guards
it. Each line written to the FIFO is one command:

    type <text>     type the text (no Enter)
    send <text>     type the text, then press Enter
    enter | esc | ctrl-c | ctrl-u | backspace | up | down
    quit            stop the session

The rendered screen is rewritten to --screen every half second; raw output goes to --log.

    uv run --with pyte python3 pty_driver.py --cwd DIR --fifo F --screen S --log L -- claude ...
    uv run --with pyte python3 pty_driver.py --cwd DIR --fifo F --screen S --log L -- codex ...
"""
import argparse
import fcntl
import os
import pty
import signal
import struct
import sys
import termios
import threading
import time

import pyte

KEYS = {"enter": b"\r", "esc": b"\x1b", "ctrl-c": b"\x03", "ctrl-u": b"\x15", "backspace": b"\x7f",
        "up": b"\x1b[A", "down": b"\x1b[B"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cwd", required=True)
    ap.add_argument("--fifo", required=True)
    ap.add_argument("--screen", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--cols", type=int, default=150)
    ap.add_argument("--rows", type=int, default=45)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    cmd = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd

    if not os.path.exists(args.fifo):
        os.mkfifo(args.fifo)

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(args.cwd)
        os.environ["TERM"] = "xterm-256color"
        os.execvp(cmd[0], cmd)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", args.rows, args.cols, 0, 0))
    screen = pyte.Screen(args.cols, args.rows)
    stream = pyte.ByteStream(screen)
    lock = threading.Lock()
    done = threading.Event()

    def reader() -> None:
        with open(args.log, "ab") as log:
            while True:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                log.write(data)
                log.flush()
                with lock:
                    stream.feed(data)
        done.set()

    def snapshot() -> None:
        while not done.is_set():
            with lock:
                text = "\n".join(line.rstrip() for line in screen.display)
            tmp = args.screen + ".tmp"
            with open(tmp, "w") as f:
                f.write(text + "\n")
            os.replace(tmp, args.screen)
            time.sleep(0.5)

    threading.Thread(target=reader, daemon=True).start()
    threading.Thread(target=snapshot, daemon=True).start()

    while not done.is_set():
        with open(args.fifo) as f:  # blocks until a writer opens it
            for raw in f:
                line = raw.rstrip("\n")
                verb, _, rest = line.partition(" ")
                if verb == "type":
                    os.write(fd, rest.encode())
                elif verb == "send":
                    os.write(fd, rest.encode())
                    time.sleep(0.3)
                    os.write(fd, b"\r")
                elif verb in KEYS:
                    os.write(fd, KEYS[verb])
                elif verb == "quit":
                    os.kill(pid, signal.SIGTERM)
                    done.wait(5)
                    return 0
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
