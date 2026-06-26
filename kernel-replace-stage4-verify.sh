#!/bin/bash
# Stage 4: Verify kernel switch after reboot
# Run this after rebooting from Stage 3

set -euxo pipefail

# Helper functions
ok() {
    echo "ok" "$@"
}

fatal() {
    echo "$@" >&2
    exit 1
}

# Memory monitoring function
check_memory() {
    echo "=========================================="
    echo "MEMORY STATUS"
    echo "=========================================="
    free -h
    echo ""
    df -h /var/tmp
    echo "=========================================="
}

# Check initial memory
echo "Post-reboot system state:"
check_memory

arch=$(arch)

# Verify kernel version file exists
if [ ! -f "/var/kola-kernel.evr" ]; then
    fatal "Kernel version file not found. Did you run the previous stages?"
fi

echo "=========================================="
echo "STAGE 4: Verify kernel switch"
echo "=========================================="

kver="$(cat /var/kola-kernel.evr).${arch}"
un=$(uname -r)

echo "Expected kernel: $kver"
echo "Detected kernel: $un"
echo ""

if [ "$un" != "$kver" ]; then
  echo "❌ FAILURE: Expected kernel $kver but found $un"
  echo ""
  echo "Current deployment status:"
  rpm-ostree status
  exit 1
else
  echo "✅ SUCCESS: Kernel switch to $un was successful"
fi

echo ""
echo "Verifying kernel files..."

# Verify kernel files exist
if [ ! -f "/usr/lib/modules/$kver/initramfs.img" ]; then
  echo "❌ FAILURE: initramfs.img not found at /usr/lib/modules/$kver/initramfs.img"
  exit 1
else
  echo "✅ Found: /usr/lib/modules/$kver/initramfs.img"
  ls -lh "/usr/lib/modules/$kver/initramfs.img"
fi

if [ ! -f "/usr/lib/modules/$kver/vmlinuz" ]; then
  echo "❌ FAILURE: vmlinuz not found at /usr/lib/modules/$kver/vmlinuz"
  exit 1
else
  echo "✅ Found: /usr/lib/modules/$kver/vmlinuz"
  ls -lh "/usr/lib/modules/$kver/vmlinuz"
fi

echo ""
echo "All kernel files verified successfully"

echo ""
echo "Current deployment status:"
rpm-ostree status

echo ""
echo "Kernel modules directory:"
ls -lh /usr/lib/modules/

echo ""
check_memory

echo ""
echo "=========================================="
echo "TEST COMPLETED SUCCESSFULLY!"
echo "=========================================="
echo "Kernel version: $kver"
echo "All verifications passed ✅"
echo ""
echo "Optional cleanup:"
echo "  rm -f /var/kola-kernel.evr"
echo "  rm -f /var/tmp/coreos*.ociarchive"
echo "=========================================="

# Made with Bob
