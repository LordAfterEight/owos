#make
zig build
./make_iso.sh
sudo cp zig-out/bin/owos /boot/boot/
qemu-system-x86_64 \
    -cdrom owos.iso \
    -serial stdio \
    -no-reboot \
    -m 2G \
    #-d int,cpu_reset \
    #-D qemu.log \
