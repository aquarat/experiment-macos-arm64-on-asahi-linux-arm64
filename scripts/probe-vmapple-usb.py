#!/usr/bin/env python3

"""Probe AVPBooter's VMApple USB transport over the QEMU socket backend."""

import argparse
from pathlib import Path
import socket
import struct
import sys
import time


APPLE_DFU_VID = 0x05AC
APPLE_DFU_PID = 0x1227


def receive_exact(sock: socket.socket, size: int) -> bytes:
    result = bytearray()
    while len(result) < size:
        chunk = sock.recv(size - len(result))
        if not chunk:
            raise RuntimeError("VMApple USB socket closed early")
        result.extend(chunk)
    return bytes(result)


def exchange(client: socket.socket, packet: bytes) -> bytes:
    client.sendall(struct.pack("<I", len(packet)) + packet)
    response_size = struct.unpack("<I", receive_exact(client, 4))[0]
    return receive_exact(client, response_size)


def send_packet(client: socket.socket, packet: bytes) -> None:
    client.sendall(struct.pack("<I", len(packet)) + packet)


def receive_packet(client: socket.socket) -> bytes:
    response_size = struct.unpack("<I", receive_exact(client, 4))[0]
    return receive_exact(client, response_size)


def control_in(client: socket.socket, descriptor_type: int,
               descriptor_index: int, length: int, language: int = 0) -> bytes:
    setup = struct.pack(
        "<iBB8B", 8, 0, 1, 0x80, 6, descriptor_index,
        descriptor_type, language & 0xFF, language >> 8,
        length & 0xFF, length >> 8,
    )
    response = exchange(client, setup)
    if len(response) < 2 or response[:2] != b"\x01\x00":
        raise RuntimeError(f"unexpected control reply: {response.hex()}")
    return response[2:]


def control_request_in(client: socket.socket, request_type: int, request: int,
                       value: int, index: int, length: int) -> bytes:
    setup = struct.pack(
        "<iBB8B", 8, 0, 1, request_type, request,
        value & 0xFF, value >> 8, index & 0xFF, index >> 8,
        length & 0xFF, length >> 8,
    )
    response = exchange(client, setup)
    if len(response) < 2 or response[:2] != b"\x01\x00":
        raise RuntimeError(f"unexpected control reply: {response.hex()}")
    return response[2:]


