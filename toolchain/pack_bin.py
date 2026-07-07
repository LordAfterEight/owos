#!/usr/bin/env python3
import struct
import subprocess
import sys

JIT_BASE = 0xFFFF_FFFF_8100_0000


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <elf> <out.bin>", file=sys.stderr)
        return 1

    elf, bin_path = sys.argv[1:3]
    raw_path = bin_path.replace(".bin", ".raw")
    if raw_path == bin_path:
        raw_path = bin_path + ".raw"

    symbols = {}
    for line in subprocess.check_output(["nm", elf], text=True).splitlines():
        parts = line.split()
        if len(parts) >= 3:
            symbols[parts[2]] = int(parts[0], 16)

    entry = symbols.get("_start", 0)
    api_abs = symbols.get("owos_api", 0)
    load_end = symbols.get("__load_end", 0)
    if entry < JIT_BASE or api_abs < JIT_BASE:
        print("error: symbols below JIT_BASE", file=sys.stderr)
        return 1

    entry -= JIT_BASE
    api_off = api_abs - JIT_BASE
    image_size = (load_end - JIT_BASE) if load_end >= JIT_BASE else 0
    raw = open(raw_path, "rb").read()
    need = max(len(raw), api_off + 8, image_size)
    if len(raw) < need:
        raw += b"\0" * (need - len(raw))

    with open(bin_path, "wb") as out:
        out.write(struct.pack("<QQ", entry, api_off))
        out.write(raw)

    print(f"entry={entry} api_offset={api_off} size={len(raw)} -> {bin_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())