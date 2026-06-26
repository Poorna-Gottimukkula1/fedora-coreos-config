#!/bin/bash
# Manual kernel-replace test script with reboot logic
# Based on fedora-coreos-config/tests/kola/rpm-ostree/kernel-replace
# Run as root in the VM console

set -euxo pipefail

# Helper functions (from commonlib.sh)
ok() {
    echo "ok" "$@"
}

fatal() {
    echo "$@" >&2
    exit 1
}

# State file to track reboots
STATE_FILE="/var/lib/manual-kernel-test-state"

# Define OS ID
OS_ID=$(. /etc/os-release; echo $ID)
baseimage="localhost/coreos-base:latest"
imagespec="containers-storage:${baseimage}"
derivedimage="localhost/coreos-derived:latest"
derived_imagespec="containers-storage:${derivedimage}"
arch=$(arch)

build_base_image() {
    echo "=========================================="
    echo "Building base OCI archive"
    echo "=========================================="
    
    cd $(mktemp -d)
    rpm-ostree status --json > status.json
    checksum=$(jq -r '.deployments[0].checksum' < status.json)
    v0=$(jq -r '.deployments[0].version' < status.json)
    imgref=$(jq -r '.deployments[0]["container-image-reference"]' < status.json)
    rm -f ${baseimage}
    
    encapsulate_args=()
    if [[ "$imgref" != "null" ]]; then
      encapsulate_args+=("--label" "ostree.bootable=true")
    fi
    
    ostree container encapsulate "${encapsulate_args[@]}" --repo=/ostree/repo ${checksum} "${imagespec}"
    ok "Base OCI archive created at ${baseimage}"
}

build_derived_image() {
    echo "=========================================="
    echo "Downloading previous Fedora kernel"
    echo "=========================================="
    
    contextdir=$(mktemp -d)
    pushd ${contextdir}
    
    case "$OS_ID" in
      rhcos|scos|rhel|centos)
        c9s_mirror="https://mirror.stream.centos.org/9-stream/BaseOS/${arch}/os"
        dnf_opts="--repofrompath=tmp,${c9s_mirror} --disablerepo=* --enablerepo tmp"
        kver=$(dnf repoquery $dnf_opts kernel --qf '%{EVR}' | \
                  grep -v "$(rpm -q kernel --qf '%{EVR}')" | tail -n1)
        dnf download $dnf_opts --resolve kernel-{,core-,modules-,modules-core-,modules-extra-}$kver
        ;;
      fedora)
        VERSION_ID=$(. /etc/os-release; echo $VERSION_ID)
        previous_version_id=$((VERSION_ID - 1))
        printf "[main]\nskip_system_repo_lock=true\n" > dnf_config
        dnf download --config=dnf_config --releasever "${previous_version_id}" \
          --resolve --disablerepo=* --enablerepo=updates --enablerepo=fedora kernel
        kver=$(rpm -qp --qf '%{EVR}' ./kernel-core*rpm)
        ;;
      *)
        fatal "Unknown OS_ID: ${OS_ID}"
        ;;
    esac
    
    echo "$kver" > /var/kola-kernel.evr
    ok "Downloaded kernel version: $kver"
    
    echo "=========================================="
    echo "Building derived OCI archive with new kernel"
    echo "=========================================="
    
    cat > Containerfile << EOF
FROM $imagespec
RUN ls /etc/yum.repos.d/*.repo 2>/dev/null | xargs --no-run-if-empty sed -i s/enabled=1/enabled=0/
RUN rpm-ostree override replace /tmp/buildcontext/*rpm && \
    rpm-ostree cleanup -m && \
    echo "==== KERNEL PACKAGES ====" && \
    rpm -qa | grep '^kernel' && \
    echo "==== MODULES DIR ====" && \
    ls -1 /usr/lib/modules && \
    ostree container commit
EOF

    
    podman build --volume $PWD:/tmp/buildcontext:z -t "${derived_imagespec}" --squash .
    popd
    ok "Derived OCI archive created at ${derivedimage}"
}

# Read current state
if [ -f "$STATE_FILE" ]; then
    REBOOT_MARK=$(cat "$STATE_FILE")
else
    REBOOT_MARK=""
fi

case "${REBOOT_MARK}" in
  "")
    echo "=========================================="
    echo "BOOT 0: Initial setup"
    echo "=========================================="
    
    # Build base and derived OCI archives
    build_base_image
    build_derived_image
    
    # Turn off zincati
    systemctl mask --now zincati || true
    
    # Rebase a few times to test the mechanisms
    rpm-ostree rebase --experimental "ostree-unverified-image:${imagespec}"
    ostree container image list --repo=/ostree/repo | tee /tmp/imglist.txt
    
    # Test rebasing back to ostree
    cd $(mktemp -d)
    rpm-ostree status --json > status.json
    checksum=$(jq -r '.deployments[0].checksum' < status.json)
    rpm-ostree rebase "$checksum"
    rpm-ostree rebase "ostree-unverified-image:${imagespec}"
    
    # Save state for next boot
    echo "1" > "$STATE_FILE"
    
    echo ""
    echo "=========================================="
    echo "READY FOR REBOOT 1"
    echo "=========================================="
    echo "Run: systemctl reboot"
    systemctl reboot
    echo "After reboot, run this script again"
    ;;
    
  "1")
    echo "=========================================="
    echo "BOOT 1: Rebase to derived kernel"
    echo "=========================================="
    
    rpm-ostree --version
    rpm-ostree rebase "ostree-unverified-image:$derived_imagespec"
    ostree container image list --repo=/ostree/repo
    
    # Save state for next boot
    echo "2" > "$STATE_FILE"
    
    echo ""
    echo "=========================================="
    echo "READY FOR REBOOT 2"
    echo "=========================================="
    kver=$(cat /var/kola-kernel.evr)
    echo "Expected kernel after reboot: ${kver}.${arch}"
    echo "Current kernel: $(uname -r)"
    echo ""
    echo "Run: systemctl reboot"
    systemctl reboot
    echo "After reboot, run this script again to verify"
    ;;
    
  "2")
    echo "=========================================="
    echo "BOOT 2: Verify kernel switch"
    echo "=========================================="
    
    kver="$(cat /var/kola-kernel.evr).${arch}"
    un=$(uname -r)
    
    echo "Expected kernel: $kver"
    echo "Detected kernel: $un"
    
    if [ "$un" != "$kver" ]; then
      echo "❌ FAILURE: Expected kernel $kver but found $un"
      exit 1
    else
      echo "✅ SUCCESS: Kernel switch to $un was successful"
    fi
    
    # Verify kernel files exist
    if [ ! -f "/usr/lib/modules/$kver/initramfs.img" ]; then
      echo "❌ FAILURE: initramfs.img not found"
      exit 1
    fi
    
    if [ ! -f "/usr/lib/modules/$kver/vmlinuz" ]; then
      echo "❌ FAILURE: vmlinuz not found"
      exit 1
    fi
    
    echo "✅ All kernel files verified"
    
    # Clean up state file
    rm -f "$STATE_FILE"
    
    echo ""
    echo "=========================================="
    echo "TEST COMPLETED SUCCESSFULLY!"
    echo "=========================================="
    ;;
    
  *)
    echo "Unknown state: ${REBOOT_MARK}"
    exit 1
    ;;
esac

# Made with Bob
