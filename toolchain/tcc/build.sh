#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIBC="$ROOT/libc"
OUT="$ROOT/libc/out"
TCC_DIR="$ROOT/toolchain/tcc/src"
TCC_VERSION="0.9.27"
TCC_TARBALL="tcc-${TCC_VERSION}.tar.bz2"
TCC_URL="https://download.savannah.nongnu.org/releases/tinycc/${TCC_TARBALL}"

CC="${CC:-gcc}"
OBJCOPY="${OBJCOPY:-objcopy}"

CFLAGS=(
    -O2
    -mcmodel=large
    -ffreestanding
    -fno-stack-protector
    -fno-pic
    -mno-red-zone
    -fcf-protection=none
    -nostdlib
    -static
    -I"$LIBC/include"
    -I"$TCC_DIR"
    -DTCC_TARGET_X86_64
    -DONE_SOURCE=1
    -DCONFIG_TCC_STATIC
    -DNO_FLOAT
    -include "$LIBC/include/stddef.h"
)

LDFLAGS=(
    -nostdlib
    -static
    -T"$LIBC/link.ld"
)

mkdir -p "$OUT" "$TCC_DIR"

if [ ! -f "$TCC_DIR/tcc.c" ]; then
    echo "Downloading TinyCC ${TCC_VERSION}..."
    tmp="$(mktemp -d)"
    curl -fsSL "$TCC_URL" -o "$tmp/$TCC_TARBALL"
    tar -C "$tmp" -xjf "$tmp/$TCC_TARBALL"
    cp -a "$tmp/tcc-${TCC_VERSION}/"* "$TCC_DIR/"
    rm -rf "$tmp"
fi

if [ ! -f "$TCC_DIR/config.h" ]; then
    echo "Configuring TinyCC..."
    (cd "$TCC_DIR" && ./configure --enable-static)
fi

echo "Building OwOS libc..."
"$ROOT/toolchain/build.sh" libc-only

echo "Building TinyCC for OwOS..."
$CC "${CFLAGS[@]}" -c "$TCC_DIR/tcc.c" -o "$OUT/tcc.o"
$CC "${LDFLAGS[@]}" -o "$OUT/tcc.elf" "$OUT/tcc.o" "$OUT/libc.a"
$OBJCOPY -O binary -j .text -j .rodata -j .data -j .bss "$OUT/tcc.elf" "$OUT/tcc.raw"
python3 "$ROOT/toolchain/pack_bin.py" "$OUT/tcc.elf" "$OUT/tcc.bin"

echo "Wrote $OUT/tcc.bin ($(wc -c < "$OUT/tcc.bin") bytes)"