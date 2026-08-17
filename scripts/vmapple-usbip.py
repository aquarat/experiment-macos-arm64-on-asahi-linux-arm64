#!/usr/bin/env python3

"""Expose AVPBooter's VMApple DFU socket as a USB/IP device."""

import argparse
import os
from pathlib import Path
import socket
import struct
import sys


USBIP_VERSION = 0x0111
OP_REQ_IMPORT = 0x8003
OP_REP_IMPORT = 0x0003
USBIP_CMD_SUBMIT = 0x0001
USBIP_CMD_UNLINK = 0x0002
USBIP_RET_SUBMIT = 0x0003
USBIP_RET_UNLINK = 0x0004
USBIP_DIR_OUT = 0
USBIP_DIR_IN = 1
USB_SPEED_HIGH = 3
AVP_TRANSFER_SETUP = 1
AVP_TRANSFER_DATA_OUT = 3
AVP_TRANSFER_DATA_OUT_REPLY = 5
DFU_GETSTATUS_SETUP = bytes.fromhex("a103000000000600")
DFU_DOWNLOAD_IDLE = bytes.fromhex("000000000500")
DFU_MANIFEST_WAIT_RESET = bytes.fromhex("000000000800")
BUS_ID = "1-1"
DEVICE_ID = 0x00010001
MAX_TRANSFER = 128 * 1024
VHCI_NULL = 4


def receive_exact(sock: socket.socket, size: int) -> bytes:
    result = bytearray()
    while len(result) < size:
        chunk = sock.recv(size - len(result))
        if not chunk:
            raise EOFError("connection closed")
        result.extend(chunk)
    return bytes(result)


def fixed_string(value: str, size: int) -> bytes:
    encoded = value.encode("ascii")
    if len(encoded) >= size:
        raise ValueError(f"string does not fit in {size} bytes")
    return encoded + bytes(size - len(encoded))


class AVPTransport:
    def __init__(self, path: str):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.connect(path)

    def close(self) -> None:
        self.socket.close()

    def send_packet(self, packet: bytes) -> None:
        self.socket.sendall(struct.pack("<I", len(packet)) + packet)

    def receive_packet(self) -> bytes:
        length = struct.unpack("<I", receive_exact(self.socket, 4))[0]
        if length > MAX_TRANSFER:
            raise RuntimeError(f"oversized AVP packet: {length}")
        return receive_exact(self.socket, length)

    @staticmethod
    def host_packet(endpoint: int, transfer_type: int, payload: bytes) -> bytes:
        return struct.pack("<iBB", len(payload), endpoint, transfer_type) + payload

    def control(self, setup: bytes, direction: int, data: bytes,
                expected_length: int) -> bytes:
        self.send_packet(self.host_packet(0, AVP_TRANSFER_SETUP, setup))
        if direction == USBIP_DIR_OUT and data:
            self.send_packet(self.host_packet(0, AVP_TRANSFER_DATA_OUT, data))
        response_type = (AVP_TRANSFER_DATA_OUT_REPLY
                         if direction == USBIP_DIR_OUT and data
                         else AVP_TRANSFER_SETUP)
        response = self.validate_response(self.receive_packet(), response_type)
        payload = response[2:]
        if direction == USBIP_DIR_IN:
            return payload[:expected_length]
        return b""

    @staticmethod
    def validate_response(response: bytes, expected_type: int) -> bytes:
        if (len(response) < 2 or response[0] != expected_type
                or response[1] != 0):
            raise RuntimeError(f"AVP USB transfer failed: {response.hex()}")
        return response


def send_import_reply(client: socket.socket, version: int) -> None:
    client.sendall(struct.pack("!HHI", version, OP_REP_IMPORT, 0))
    device = b"".join((
        fixed_string("/sys/devices/vmapple/dfu", 256),
        fixed_string(BUS_ID, 32),
        struct.pack("!IIIHHHBBBBBB", 1, 1, USB_SPEED_HIGH,
                    0x05AC, 0x1227, 0x0000,
                    0, 0, 0, 0, 1, 0),
    ))
    client.sendall(device)


def receive_import(client: socket.socket) -> None:
    version, code, status = struct.unpack("!HHI", receive_exact(client, 8))
    if version not in (0x0106, USBIP_VERSION):
        raise RuntimeError(f"unsupported USB/IP version: {version:#06x}")
    if code != OP_REQ_IMPORT or status != 0:
        raise RuntimeError(f"expected import request, got code={code:#06x}")
    busid = receive_exact(client, 32).split(b"\0", 1)[0].decode("ascii")
    if busid != BUS_ID:
        raise RuntimeError(f"unknown USB/IP bus id: {busid}")
    send_import_reply(client, version)


def send_submit_reply(client: socket.socket, basic: tuple[int, ...],
                      status: int, payload: bytes,
                      actual_length: int | None = None) -> None:
    _command, seqnum, devid, direction, endpoint = basic
    if actual_length is None:
        actual_length = len(payload)
    header = struct.pack(
        "!IIIIIiiiii8x", USBIP_RET_SUBMIT, seqnum, devid, direction,
        endpoint, status, actual_length, 0, 0, 0,
    )
    client.sendall(header + payload)


