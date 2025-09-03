# Create the disk
qemu-img create -f raw ubuntu-arm64.raw 100G

# Initialize and launch into qemu
qemu-system-aarch64 \
  -accel hvf -cpu host -M virt -m 16384 -smp 8 \
  -drive if=pflash,format=raw,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd,readonly=on \
  -drive file=ubuntu-arm64.raw,if=virtio,format=raw \
  -drive file=./ubuntu-24.04.3-live-server-arm64.iso,media=cdrom,if=virtio \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -nographic \
  -serial mon:stdio
