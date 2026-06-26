#!/bin/bash
# Complete kernel-replace test - Auto-runs all stages with reboots
# This script is injected via Ignition and runs automatically
# Manages state across reboots to execute all 4 stages sequentially

set -euxo pipefail

# Helper functions
ok() {
    echo "ok" "$@"
}

fatal() {
    echo "$@" >&2
    exit 1
}

check_memory() {
    echo "=========================================="
    echo "MEMORY STATUS"
    echo "=========================================="
    free -h
    echo ""
    df -h /var/tmp
    echo "=========================================="
}

# State file to track progress
STATE_FILE="/var/lib/kernel-test-state"
LOG_FILE="/var/log/kernel-test.log"

# Redirect all output to log file and console
exec > >(tee -a "$LOG_FILE") 2>&1

# Read current state
if [ -f "$STATE_FILE" ]; then
    CURRENT_STAGE=$(cat "$STATE_FILE")
else
    CURRENT_STAGE="0"
fi

echo "=========================================="
echo "Kernel Replace Test - Auto All Stages"
echo "Stage: $CURRENT_STAGE"
echo "Time: $(date)"
echo "=========================================="

# Define variables
OS_ID=$(. /etc/os-release; echo $ID)
imagepath=/var/tmp/coreos.ociarchive
imagespec="oci-archive:${imagepath}"
derived_imagepath=/var/tmp/coreos-derived.ociarchive
derived_imagespec="oci-archive:${derived_imagepath}"
arch=$(arch)

case "$CURRENT_STAGE" in
    "0")
        echo "=========================================="
        echo "STAGE 1: Build base OCI archive"
        echo "=========================================="
        
        check_memory
        
        cd $(mktemp -d)
        rpm-ostree status --json > status.json
        checksum=$(jq -r '.deployments[0].checksum' < status.json)
        v0=$(jq -r '.deployments[0].version' < status.json)
        imgref=$(jq -r '.deployments[0]["container-image-reference"]' < status.json)
        
        echo "Current deployment: $v0 ($checksum)"
        
        rm -f ${imagepath}
        
        encapsulate_args=()
        if [[ "$imgref" != "null" ]]; then
          encapsulate_args+=("--label" "ostree.bootable=true")
        fi
        
        ostree container encapsulate "${encapsulate_args[@]}" --repo=/ostree/repo ${checksum} "${imagespec}"
        ok "Base OCI archive created"
        
        systemctl mask --now zincati || true
        
        rpm-ostree rebase --experimental "ostree-unverified-image:${imagespec}"
        ostree container image list --repo=/ostree/repo
        
        cd $(mktemp -d)
        rpm-ostree status --json > status.json
        checksum=$(jq -r '.deployments[0].checksum' < status.json)
        rpm-ostree rebase "$checksum"
        rpm-ostree rebase "ostree-unverified-image:${imagespec}"
        
        check_memory
        
        # Move to next stage
        echo "1" > "$STATE_FILE"
        
        echo ""
        echo "Stage 1 complete. Proceeding to Stage 2..."
        echo ""
        
        # Continue to Stage 2 without reboot
        CURRENT_STAGE="1"
        ;&  # Fall through to next case
        
    "1")
        echo "=========================================="
        echo "STAGE 2: Download kernel and build derived"
        echo "=========================================="
        
        check_memory
        
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
        ok "Downloaded kernel: $kver"
        
        cat > Containerfile << 'EOF'
FROM $imagespec
RUN ls /etc/yum.repos.d/*.repo 2>/dev/null | xargs --no-run-if-empty sed -i s/enabled=1/enabled=0/
RUN rpm-ostree override replace /tmp/buildcontext/*rpm && \
    rpm-ostree cleanup -m && \
    ostree container commit
EOF
        
        # Substitute imagespec in Containerfile
        sed -i "s|\$imagespec|$imagespec|g" Containerfile
        
        echo "Building derived OCI archive..."
        podman build --volume $PWD:/tmp/buildcontext:z -t "${derived_imagespec}" --squash .
        
        popd
        rm -rf ${contextdir}
        
        check_memory
        ok "Derived OCI archive created"
        
        # Move to next stage
        echo "2" > "$STATE_FILE"
        
        echo ""
        echo "Stage 2 complete. Proceeding to Stage 3..."
        echo ""
        
        # Continue to Stage 3 without reboot
        CURRENT_STAGE="2"
        ;&  # Fall through to next case
        
    "2")
        echo "=========================================="
        echo "STAGE 3: Rebase to derived kernel"
        echo "=========================================="
        
        check_memory
        
        rpm-ostree --version
        rpm-ostree rebase "ostree-unverified-image:$derived_imagespec"
        ostree container image list --repo=/ostree/repo
        
        check_memory
        
        # Move to next stage
        echo "3" > "$STATE_FILE"
        
        kver=$(cat /var/kola-kernel.evr)
        echo ""
        echo "=========================================="
        echo "Stage 3 complete. Rebooting to new kernel..."
        echo "Expected kernel: ${kver}.${arch}"
        echo "=========================================="
        
        # Reboot to boot into new kernel
        systemctl reboot
        ;;
        
    "3")
        echo "=========================================="
        echo "STAGE 4: Verify kernel switch"
        echo "=========================================="
        
        check_memory
        
        kver="$(cat /var/kola-kernel.evr).${arch}"
        un=$(uname -r)
        
        echo "Expected kernel: $kver"
        echo "Detected kernel: $un"
        
        if [ "$un" != "$kver" ]; then
          echo "❌ FAILURE: Expected $kver but found $un"
          rpm-ostree status
          exit 1
        else
          echo "✅ SUCCESS: Kernel switch to $un successful"
        fi
        
        if [ ! -f "/usr/lib/modules/$kver/initramfs.img" ]; then
          echo "❌ FAILURE: initramfs.img not found"
          exit 1
        else
          echo "✅ Found: /usr/lib/modules/$kver/initramfs.img"
        fi
        
        if [ ! -f "/usr/lib/modules/$kver/vmlinuz" ]; then
          echo "❌ FAILURE: vmlinuz not found"
          exit 1
        else
          echo "✅ Found: /usr/lib/modules/$kver/vmlinuz"
        fi
        
        echo ""
        echo "All kernel files verified"
        
        rpm-ostree status
        check_memory
        
        # Clean up state file
        rm -f "$STATE_FILE"
        
        echo ""
        echo "=========================================="
        echo "ALL STAGES COMPLETED SUCCESSFULLY!"
        echo "=========================================="
        echo "Kernel version: $kver"
        echo "Test log: $LOG_FILE"
        echo ""
        echo "Optional cleanup:"
        echo "  rm -f /var/kola-kernel.evr"
        echo "  rm -f /var/tmp/coreos*.ociarchive"
        echo "=========================================="
        ;;
        
    *)
        echo "Unknown stage: $CURRENT_STAGE"
        exit 1
        ;;
esac

# Made with Bob
