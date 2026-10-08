#!/usr/bin/env python3
"""Size a macOS guest's memory balloon to what the guest needs, continuously.

    scripts/balloon-governor.py --qmp SOCKET --ssh-port PORT [--key KEY] [--user USER]

Needs a guest started with BALLOON=1 (virtio-balloon with macos-units, see
scripts/launch-kvm.sh); scripts/vm-job.sh starts one governor per guest.

Guest state comes from one long-lived `vm_stat <interval>` over SSH (one
line per interval, no process per sample). Each sample:

  available = free + speculative + purgeable + the file-backed share of the
              inactive queue (cache macOS can drop without compressing)

  pressure  = compressions or swap-outs above a small rate, available below
              half the margin, or available falling (>= 128 MiB a sample)
              fast enough to cross the margin within two samples: deflate
              at once, by the shortfall plus twice the last drop plus twice
              what was compressed, at least BALLOON_DEFLATE_MIN; no
              inflating for BALLOON_COOLDOWN seconds afterwards.
  surplus   = available above margin + hysteresis, no compressions in the
              last few samples, not cooling down: inflate by half the
              surplus, at most BALLOON_INFLATE_STEP per BALLOON_INFLATE_EVERY.

The guest is never left smaller than BALLOON_MIN_GUEST. If the vm_stat stream
stops for BALLOON_BLIND seconds (guest hung or rebooting) the balloon is
released. QEMU's balloon statistics are not used (the macOS driver leaves
them empty); the balloon size is QEMU's count of pages actually received.

Tunables (environment; sizes take K/M/G suffixes):
  BALLOON_MARGIN        available memory to leave the guest      (1536M)
  BALLOON_HYSTERESIS    surplus ignored above the margin          (512M)
  BALLOON_INTERVAL      seconds between samples                   (1)
  BALLOON_MIN_GUEST     smallest guest memory                     (2560M)
  BALLOON_MAX           largest balloon (default: RAM - MIN_GUEST)
  BALLOON_INFLATE_STEP  largest single inflate                    (512M)
  BALLOON_INFLATE_EVERY seconds between inflates                  (5)
  BALLOON_DEFLATE_MIN   smallest deflate on pressure              (1G)
  BALLOON_COOLDOWN      seconds without inflating after pressure  (60)
  BALLOON_COMPRESS_RATE compressed+swapped pages/s that count as
                        pressure (16 KiB pages)                   (64)
  BALLOON_BLIND         seconds without samples before release    (30)
  BALLOON_DRY_RUN=1     log decisions, never change the balloon
  BALLOON_VERBOSE=1     log every sample
"""

import argparse
import json
import os
import select
import signal
import socket
import subprocess
import sys
import time

UNITS = {"": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}


def size_env(name, default):
    text = os.environ.get(name, default).strip().upper().rstrip("B").rstrip("I")
    unit = text[-1] if text and text[-1] in UNITS else ""
    return int(float(text[: len(text) - len(unit)]) * UNITS[unit])


def num_env(name, default):
    return float(os.environ.get(name, default))


def gib(n):
    return f"{n / (1 << 30):.2f}G"


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


