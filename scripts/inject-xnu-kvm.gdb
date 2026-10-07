python
import gdb
import json
import os
import socket
import struct
import sys
import tempfile


HANDOFF_PC = int(os.environ.get("VMAPPLE_HANDOFF_PC", "0xACA00000"), 0)
COMMAND_LINE_OFFSET = 108
COMMAND_LINE_SIZE = 608
DEVICE_TREE_POINTER_OFFSET = 96
VIRTUAL_BASE_OFFSET = 8
PHYSICAL_BASE_OFFSET = 16
KVM_MMIO_SIGNATURE = struct.pack(
    "<IIII", 0x12AFC009, 0xB8080D09, 0x52A10009, 0xB9008109
)
KVM_MMIO_FIRST = struct.pack("<I", 0xB9008109)
KVM_MMIO_SECOND = struct.pack("<I", 0xB9010109)


def required(name):
    value = os.environ.get(name)
    if not value:
        raise gdb.GdbError(f"set {name}")
    return value


port = required("QEMU_27ON86_GDB_PORT")
command_line = required("QEMU_27ON86_XNU_BOOT_ARGS").encode()
qmp_socket = required("QEMU_27ON86_QMP_SOCKET")
if b"\0" in command_line or len(command_line) >= COMMAND_LINE_SIZE:
    raise gdb.GdbError("invalid XNU command line")

gdb.execute("set architecture aarch64", to_string=True)
gdb.execute(f"target remote :{port}", to_string=True)
breakpoint = gdb.Breakpoint(
    f"*{HANDOFF_PC:#x}", type=gdb.BP_HARDWARE_BREAKPOINT, internal=True
)
breakpoint.ignore_count = 1
gdb.execute("continue", to_string=True)
if int(gdb.parse_and_eval("$pc")) != HANDOFF_PC:
    raise gdb.GdbError("unexpected XNU handoff address")

boot_args = int(gdb.parse_and_eval("$x1"))
inferior = gdb.selected_inferior()
revision, version = struct.unpack("<HH", bytes(inferior.read_memory(boot_args, 4)))
if (revision, version) not in ((2, 2), (3, 2)):
    raise gdb.GdbError(f"unexpected boot_args revision/version {revision}/{version}")
if revision == 3:
    # macOS 26 passes revision 3. Accept it only if the revision-2 offsets
    # still describe a plausible layout (device tree inside guest memory).
    vb, pb, msz = struct.unpack("<QQQ", bytes(inferior.read_memory(boot_args + 8, 24)))
    dtp, dtl = struct.unpack("<QI", bytes(inferior.read_memory(boot_args + DEVICE_TREE_POINTER_OFFSET, 12)))
    if not (vb <= dtp < vb + msz and 0 < dtl < 4 * 1024 * 1024):
        raise gdb.GdbError(f"boot_args rev 3 layout check failed: dt={dtp:#x}/{dtl:#x} virt={vb:#x} mem={msz:#x}")
    print(f"boot_args revision 3 accepted: dt={dtp:#x} len={dtl:#x}")
payload = (command_line + b"\0").ljust(COMMAND_LINE_SIZE, b"\0")
inferior.write_memory(boot_args + COMMAND_LINE_OFFSET, payload)
print(f"injected XNU boot arguments: {command_line.decode(errors='replace')}")

virtual_base, physical_base = struct.unpack(
    "<QQ", bytes(inferior.read_memory(boot_args + VIRTUAL_BASE_OFFSET, 16))
)

csr_text = os.environ.get("QEMU_27ON86_CSR_CONFIG")
if csr_text:
    csr_config = int(csr_text, 0)
    device_tree_virtual, device_tree_length = struct.unpack(
        "<QI", bytes(inferior.read_memory(boot_args + DEVICE_TREE_POINTER_OFFSET, 12))
    )
    device_tree = device_tree_virtual - virtual_base + physical_base
    flattened = bytearray(inferior.read_memory(device_tree, device_tree_length))
    sys.path.insert(0, required("VMAPPLE_INJECT_SCRIPT_DIR"))
    import apple_device_tree
    root = apple_device_tree.parse(flattened)
    chosen = apple_device_tree.child_named(flattened, root, "chosen")
    asmb = apple_device_tree.child_named(flattened, chosen, "asmb")
    old_name = "lp-sip0" if "lp-sip0" in asmb["properties"] else "lp-stng"
    apple_device_tree.replace_property(
        flattened, asmb, old_name, "lp-sip0", struct.pack("<Q", csr_config)
    )
    inferior.write_memory(device_tree, flattened)
    print(f"injected XNU CSR configuration: {csr_config:#x}")

qmp = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
qmp.settimeout(30)
qmp.connect(qmp_socket)
qmp_file = qmp.makefile("rwb", buffering=0)


def qmp_call(command, arguments=None):
    request = {"execute": command}
    if arguments is not None:
        request["arguments"] = arguments
    qmp_file.write(json.dumps(request).encode() + b"\n")
    while True:
        response = json.loads(qmp_file.readline())
        if "return" in response:
            return response["return"]
        if "error" in response:
            raise gdb.GdbError(f"QMP {command} failed: {response['error']}")


if os.environ.get("QEMU_27ON86_KVM_MMIO_PATCH", "1") == "0":
    qmp_file.close()
    qmp.close()
    print("XNU GIC MMIO patch disabled (QEMU_27ON86_KVM_MMIO_PATCH=0)")
    breakpoint.delete()
    gdb.execute("detach", to_string=True)
    gdb.execute("quit", to_string=True)

json.loads(qmp_file.readline())
qmp_call("qmp_capabilities")
dump = tempfile.NamedTemporaryFile(prefix="vmapple-xnu-", suffix=".bin", delete=False)
dump.close()
try:
    qmp_call("pmemsave", {
        "val": physical_base,
        "size": 128 * 1024 * 1024,
        "filename": dump.name,
    })
    with open(dump.name, "rb") as dumped:
        window = dumped.read()
finally:
    os.unlink(dump.name)
    qmp_file.close()
    qmp.close()

matches = []
start = 0
while True:
    found = window.find(KVM_MMIO_SIGNATURE, start)
    if found < 0:
        break
    matches.append(physical_base + found)
    start = found + 1
if len(matches) != 1:
    raise gdb.GdbError(
        f"expected one XNU GIC MMIO instruction sequence, found {len(matches)}"
    )
patch_address = matches[0] + 4
inferior.write_memory(patch_address, KVM_MMIO_FIRST)
inferior.write_memory(patch_address + 8, KVM_MMIO_SECOND)
print("patched XNU pre-indexed GIC MMIO store for KVM emulation")

breakpoint.delete()
gdb.execute("detach", to_string=True)
end
