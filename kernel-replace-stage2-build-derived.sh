#!/bin/bash
# Stage 2: Download kernel and build derived OCI archive
# Run this after Stage 1 completes (or after reboot)

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
    echo ""
    echo "Podman info:"
    podman info --format "{{.Store.GraphRoot}}: {{.Store.GraphStatus}}" 2>/dev/null || echo "Podman info unavailable"
    echo "=========================================="
}

# Check initial memory
echo "Initial system state:"
check_memory

# Define variables
OS_ID=$(. /etc/os-release; echo $ID)
imagepath=/var/tmp/coreos.ociarchive
imagespec="oci-archive:${imagepath}"
derived_imagepath=/var/tmp/coreos-derived.ociarchive
derived_imagespec="oci-archive:${derived_imagepath}"
arch=$(arch)

# Verify base archive exists
if [ ! -f "$imagepath" ]; then
    fatal "Base OCI archive not found at $imagepath. Run stage1 first!"
fi

echo "=========================================="
echo "STAGE 2: Downloading previous Fedora kernel"
echo "=========================================="

contextdir=$(mktemp -d)
echo "Working directory: $contextdir"
pushd ${contextdir}

case "$OS_ID" in
  rhcos|scos|rhel|centos)
    echo "Downloading CentOS Stream kernel..."
    c9s_mirror="https://mirror.stream.centos.org/9-stream/BaseOS/${arch}/os"
    dnf_opts="--repofrompath=tmp,${c9s_mirror} --disablerepo=* --enablerepo tmp"
    kver=$(dnf repoquery $dnf_opts kernel --qf '%{EVR}' | \
              grep -v "$(rpm -q kernel --qf '%{EVR}')" | tail -n1)
    
    echo "Kernel version to download: $kver"
    echo ""
    echo "Memory before download:"
    check_memory
    
    dnf download $dnf_opts --resolve kernel-{,core-,modules-,modules-core-,modules-extra-}$kver
    ;;
    
  fedora)
    echo "Downloading Fedora kernel..."
    VERSION_ID=$(. /etc/os-release; echo $VERSION_ID)
    previous_version_id=$((VERSION_ID - 1))
    echo "Current Fedora version: $VERSION_ID"
    echo "Downloading from Fedora $previous_version_id"
    
    printf "[main]\nskip_system_repo_lock=true\n" > dnf_config
    
    echo ""
    echo "Memory before download:"
    check_memory
    
    dnf download --config=dnf_config --releasever "${previous_version_id}" \
      --resolve --disablerepo=* --enablerepo=updates --enablerepo=fedora kernel
    kver=$(rpm -qp --qf '%{EVR}' ./kernel-core*rpm)
    ;;
    
  *)
    fatal "Unknown OS_ID: ${OS_ID}"
    ;;
esac

echo ""
echo "Memory after download:"
check_memory

echo "$kver" > /var/kola-kernel.evr
ok "Downloaded kernel version: $kver"

echo ""
echo "Downloaded RPMs:"
ls -lh *.rpm

echo ""
echo "=========================================="
echo "STAGE 2: Building derived OCI archive"
echo "=========================================="

cat > Containerfile << EOF
FROM $imagespec
RUN ls /etc/yum.repos.d/*.repo 2>/dev/null | xargs --no-run-if-empty sed -i s/enabled=1/enabled=0/
RUN rpm-ostree override replace /tmp/buildcontext/*rpm && \
    rpm-ostree cleanup -m && \
    ostree container commit
EOF

echo "Containerfile contents:"
cat Containerfile

echo ""
echo "Memory before podman build:"
check_memory

echo ""
echo "Starting podman build (this may take several minutes)..."
echo "Build command: podman build --volume $PWD:/tmp/buildcontext:z -t ${derived_imagespec} --squash ."

# Run podman build with progress
podman build --volume $PWD:/tmp/buildcontext:z -t "${derived_imagespec}" --squash .

popd

echo ""
echo "Memory after podman build:"
check_memory

ok "Derived OCI archive created at ${derived_imagepath}"

echo ""
echo "Archive sizes:"
echo "  Base:    $(du -h ${imagepath} | cut -f1)"
echo "  Derived: $(du -h ${derived_imagepath} | cut -f1)"

# Cleanup build context to free space
echo ""
echo "Cleaning up build context..."
rm -rf ${contextdir}

echo ""
echo "Final memory status:"
check_memory

echo ""
echo "=========================================="
echo "STAGE 2 COMPLETE"
echo "=========================================="
echo "Derived OCI archive: ${derived_imagepath}"
echo "Kernel version: $kver"
echo ""
echo "Next step: Run kernel-replace-stage3-rebase.sh"
echo "=========================================="

# Made with Bob
