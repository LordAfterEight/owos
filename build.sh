#!/bin/bash
set -e

# Cleanup
cargo clean
rm -rf iso_root owos.iso

# Build kernel
cargo build --release

# Get Limine if not already present
if [ ! -d limine ]; then
    git clone https://github.com/limine-bootloader/limine --branch=v8.x-binary --depth=1
    make -C limine
fi

# Create ISO directory structure
rm -rf iso_root
mkdir -p iso_root/boot/limine iso_root/EFI/BOOT

# Copy kernel
cp target/x86_64-unknown-none/release/owos iso_root/boot/

# Copy Limine files
cp limine/limine-bios.sys limine/limine-bios-cd.bin iso_root/boot/limine/
cp limine/BOOTX64.EFI iso_root/EFI/BOOT/

# Write Limine config
cat > iso_root/boot/limine/limine.conf << 'EOF'
timeout: 0
interface_resolution: 1920x1080

/owos
    resolution: 1920x1080
    protocol: limine
    kernel_path: boot():/boot/owos
EOF

# Build ISO
xorriso -as mkisofs -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot EFI/BOOT/BOOTX64.EFI -efi-boot-part \
    --efi-boot-image --protective-msdos-label \
    iso_root -o owos.iso

# Install Limine BIOS stages
./limine/limine bios-install owos.iso

echo "Done! Run with: qemu-system-x86_64 -cdrom owos.iso -serial stdio"
