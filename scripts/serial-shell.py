#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Drive a guest shell on a QEMU serial Unix socket, expect-style.

    serial-shell.py <socket> wait '<regex>' <timeout>
    serial-shell.py <socket> run '<command>' [timeout]     # waits for the shell prompt

Output read from the console is echoed to stdout. A command's completion is
detected by an end marker printed after it, so prompts need not be parsed.
"""
import re
import socket
import sys
import time


def read_until(sock, pattern, timeout):
    deadline = time.time() + timeout
    buf = b""
    regex = re.compile(pattern.encode())
    while time.time() < deadline:
        sock.settimeout(max(0.1, deadline - time.time()))
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        buf += chunk
        sys.stdout.write(chunk.decode(errors="replace"))
        sys.stdout.flush()
        if regex.search(buf):
            return True
    return False


def main():
    path, mode, arg = sys.argv[1:4]
    timeout = float(sys.argv[4]) if len(sys.argv) > 4 else 60
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(path)
    if mode == "wait":
        ok = read_until(sock, arg, timeout)
    elif mode == "run":
        marker = f"__DONE_{int(time.time() * 1000)}__"
        sock.sendall((arg + f"; echo {marker}$?\r").encode())
        ok = read_until(sock, re.escape(marker) + r"\d+", timeout)
    else:
        sys.exit(f"unknown mode {mode}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
