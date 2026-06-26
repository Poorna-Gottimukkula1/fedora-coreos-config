#!/bin/bash
# Stage 3: Rebase to derived kernel
# Run this after Stage 2 completes

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
echo "Initial system state:"
check_memory

# Define variables
derived_imagepath=/var/tmp/coreos-derived.ociarchive
derived_imagespec="oci-archive:${derived_imagepath}"
arch=$(arch)

# Verify derived archive exists
if [ ! -f "$derived_imagepath" ]; then
    fatal "Derived OCI archive not found at $derived_imagepath. Run stage2 first!"
fi

# Verify kernel version file exists
if [ ! -f "/var/kola-kernel.evr" ]; then
    fatal "Kernel version file not found. Run stage2 first!"
fi

echo "=========================================="
echo "STAGE 3: Rebase to derived kernel"
echo "=========================================="

echo "Current rpm-ostree version:"
rpm-ostree --version

echo ""
echo "Current deployment status:"
rpm-ostree status

echo ""
echo "Memory before rebase:"
check_memory

echo ""
echo "Rebasing to derived image with new kernel..."
rpm-ostree rebase "ostree-unverified-image:$derived_imagespec"

echo ""
echo "Memory after rebase:"
check_memory

echo ""
echo "Container images in ostree repo:"
ostree container image list --repo=/ostree/repo

echo ""
echo "New deployment status:"
rpm-ostree status

echo ""
echo "=========================================="
echo "STAGE 3 COMPLETE"
echo "=========================================="
kver=$(cat /var/kola-kernel.evr)
echo "Expected kernel after reboot: ${kver}.${arch}"
echo "Current kernel: $(uname -r)"
echo ""
echo "Next step: Reboot the system"
echo "  Run: systemctl reboot"
echo ""
echo "After reboot, run: kernel-replace-stage4-verify.sh"
echo "=========================================="

# Made with Bob