class Qmp:
    """Minimal QMP client on a dedicated monitor socket (events skipped)."""

    def __init__(self, path):
        self.path = path
        self.sock = None
        self.buf = b""

    def connect(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(10)
                s.connect(self.path)
                break
            except OSError:
                s.close()
                if time.monotonic() > deadline:
                    raise
                time.sleep(1)
        self.sock, self.buf = s, b""
        self._read()                                    # greeting
        self.call("qmp_capabilities")

    def _read(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("QMP closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, cmd, **args):
        msg = {"execute": cmd}
        if args:
            msg["arguments"] = args
        self.sock.sendall(json.dumps(msg).encode() + b"\n")
        while True:
            reply = self._read()
            if "return" in reply:
                return reply["return"]
            if "error" in reply:
                raise RuntimeError(f"{cmd}: {reply['error'].get('desc')}")


class VmStat:
    """`vm_stat N` in the guest over one SSH session; yields parsed samples."""

    def __init__(self, ssh_cmd, interval):
        self.cmd = ssh_cmd + [f"exec vm_stat {interval}"]
        self.proc = None
        self.cols = None
        self.page = 16384
        self.first = True

    def start(self):
        self.stop()
        self.proc = subprocess.Popen(self.cmd, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.buf, self.cols, self.first = b"", None, True

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        self.proc = None

    def fileno(self):
        return self.proc.stdout.fileno()

    def read(self):
        """Parsed samples from what is buffered; None at end of stream."""
        try:
            data = os.read(self.fileno(), 65536)
        except BlockingIOError:
            return []
        if not data:
            return None
        self.buf += data
        samples = []
        *lines, self.buf = self.buf.split(b"\n")
        for raw in lines:
            line = raw.decode(errors="replace").strip()
            if line.startswith("Mach Virtual Memory"):
                digits = [w for w in line.replace("(", " ").split() if w.isdigit()]
                if digits:
                    self.page = int(digits[0])
            elif line.startswith("free"):
                # vm_stat repeats its header; the line after it holds totals
                self.cols, self.first = line.split(), True
            elif self.cols and line and line[0].isdigit():
                vals = [int(v) for v in line.split()]
                if len(vals) == len(self.cols):
                    sample = dict(zip(self.cols, vals))
                    if self.first:      # totals since boot, not a rate
                        self.first = False
                        continue
                    samples.append(sample)
        return samples


class Governor:
    def __init__(self, qmp, ram):
        self.qmp = qmp
        self.ram = ram
        self.margin = size_env("BALLOON_MARGIN", "1536M")
        self.hyst = size_env("BALLOON_HYSTERESIS", "512M")
        self.min_guest = size_env("BALLOON_MIN_GUEST", "2560M")
        self.max_balloon = min(size_env("BALLOON_MAX", str(ram)), ram - self.min_guest)
        self.inflate_step = size_env("BALLOON_INFLATE_STEP", "512M")
        self.inflate_every = num_env("BALLOON_INFLATE_EVERY", "5")
        self.deflate_min = size_env("BALLOON_DEFLATE_MIN", "1G")
        self.cooldown = num_env("BALLOON_COOLDOWN", "60")
        self.comp_rate = num_env("BALLOON_COMPRESS_RATE", "64")
        self.dry = os.environ.get("BALLOON_DRY_RUN", "0") == "1"
        self.target = None              # balloon size we asked for (bytes)
        self.sent = 0.0
        self.last_inflate = 0.0
        self.last_pressure = -1e9
        self.quiet_samples = 0
        self.prev_avail = self.prev_balloon = None
        self.counts = {"inflate": 0, "deflate": 0, "inflated": 0, "deflated": 0}

    def balloon(self):
        """Current balloon size: what QEMU has received, not what was asked."""
        return self.ram - self.qmp.call("query-balloon")["actual"]

    def set_balloon(self, size, why, s=None):
        size = max(0, min(int(size) >> 24 << 24, self.max_balloon))   # 16 MiB units
        cur = self.balloon()
        now = time.monotonic()
        # already asked for: re-send only if the driver has not got there
        # within 10 s (it drops an inflate it cannot allocate)
        if size == self.target and (size == cur or now - self.sent < 10):
            return
        self.sent = now
        kind = "inflate" if size > cur else "deflate"
        detail = ""
        if s:
            detail = (f" avail {gib(s['avail'])} free {gib(s['free_b'])} "
                      f"cache {gib(s['cache_b'])} comp {s['comp']:.0f}/s")
        log(f"{kind} {gib(cur)} -> {gib(size)}{detail} [{why}]")
        self.counts[kind] += 1
        self.counts[kind + "d"] += abs(size - cur)
        self.target = size
        if not self.dry:
            self.qmp.call("balloon", value=self.ram - size)

    def release(self, why):
        if self.balloon() > 0 or self.target:
            self.set_balloon(0, why)

    def step(self, raw, interval, now):
        pg = raw["_page"]
        fb, anon = raw["file-backed"], raw["anonymous"]
        free_b = (raw["free"] + raw["specul"]) * pg
        cache_b = (raw["prgable"] + raw["inactive"] * fb // max(fb + anon, 1)) * pg
        avail = free_b + cache_b
        comp = (raw["comprs"] + raw["swapouts"]) / interval
        s = {"free_b": free_b, "cache_b": cache_b, "avail": avail, "comp": comp}
        cur = self.balloon()
        # memory the guest took since the last sample (an inflate takes some
        # itself; a deflate is not credited: the guest frees it only later)
        drop = 0
        if self.prev_avail is not None:
            drop = max(self.prev_avail - avail - max(cur - self.prev_balloon, 0), 0)
        self.prev_avail, self.prev_balloon = avail, cur

        pressure = comp > self.comp_rate or avail < self.margin // 2
        falling = drop >= 128 << 20 and avail - 2 * drop < self.margin
        if pressure or falling:
            self.quiet_samples = 0
            self.last_pressure = now
            if cur > 0:
                need = (max(self.margin - avail, 0) + 2 * drop
                        + 2 * (raw["comprs"] + raw["swapouts"]) * pg)
                self.set_balloon(cur - max(need, self.deflate_min),
                                 "pressure" if pressure else "falling", s)
            return s
        self.quiet_samples += 1
        surplus = avail - self.margin
        if (surplus > self.hyst and self.quiet_samples >= 3
                and now - self.last_pressure >= self.cooldown
                and now - self.last_inflate >= self.inflate_every
                and cur < self.max_balloon):
            amount = min(surplus // 2, self.inflate_step, self.max_balloon - cur)
            if amount >= 64 << 20:
                self.last_inflate = now
                self.set_balloon(cur + amount, "surplus", s)
        return s


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--qmp", required=True, help="QMP socket (a monitor of its own)")
    ap.add_argument("--ssh-port", required=True)
    ap.add_argument("--ssh-host", default="127.0.0.1")
    ap.add_argument("--user", default="aquarat")
    ap.add_argument("--key", default=os.path.expanduser("~/.ssh/vmapple_runner"))
    args = ap.parse_args()

    interval = max(1, int(num_env("BALLOON_INTERVAL", "1")))
    blind = num_env("BALLOON_BLIND", "30")
    verbose = os.environ.get("BALLOON_VERBOSE", "0") == "1"
    ssh_cmd = ["ssh", "-i", args.key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
               "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5",
               "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=no",
               "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
               "-p", str(args.ssh_port), f"{args.user}@{args.ssh_host}"]

    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))

    qmp = Qmp(args.qmp)
    qmp.connect(timeout=120)
    ram = qmp.call("query-memory-size-summary")["base-memory"]
    gov = Governor(qmp, ram)
    log(f"governor: ram {gib(ram)} margin {gib(gov.margin)} min guest {gib(gov.min_guest)} "
        f"max balloon {gib(gov.max_balloon)} interval {interval}s"
        + (" (dry run)" if gov.dry else ""))

    stat = VmStat(ssh_cmd, interval)
    started = time.monotonic()
    last_sample = time.monotonic()
    last_report = last_sample
    restart_at = 0.0
    released = False
    try:
        while not stop:
            now = time.monotonic()
            if stat.proc is not None and now - last_sample > max(10, 5 * interval):
                log(f"vm_stat stream silent for {now - last_sample:.0f}s; restarting it")
                stat.stop()
            if stat.proc is None or stat.proc.poll() is not None:
                if now >= restart_at:
                    if stat.proc is not None:
                        log(f"vm_stat stream ended ({stat.proc.returncode}); restarting it")
                    stat.start()
                    restart_at = now + 5
            timeout = interval * 2
            ready = []
            if stat.proc is not None:
                try:
                    ready, _, _ = select.select([stat], [], [], timeout)
                except InterruptedError:
                    continue
            else:
                time.sleep(1)
            now = time.monotonic()
            if ready:
                samples = stat.read()
                if samples is None:
                    log(f"vm_stat stream closed ({stat.proc.wait()})")
                    stat.stop()
                    continue
                for raw in samples:
                    raw["_page"] = stat.page
                    try:
                        s = gov.step(raw, max(now - last_sample, interval), now)
                    except (KeyError, ValueError, TypeError, ZeroDivisionError) as e:
                        log(f"bad sample ({e!r}): {raw}")
                        continue
                    last_sample, released = now, False
                    if verbose:
                        log(f"sample balloon {gib(gov.balloon())} avail {gib(s['avail'])} "
                            f"free {gib(s['free_b'])} cache {gib(s['cache_b'])} "
                            f"comp {s['comp']:.0f}/s")
            if now - last_sample > blind and not released:
                gov.release(f"no guest samples for {now - last_sample:.0f}s")
                released = True
            if now - last_report >= 300:
                t = os.times()
                c = gov.counts
                log(f"status: balloon {gib(gov.balloon())} inflates {c['inflate']} "
                    f"({gib(c['inflated'])}) deflates {c['deflate']} ({gib(c['deflated'])}) "
                    f"cpu {t.user + t.system:.1f}s")
                last_report = now
    except (ConnectionError, OSError, RuntimeError) as e:
        log(f"stopping: {e}")
    finally:
        stat.stop()
        if os.environ.get("BALLOON_RELEASE_ON_EXIT", "0") == "1":
            try:
                gov.release("exit")
            except Exception:
                pass
        t = os.times()
        c = gov.counts
        log(f"exit: inflates {c['inflate']} ({gib(c['inflated'])}) deflates {c['deflate']} "
            f"({gib(c['deflated'])}) cpu {t.user + t.system:.2f}s "
            f"(ssh {t.children_user + t.children_system:.2f}s) "
            f"in {time.monotonic() - started:.0f}s")


if __name__ == "__main__":
    sys.exit(main())
