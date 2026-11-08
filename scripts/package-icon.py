#!/usr/bin/env python3
"""Package unchanged Ghostty artwork in a Snow Leopard-compatible ICNS."""
import argparse
from io import BytesIO
from pathlib import Path
import struct
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
source = Image.open(args.source).convert("RGBA")
entries = []

def entry(kind, payload):
    entries.append(kind + struct.pack(">I", len(payload) + 8) + payload)

for size, rgb, alpha in ((16, b"is32", b"s8mk"), (32, b"il32", b"l8mk"),
                         (48, b"ih32", b"h8mk"), (128, b"it32", b"t8mk")):
    image = source.resize((size, size), Image.Resampling.LANCZOS)
    # Legacy RGB channels use ICNS RLE. Literal blocks preserve exact bytes.
    payload = b"\0\0\0\0" if size == 128 else b""
    for channel in image.split()[:3]:
        data = channel.tobytes()
        for offset in range(0, len(data), 128):
            block = data[offset:offset + 128]
            payload += bytes([len(block) - 1]) + block
    entry(rgb, payload)
    entry(alpha, image.getchannel("A").tobytes())

for size, kind in ((256, b"ic08"), (512, b"ic09")):
    stream = BytesIO()
    source.resize((size, size), Image.Resampling.LANCZOS).save(stream, "PNG")
    entry(kind, stream.getvalue())

body = b"".join(entries)
args.output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
print("Packaged icon:", args.output)
