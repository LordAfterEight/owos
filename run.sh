#make
zig build
./make_iso.sh
qemu-system-x86_64 \
    -cdrom owos.iso \
    -serial stdio \
    #-d int,cpu_reset \
    #-D qemu.log \
    -no-reboot \
    -m 256M
