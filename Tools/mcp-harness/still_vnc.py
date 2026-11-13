#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Serve one image as a VNC screen, so Regi can treat a fixture as a live host.

    still_vnc.py IMAGE PORT

RFB 3.8 on 127.0.0.1:PORT, security type None, Raw encoding, any 32 bpp
true-colour pixel format the client asks for. It answers non-incremental update
requests with the whole image and ignores input. Needs Pillow to read the image.
"""
import socket
import struct
import sys
import threading

from PIL import Image

image = Image.open(sys.argv[1]).convert("RGB")
WIDTH, HEIGHT = image.size
RGB = image.tobytes()
port = int(sys.argv[2])


def recv_exact(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise ConnectionError("client went away")
        data += chunk
    return data


def encode(pixel_format):
    """The image in the client's pixel format: (bits per pixel, big endian, red/green/blue shifts)."""
    bpp, big_endian, red, green, blue = pixel_format
    if bpp != 32:
        raise ValueError(f"only 32 bpp is supported, the client asked for {bpp}")
    out = bytearray(WIDTH * HEIGHT * 4)
    order = "big" if big_endian else "little"
    for i in range(WIDTH * HEIGHT):
        value = (RGB[3 * i] << red) | (RGB[3 * i + 1] << green) | (RGB[3 * i + 2] << blue)
        out[4 * i:4 * i + 4] = value.to_bytes(4, order)
    return bytes(out)


def serve(conn):
    pixel_format, encoded = (32, 0, 16, 8, 0), {}
    conn.sendall(b"RFB 003.008\n")
    recv_exact(conn, 12)                                   # client version
    conn.sendall(bytes([1, 1]))                            # one security type: None
    recv_exact(conn, 1)
    conn.sendall(struct.pack(">I", 0))                     # security result: OK
    recv_exact(conn, 1)                                    # ClientInit
    name = b"still"
    conn.sendall(struct.pack(">HHBBBBHHHBBB3xI", WIDTH, HEIGHT, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, len(name)) + name)
    while True:
        kind = recv_exact(conn, 1)[0]
        if kind == 0:                                      # SetPixelFormat
            fields = struct.unpack(">BBBBHHHBBB", recv_exact(conn, 19)[3:16])
            pixel_format = (fields[0], fields[2], fields[7], fields[8], fields[9])
        elif kind == 2:                                    # SetEncodings
            (count,) = struct.unpack(">xH", recv_exact(conn, 3))
            recv_exact(conn, 4 * count)
        elif kind == 3:                                    # FramebufferUpdateRequest
            incremental = recv_exact(conn, 9)[0]
            if not incremental:                            # a still image never changes
                if pixel_format not in encoded:
                    encoded[pixel_format] = encode(pixel_format)
                conn.sendall(struct.pack(">BxHHHHHi", 0, 1, 0, 0, WIDTH, HEIGHT, 0) + encoded[pixel_format])
        elif kind == 4:                                    # KeyEvent
            recv_exact(conn, 7)
        elif kind == 5:                                    # PointerEvent
            recv_exact(conn, 5)
        elif kind == 6:                                    # ClientCutText (negative length: extended clipboard)
            _, length = struct.unpack(">3si", recv_exact(conn, 7))
            recv_exact(conn, abs(length))
        elif kind == 250:                                  # XVP
            recv_exact(conn, 3)
        elif kind == 255:                                  # QEMU: subtype 0 is the extended key event
            if recv_exact(conn, 1)[0] == 0:
                recv_exact(conn, 10)
        else:
            raise ValueError(f"unknown client message type {kind}")


listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", port))
listener.listen()
print(f"serving {sys.argv[1]} ({WIDTH}x{HEIGHT}) on 127.0.0.1:{port}", flush=True)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