def control_out(client: socket.socket, request: int, value: int,
                index: int = 0, data: bytes = b"",
                request_type: int = 0, data_type: int = 3,
                data_setup_prefix: bool = False,
                extra_data_reply: bool = False) -> bytes:
    setup = struct.pack(
        "<iBB8B", 8, 0, 1, request_type, request,
        value & 0xFF, value >> 8, index & 0xFF, index >> 8,
        len(data) & 0xFF, len(data) >> 8,
    )
    if data:
        prefix = setup[-8:] if data_setup_prefix else b""
        packet_length = len(data) + len(prefix)
        data_packet = (struct.pack("<iBB", packet_length, 0, data_type)
                       + prefix + data)
        send_packet(client, setup)
        send_packet(client, data_packet)
        response = receive_packet(client)
        if extra_data_reply:
            response += receive_packet(client)
    else:
        response = exchange(client, setup)
    return response


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("socket", help="QEMU VMApple USB Unix socket")
    parser.add_argument("--timeout", type=float, default=3.0)
    parser.add_argument("--test-download", action="store_true",
                        help="send a disposable four-byte DFU block")
    parser.add_argument("--test-download-size", type=int,
                        help="send a disposable zero-filled DFU block")
    parser.add_argument("--test-download-file", type=Path,
                        help="send up to 2048 bytes from a local test file")
    parser.add_argument("--file-limit", type=int, default=2048,
                        help="maximum bytes read by --test-download-file")
    parser.add_argument("--stream-download", action="store_true",
                        help="send the entire file without per-block status")
    parser.add_argument("--data-type", type=int, default=3,
                        help="BDIF transfer type for the test data phase")
    parser.add_argument("--fill-byte", type=lambda value: int(value, 0), default=0,
                        help="byte used by the disposable download test")
    parser.add_argument("--xor-first-byte", type=lambda value: int(value, 0),
                        default=0,
                        help="XOR the first file byte for corruption tests")
    parser.add_argument("--data-setup-prefix", action="store_true",
                        help="repeat the setup bytes before OUT data")
    parser.add_argument("--status-delay", type=float, default=0,
                        help="seconds to wait before DFU GETSTATUS")
    parser.add_argument("--extra-data-reply", action="store_true",
                        help="receive a second reply after OUT data")
    parser.add_argument("--status-retries", type=int, default=1,
                        help="repeat an empty DFU GETSTATUS request")
    args = parser.parse_args()
    download_size = args.test_download_size
    if args.test_download:
        if download_size is not None or args.test_download_file is not None:
            parser.error("use only one download test option")
        download_size = 4
    if args.test_download_file is not None:
        if download_size is not None:
            parser.error("use only one download test option")
        if not 1 <= args.file_limit <= 2048:
            parser.error("--file-limit must be between 1 and 2048")
        file_data = args.test_download_file.read_bytes()
        test_data = file_data if args.stream_download else file_data[:args.file_limit]
        if not test_data:
            parser.error("--test-download-file is empty")
        download_size = len(test_data)
    else:
        test_data = None
    if (download_size is not None and not args.stream_download
            and not 1 <= download_size <= 2048):
        parser.error("--test-download-size must be between 1 and 2048")
    if not 0 <= args.data_type <= 255:
        parser.error("--data-type must fit in one byte")
    if not 0 <= args.fill_byte <= 255:
        parser.error("--fill-byte must fit in one byte")
    if not 0 <= args.xor_first_byte <= 255:
        parser.error("--xor-first-byte must fit in one byte")
    if args.xor_first_byte and test_data is None:
        parser.error("--xor-first-byte requires --test-download-file")
    if args.xor_first_byte:
        test_data = bytes([test_data[0] ^ args.xor_first_byte]) + test_data[1:]

    # Host-to-device framing: payload length, endpoint, transfer type, then a
    # standard USB setup packet requesting the 18-byte device descriptor.
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(args.timeout)
        client.connect(args.socket)
        descriptor = control_in(client, 1, 0, 18)
        config_header = control_in(client, 2, 0, 9)
        if len(config_header) != 9:
            raise RuntimeError(f"unexpected configuration header: {config_header.hex()}")
        config = control_in(client, 2, 0,
                            struct.unpack_from("<H", config_header, 2)[0])
        address_reply = control_out(client, 5, 1)
        configuration_reply = control_out(client, 9, 1)
        print("USB enumeration control requests passed", flush=True)
        dfu_state = control_request_in(client, 0xA1, 5, 0, 0, 1)
        print(f"DFU GETSTATE reply={dfu_state.hex()}", flush=True)
        if download_size is not None:
            data = (test_data if test_data is not None else
                    bytes([args.fill_byte]) * download_size)
            if args.stream_download:
                replies = []
                for block, offset in enumerate(range(0, len(data), 2048)):
                    replies.append(control_out(
                        client, 1, block, data=data[offset:offset + 2048],
                        request_type=0x21, data_type=args.data_type))
                replies.append(control_out(client, 1, len(replies),
                                           request_type=0x21))
                download_reply = b"".join(replies)
            else:
                download_reply = control_out(
                    client, 1, 0, data=data, request_type=0x21,
                    data_type=args.data_type,
                    data_setup_prefix=args.data_setup_prefix,
                    extra_data_reply=args.extra_data_reply)
            if args.status_delay < 0:
                parser.error("--status-delay cannot be negative")
            time.sleep(args.status_delay)
            download_status = b""
            for _attempt in range(args.status_retries):
                download_status = control_request_in(client, 0xA1, 3, 0, 0, 6)
                if download_status:
                    break
                time.sleep(0.05)
        else:
            download_reply = None
            download_status = None

    if len(descriptor) != 18:
        raise RuntimeError(f"unexpected device descriptor: {descriptor.hex()}")
    vendor, product = struct.unpack_from("<HH", descriptor, 8)
    print(f"USB device {vendor:04x}:{product:04x} descriptor={descriptor.hex()}")
    if (vendor, product) != (APPLE_DFU_VID, APPLE_DFU_PID):
        raise RuntimeError("AVPBooter did not identify as the expected Apple DFU device")
    if len(config_header) != 9 or config_header[1] != 2:
        raise RuntimeError(f"unexpected configuration descriptor: {config_header.hex()}")
    total_length = struct.unpack_from("<H", config_header, 2)[0]
    print(f"USB configuration total_length={total_length} descriptor={config.hex()}")
    print(f"USB set-address reply={address_reply.hex()}")
    print(f"USB set-configuration reply={configuration_reply.hex()}")
    print(f"DFU state={dfu_state.hex()}")
    if download_reply is not None:
        print(f"DFU download reply={download_reply.hex()} "
              f"status={download_status.hex()}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
