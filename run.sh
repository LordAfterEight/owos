./build.sh
qemu-system-x86_64 \
    -cdrom owos.iso \
    -serial stdio \
    -m 8G \
    -nodefaults \
    -vga virtio \
    -smp 4 \
    -accel tcg,tb-size=512 \
    # -enable-kvm -cpu host -machine q35,accel=kvm