def serve_urbs(client: socket.socket, avp: AVPTransport, verbose: bool) -> None:
    while True:
        raw = receive_exact(client, 48)
        basic = struct.unpack_from("!IIIII", raw)
        command, seqnum, _devid, direction, endpoint = basic
        if command == USBIP_CMD_UNLINK:
            unlink_seqnum = struct.unpack_from("!I", raw, 20)[0]
            if verbose:
                print(f"unlink seq={unlink_seqnum}", file=sys.stderr)
            reply = struct.pack("!IIIIIi24x", USBIP_RET_UNLINK, seqnum,
                                DEVICE_ID, direction, endpoint, -2)
            client.sendall(reply)
            continue
        if command != USBIP_CMD_SUBMIT:
            raise RuntimeError(f"unsupported USB/IP command: {command:#x}")

        flags, length, _start, packets, _interval = struct.unpack_from(
            "!Iiiii", raw, 20
        )
        del flags
        setup = raw[40:48]
        if packets != 0 or endpoint != 0:
            send_submit_reply(client, basic, -95, b"")  # EOPNOTSUPP
            continue
        if length < 0 or length > MAX_TRANSFER:
            send_submit_reply(client, basic, -90, b"")  # EMSGSIZE
            continue
        outgoing = receive_exact(client, length) if direction == USBIP_DIR_OUT else b""
        if verbose:
            print(f"submit seq={seqnum} dir={direction} len={length} "
                  f"setup={setup.hex()}", file=sys.stderr)
        try:
            is_getstatus = (direction == USBIP_DIR_IN
                            and setup == DFU_GETSTATUS_SETUP)
            avp.socket.settimeout(2.0 if is_getstatus else None)
            try:
                payload = avp.control(setup, direction, outgoing, length)
            except TimeoutError:
                if not is_getstatus:
                    raise
                # A successfully manifested image stops replying while it
                # waits for the host-side USB reset. Type zero is the AVP
                # transport's bus-reset event; USB/IP does not carry that
                # event as an URB, so forward it explicitly here.
                avp.send_packet(avp.host_packet(0, 0, b""))
                payload = DFU_MANIFEST_WAIT_RESET
                if verbose:
                    print(f"reply seq={seqnum} manifest timeout; "
                          "synthesizing wait-reset", file=sys.stderr)
            finally:
                avp.socket.settimeout(None)
            if (direction == USBIP_DIR_IN and setup == DFU_GETSTATUS_SETUP
                    and not payload):
                # AVP's virtual USB transport acknowledges the status request
                # with an empty frame while advancing from DNLOAD-SYNC. A
                # physical host controller hides this transient from libusb.
                payload = DFU_DOWNLOAD_IDLE
            if verbose:
                preview = payload[:64].hex()
                suffix = "..." if len(payload) > 64 else ""
                print(f"reply seq={seqnum} len={len(payload)} "
                      f"data={preview}{suffix}", file=sys.stderr)
            actual_length = len(payload) if direction == USBIP_DIR_IN else length
            send_submit_reply(client, basic, 0, payload, actual_length)
        except RuntimeError as error:
            if verbose:
                print(f"transfer error: {error}", file=sys.stderr)
            send_submit_reply(client, basic, -32, b"")  # EPIPE/stall


def find_vhci_port(vhci: Path) -> int:
    status_files = sorted(vhci.glob("status*"))
    if not status_files:
        raise RuntimeError(f"vhci-hcd is not loaded under {vhci}")
    for status_file in status_files:
        for line in status_file.read_text(encoding="ascii").splitlines()[1:]:
            fields = line.split()
            if len(fields) >= 3 and fields[0] == "hs" and int(fields[2]) == VHCI_NULL:
                return int(fields[1])
    raise RuntimeError("no free high-speed vhci-hcd port")


def direct_attach(socket_path: str, vhci: Path, verbose: bool) -> None:
    if os.geteuid() != 0:
        raise RuntimeError("--direct-attach requires root for vhci-hcd sysfs")
    port = find_vhci_port(vhci)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        kernel = socket.create_connection(listener.getsockname())
        bridge, _address = listener.accept()
    avp = AVPTransport(socket_path)
    attached = False
    try:
        command = f"{port} {kernel.fileno()} {DEVICE_ID} {USB_SPEED_HIGH}"
        (vhci / "attach").write_text(command, encoding="ascii")
        attached = True
        kernel.close()
        print(f"attached VMApple DFU to vhci-hcd port {port}", flush=True)
        serve_urbs(bridge, avp, verbose)
    finally:
        bridge.close()
        kernel.close()
        avp.close()
        if attached:
            (vhci / "detach").write_text(str(port), encoding="ascii")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True,
                        help="QEMU VMApple USB Unix socket")
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3240)
    parser.add_argument("--direct-attach", action="store_true",
                        help="attach directly to an already-loaded vhci-hcd")
    parser.add_argument("--vhci-path", type=Path,
                        default=Path("/sys/devices/platform/vhci_hcd.0"))
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if args.direct_attach:
        direct_attach(args.socket, args.vhci_path, args.verbose)
        return 0

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((args.listen, args.port))
        server.listen(1)
        print(f"VMApple DFU USB/IP {BUS_ID} listening on "
              f"{args.listen}:{args.port}", flush=True)
        client, address = server.accept()
        with client:
            if args.verbose:
                print(f"client connected: {address}", file=sys.stderr)
            receive_import(client)
            avp = AVPTransport(args.socket)
            try:
                serve_urbs(client, avp, args.verbose)
            finally:
                avp.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (EOFError, OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
