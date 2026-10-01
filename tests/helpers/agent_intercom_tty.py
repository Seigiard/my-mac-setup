#!/usr/bin/env python3
"""Run one command with a bounded controlling PTY."""

import os
import select
import signal
import sys
import termios
import time
import fcntl


def main(timeout_seconds=10):
    if len(sys.argv) < 2:
        raise SystemExit("usage: agent_intercom_tty.py command [arguments...]")

    master, slave = os.openpty()
    attributes = termios.tcgetattr(slave)
    attributes[1] &= ~termios.ONLCR
    termios.tcsetattr(slave, termios.TCSANOW, attributes)
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(master)
        os.close(slave)
        os.execvp(sys.argv[1], sys.argv[1:])

    os.close(slave)
    os.set_blocking(master, False)
    deadline = time.monotonic() + timeout_seconds
    status = None

    def stop_group():
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        time.sleep(0.1)
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    try:
        while status is None:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    sys.stdout.buffer.write(os.read(master, 65536))
                    sys.stdout.buffer.flush()
                except OSError:
                    pass
            waited, status = os.waitpid(pid, os.WNOHANG)
            if waited == 0:
                status = None
            if status is None and time.monotonic() >= deadline:
                stop_group()
                _, status = os.waitpid(pid, 0)
                raise TimeoutError(f"PTY command exceeded {timeout_seconds} seconds")
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                stop_group()
                raise TimeoutError("PTY output remained open after command exit")
            ready, _, _ = select.select([master], [], [], remaining)
            if not ready:
                continue
            try:
                chunk = os.read(master, 65536)
            except BlockingIOError:
                continue
            except OSError:
                break
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
    finally:
        os.close(master)

    if os.WIFEXITED(status):
        raise SystemExit(os.WEXITSTATUS(status))
    raise SystemExit(128 + os.WTERMSIG(status))


if __name__ == "__main__":
    main()
