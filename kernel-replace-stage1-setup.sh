#!/bin/bash
# Stage 1: Build base OCI archive and setup
# Run this first in the VM console as root

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

# Define OS ID
OS_ID=$(. /etc/os-release; echo $ID)
imagepath=/var/tmp/coreos.ociarchive
imagespec="oci-archive:${imagepath}"
arch=$(arch)

echo "=========================================="
echo "STAGE 1: Building base OCI archive"
echo "=========================================="

cd $(mktemp -d)
rpm-ostree status --json > status.json
checksum=$(jq -r '.deployments[0].checksum' < status.json)
v0=$(jq -r '.deployments[0].version' < status.json)
imgref=$(jq -r '.deployments[0]["container-image-reference"]' < status.json)

echo "Current deployment:"
echo "  Version: $v0"
echo "  Checksum: $checksum"
echo "  Image ref: $imgref"

# Check memory before encapsulation
echo ""
echo "Memory before encapsulation:"
check_memory

rm -f ${imagepath}

encapsulate_args=()
if [[ "$imgref" != "null" ]]; then
  encapsulate_args+=("--label" "ostree.bootable=true")
fi

echo ""
echo "Running ostree container encapsulate..."
ostree container encapsulate "${encapsulate_args[@]}" --repo=/ostree/repo ${checksum} "${imagespec}"

# Check memory after encapsulation
echo ""
echo "Memory after encapsulation:"
check_memory

ok "Base OCI archive created at ${imagepath}"

# Turn off zincati
echo ""
echo "Disabling zincati..."
systemctl mask --now zincati || true

# Test rebase mechanisms
echo ""
echo "Testing rebase to container image..."
rpm-ostree rebase --experimental "ostree-unverified-image:${imagespec}"

echo ""
echo "Listing container images..."
ostree container image list --repo=/ostree/repo | tee /tmp/imglist.txt

# Test rebasing back to ostree
echo ""
echo "Testing rebase back to ostree..."
cd $(mktemp -d)
rpm-ostree status --json > status.json
checksum=$(jq -r '.deployments[0].checksum' < status.json)
rpm-ostree rebase "$checksum"

echo ""
echo "Rebasing back to container image..."
rpm-ostree rebase "ostree-unverified-image:${imagespec}"

# Final memory check
echo ""
echo "Final memory status:"
check_memory

echo ""
echo "=========================================="
echo "STAGE 1 COMPLETE"
echo "=========================================="
echo "Base OCI archive: ${imagepath}"
echo "Size: $(du -h ${imagepath} | cut -f1)"
echo ""
echo "Next step: Run kernel-replace-stage2-build-derived.sh"
echo "Or reboot first: systemctl reboot"
echo "=========================================="

# Made with Bob
