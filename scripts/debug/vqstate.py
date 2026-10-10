#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Dump the virtio queue state of a running vmapple guest over QMP.

  scripts/debug/vqstate.py <qmp-socket> [device-name-filter]

Per queue: QEMU's view (x-query-virtio-queue-status: last_avail, used_idx,
signalled) and the ring addresses, plus the guest-written ring fields read
from guest memory (avail flags/idx/used_event, used flags/idx/avail_event).
With EVENT_IDX, a used_event that lags used.idx after the guest has had time
to run means the driver has not consumed those completions.  Then the MSI-X
table and PBA of each virtio PCI function (vector address/data/control).
QEMU's HMP "info virtio-status" and QMP "x-query-virtio-status" are avoided:
they hung or crashed QEMU with these guests."""
import json, socket, sys, re

sock = socket.socket(socket.AF_UNIX)
sock.connect(sys.argv[1])
f = sock.makefile('rw')
filt = sys.argv[2] if len(sys.argv) > 2 else ''

def rd():
    while True:
        m = json.loads(f.readline())
        if 'event' in m:
            continue
        return m

rd()
def q(cmd, **args):
    f.write(json.dumps({'execute': cmd, 'arguments': args} if args else {'execute': cmd}) + '\n')
    f.flush()
    return rd()

def hmp(line):
    return q('human-monitor-command', **{'command-line': line}).get('return', '')

def xp16(addr, n=1):
    out = hmp(f'xp /{n}hx {addr:#x}')
    return [int(v, 16) for v in re.findall(r'0x([0-9a-f]{4})\b', out.split(':', 1)[1])] if ':' in out else []

def xp32(addr, n=1):
    out = hmp(f'xp /{n}wx {addr:#x}')
    vals = []
    for line in out.splitlines():
        if ':' in line:
            vals += [int(v, 16) for v in re.findall(r'0x([0-9a-f]{8})\b', line.split(':', 1)[1])]
    return vals

q('qmp_capabilities')
devs = q('x-query-virtio')['return']
for d in devs:
    if filt and filt not in d['name']:
        continue
    print(f"== {d['name']} {d['path']}")
    for n in range(8):
        r = q('x-query-virtio-queue-status', path=d['path'], queue=n)
        if 'error' in r:
            break
        s = r['return']
        num, av, us = s['vring-num'], s['vring-avail'], s['vring-used']
        line = (f"  q{n}: num={num} desc={s['vring-desc']:#x} avail={av:#x} used={us:#x} last_avail={s['last-avail-idx']} shadow_avail={s['shadow-avail-idx']} "
                f"used_idx={s['used-idx']} signalled={s['signalled-used']} valid={s['signalled-used-valid']} inuse={s['inuse']}")
        if av:
            a = xp16(av, 2)
            ue = xp16(av + 4 + 2 * num)
            u = xp16(us, 2)
            ae = xp16(us + 4 + 8 * num)
            line += (f" | guest avail.flags={a[0]:#x} avail.idx={a[1]} used_event={ue[0] if ue else '?'}"
                     f" used.flags={u[0]:#x} used.idx={u[1]} avail_event={ae[0] if ae else '?'}")
        print(line)

# MSI-X table (BAR1 offset 0) and PBA (BAR1 + 0x800) of each virtio function
pci = hmp('info pci')
for b in pci.split('  Bus ')[1:]:
    m = re.search(r'PCI device (1af4|106b):(\w+)', b)
    bar1 = re.search(r'BAR1: 32 bit memory at (0x[0-9a-f]+)', b)
    if not m or not bar1:
        continue
    base = int(bar1.group(1), 16)
    t = xp32(base, 16)
    pba = xp32(base + 0x800, 1)
    ents = ' '.join(f"[{i}] addr={t[4*i+1]:08x}{t[4*i]:08x} data={t[4*i+2]:#x} ctl={t[4*i+3]:#x}" for i in range(len(t)//4))
    print(f"== msix {m.group(1)}:{m.group(2)} bar1={base:#x} pba={hex(pba[0]) if pba else '?'} {ents}")
