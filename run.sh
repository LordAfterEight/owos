#make
zig build
./make_iso.sh
qemu-system-x86_64 \
    -cdrom owos.iso \
    -debugcon stdio \
    -d int,cpu_reset \
    -no-reboot \
    -D qemu.log \
    -m 256M
