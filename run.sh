#make
zig build
./make_iso.sh
qemu-system-x86_64 \
    -cdrom owos.iso \
    -serial stdio \
    -no-reboot \
    -m 2G \
    -device virtio-vga \
    -enable-kvm
    #-d int,cpu_reset \
    #-D qemu.log \
