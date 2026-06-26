#!/bin/bash
# Manual kernel-replace test script
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

cd $(mktemp -d)

# Define OS ID
OS_ID=$(. /etc/os-release; echo $ID)
imagepath=/var/tmp/coreos.ociarchive
imagespec="oci-archive:${imagepath}"
derived_imagepath=/var/tmp/coreos-derived.ociarchive
derived_imagespec="oci-archive:${derived_imagepath}"
arch=$(arch)

echo "=========================================="
echo "STEP 1: Building base OCI archive"
echo "=========================================="

# Take the existing ostree commit, and export it to a container image/ociarchive
rpm-ostree status --json > status.json
checksum=$(jq -r '.deployments[0].checksum' < status.json)
v0=$(jq -r '.deployments[0].version' < status.json)
imgref=$(jq -r '.deployments[0]["container-image-reference"]' < status.json)
rm -f ${imagepath}

encapsulate_args=()
if [[ "$imgref" != "null" ]]; then
  encapsulate_args+=("--label" "ostree.bootable=true")
fi

ostree container encapsulate "${encapsulate_args[@]}" --repo=/ostree/repo ${checksum} "${imagespec}"
ok "Base OCI archive created at ${imagepath}"

echo ""
echo "=========================================="
echo "STEP 2: Downloading previous Fedora kernel"
echo "=========================================="

# Do the container build in a temporary context directory
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
    # Workaround https://github.com/coreos/fedora-coreos-tracker/issues/2113
    printf "[main]\nskip_system_repo_lock=true\n" > dnf_config
    dnf download --config=dnf_config --releasever "${previous_version_id}" \
      --resolve --disablerepo=* --enablerepo=updates --enablerepo=fedora kernel
    kver=$(rpm -qp --qf '%{EVR}' ./kernel-core*rpm)
    ;;
  *)
    fatal "Unknown OS_ID: ${OS_ID}"
    ;;
esac

# Save kernel version for later verification
echo "$kver" > /var/kola-kernel.evr
ok "Downloaded kernel version: $kver"
ls -lh kernel*.rpm

echo ""
echo "=========================================="
echo "STEP 3: Building derived OCI archive with new kernel"
echo "=========================================="

cat > Containerfile << EOF
FROM $imagespec
# Disable yum repos since we are overriding local files
RUN ls /etc/yum.repos.d/*.repo 2>/dev/null | xargs --no-run-if-empty sed -i s/enabled=1/enabled=0/
RUN rpm-ostree override replace /tmp/buildcontext/*rpm && \
    rpm-ostree cleanup -m && \
    ostree container commit
EOF

cat Containerfile
podman build --volume $PWD:/tmp/buildcontext:z -t "${derived_imagespec}" --squash .
popd
ok "Derived OCI archive created at ${derived_imagepath}"

echo ""
echo "=========================================="
echo "STEP 4: Rebasing to derived image"
echo "=========================================="

# Turn off zincati since we're switching OS update streams
systemctl mask --now zincati || true

# Rebase to the derived kernel-replaced image
rpm-ostree --version
rpm-ostree rebase "ostree-unverified-image:$derived_imagespec"
ostree container image list --repo=/ostree/repo

echo ""
echo "=========================================="
echo "READY TO REBOOT"
echo "=========================================="
echo "Current kernel: $(uname -r)"
echo "Expected kernel after reboot: ${kver}.${arch}"
echo ""
echo "To complete the test:"
echo "  1. Run: systemctl reboot"
echo "  2. After reboot, verify with: uname -r"
echo "  3. Expected output: ${kver}.${arch}"
echo ""
echo "To verify manually after reboot:"
echo "  kver=\"\$(cat /var/kola-kernel.evr).\$(arch)\""
echo "  un=\$(uname -r)"
echo "  if [ \"\$un\" = \"\$kver\" ]; then"
echo "    echo \"SUCCESS: Kernel switch to \$un was successful\""
echo "  else"
echo "    echo \"FAILURE: Expected kernel \$kver but found \$un\""
echo "  fi"

# Made with Bob
