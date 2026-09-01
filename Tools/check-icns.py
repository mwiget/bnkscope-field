#!/usr/bin/env python3
"""Fail if an .icns is missing sizes.

A partial icon still builds and still launches — macOS just scales the largest
it finds — so nothing about the build tells you it happened. The asset
catalogue shipped exactly that: four of the ten sizes, with the Dock quietly
upscaling a 256 to 1024. This reads the chunk table and insists.
"""
import struct
import sys

TYPES = {"ic04": 16, "ic11": 32, "ic05": 64, "ic12": 64, "ic07": 128,
         "ic13": 256, "ic08": 256, "ic14": 512, "ic09": 512, "ic10": 1024}
WANTED = {16, 32, 64, 128, 256, 512, 1024}

def sizes(path):
    data = open(path, "rb").read()
    if data[:4] != b"icns":
        raise SystemExit(f"{path} is not an icns file")
    found, offset = set(), 8
    while offset < len(data):
        kind, length = struct.unpack(">4sI", data[offset:offset + 8])
        if length < 8:
            raise SystemExit(f"{path} has a malformed chunk at {offset}")
        found.add(TYPES.get(kind.decode("mac_roman")))
        offset += length
    return found - {None}

if __name__ == "__main__":
    have = sizes(sys.argv[1])
    print("icon sizes:", sorted(have))
    missing = WANTED - have
    if missing:
        raise SystemExit(f"icns is missing {sorted(missing)}")
