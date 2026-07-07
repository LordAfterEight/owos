#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBC="$ROOT/libc"
OUT="$LIBC/out"
mkdir -p "$OUT"

CC="${CC:-gcc}"
AR="${AR:-ar}"
OBJCOPY="${OBJCOPY:-objcopy}"

CFLAGS=(
    -mcmodel=large
    -ffreestanding
    -fno-stack-protector
    -fno-pic
    -mno-red-zone
    -fcf-protection=none
    -nostdlib
    -static
    -I"$LIBC/include"
)

LDFLAGS=(
    -nostdlib
    -static
    -T"$LIBC/link.ld"
)

build_libc() {
    echo "Building OwOS libc..."
    $CC "${CFLAGS[@]}" -c "$LIBC/crt0.S" -o "$OUT/crt0.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/kapi.c" -o "$OUT/kapi.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/errno.c" -o "$OUT/errno.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/unistd.c" -o "$OUT/unistd.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/stdlib.c" -o "$OUT/stdlib.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/string.c" -o "$OUT/string.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/stdio.c" -o "$OUT/stdio.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/setjmp.S" -o "$OUT/setjmp.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/math.c" -o "$OUT/math.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/assert.c" -o "$OUT/assert.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/owos_stubs.c" -o "$OUT/owos_stubs.o"
    $CC "${CFLAGS[@]}" -c "$LIBC/owos_print.c" -o "$OUT/owos_print.o"
    $AR rcs "$OUT/libc.a" \
        "$OUT/crt0.o" \
        "$OUT/kapi.o" \
        "$OUT/errno.o" \
        "$OUT/unistd.o" \
        "$OUT/stdlib.o" \
        "$OUT/string.o" \
        "$OUT/stdio.o" \
        "$OUT/setjmp.o" \
        "$OUT/math.o" \
        "$OUT/assert.o" \
        "$OUT/owos_stubs.o" \
        "$OUT/owos_print.o"
}

build_hello() {
    echo "Building hello..."
    $CC "${CFLAGS[@]}" -c "$LIBC/hello.c" -o "$OUT/hello.o"
    $CC "${LDFLAGS[@]}" -o "$OUT/hello.elf" "$OUT/hello.o" "$OUT/libc.a"
    $OBJCOPY -O binary -j .text -j .rodata -j .data -j .bss "$OUT/hello.elf" "$OUT/hello.raw"
    python3 "$ROOT/toolchain/pack_bin.py" "$OUT/hello.elf" "$OUT/hello.bin"
}

case "${1:-all}" in
    libc-only)
        build_libc
        ;;
    hello-only)
        build_hello
        ;;
    all)
        build_libc
        build_hello
        echo "Wrote $OUT/libc.a and $OUT/hello.bin"
        ;;
    *)
        echo "usage: $0 [all|libc-only|hello-only]" >&2
        exit 1
        ;;
esac