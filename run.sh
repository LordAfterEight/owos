make
./make_iso.sh
qemu-system-x86_64 -m 2G -cdrom owos-c.iso -audiodev pa,id=speaker -machine pcspk-audiodev=speaker # -d int,cpu_reset,guest_errors
