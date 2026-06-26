# Kernel Replace Test - Technical Explanation

## Overview

The kernel-replace test validates that Fedora CoreOS can **replace its kernel** using container-based updates. This is a critical feature for security updates, bug fixes, and kernel downgrades.

## Why DNF Download + Podman Build?

### The Two-Step Process

```
┌─────────────────────────────────────────────────────────────┐
│ Step 1: DNF Download                                        │
│ Purpose: Get kernel RPMs from Fedora repository             │
├─────────────────────────────────────────────────────────────┤
│ dnf download --releasever 43 kernel                         │
│   ↓                                                          │
│ Downloads:                                                   │
│   - kernel-7.0.11-100.fc43.ppc64le.rpm                      │
│   - kernel-core-7.0.11-100.fc43.ppc64le.rpm                 │
│   - kernel-modules-7.0.11-100.fc43.ppc64le.rpm              │
│   - kernel-modules-core-7.0.11-100.fc43.ppc64le.rpm         │
└─────────────────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 2: Podman Build                                        │
│ Purpose: Create new OS image with replaced kernel           │
├─────────────────────────────────────────────────────────────┤
│ FROM base-image                                             │
│ RUN rpm-ostree override replace /tmp/buildcontext/*rpm     │
│   ↓                                                          │
│ Creates new OCI archive with:                               │
│   - Old kernel removed (7.0.11-200.fc44)                    │
│   - New kernel installed (7.0.11-100.fc43)                  │
│   - New initramfs generated                                 │
│   - Bootloader updated                                      │
└─────────────────────────────────────────────────────────────┘
```

## Why Not Just `rpm-ostree override replace` Directly?

**Because CoreOS is immutable and container-based:**

```bash
# ❌ This won't work directly on running system:
rpm-ostree override replace kernel-*.rpm
# Error: Can't modify running deployment directly

# ✅ Must create new container image:
podman build → Creates new OS image → rpm-ostree rebase to it
```

### CoreOS Architecture Constraints

1. **Immutable Root Filesystem**: The root filesystem is read-only
2. **Container-Based Updates**: OS updates delivered as OCI container images
3. **Atomic Updates**: Changes applied atomically, not incrementally
4. **Staged Deployments**: New OS versions staged, activated on reboot

## The Complete Workflow

### Stage 1: Build Base OCI Archive

```bash
# Extract current deployment as OCI container
ostree container encapsulate --repo=/ostree/repo ${checksum} "${imagespec}"

# Result: /var/tmp/coreos.ociarchive
# This is the "base image" for the next step
```

**Purpose**: Create a container image from the current running system.

### Stage 2a: DNF Download

```bash
# Download kernel RPMs from Fedora 43 repository
VERSION_ID=$(. /etc/os-release; echo $VERSION_ID)  # Current: 44
previous_version_id=$((VERSION_ID - 1))            # Target: 43

dnf download --releasever 43 kernel
```

**Downloads**:
- `kernel-7.0.11-100.fc43.ppc64le.rpm` (meta-package)
- `kernel-core-7.0.11-100.fc43.ppc64le.rpm` (core kernel)
- `kernel-modules-7.0.11-100.fc43.ppc64le.rpm` (modules)
- `kernel-modules-core-7.0.11-100.fc43.ppc64le.rpm` (core modules)

**Why download?**
- Can't install directly on immutable system
- Need RPMs to inject into container build
- Simulates getting updates from repository

### Stage 2b: Podman Build

```bash
# Create Containerfile
cat > Containerfile << EOF
FROM oci-archive:/var/tmp/coreos.ociarchive
RUN ls /etc/yum.repos.d/*.repo 2>/dev/null | xargs --no-run-if-empty sed -i s/enabled=1/enabled=0/
RUN rpm-ostree override replace /tmp/buildcontext/*rpm && \
    rpm-ostree cleanup -m && \
    ostree container commit
EOF

# Build new container image
podman build --volume $PWD:/tmp/buildcontext:z \
             -t oci-archive:/var/tmp/coreos-derived.ociarchive \
             --squash .
```

**What happens inside the build**:

1. **FROM base image**: Starts with current CoreOS image
2. **Disable repos**: Prevents unwanted package updates
3. **rpm-ostree override replace**: Replaces kernel packages
   - Removes: `kernel-7.0.11-200.fc44` (current)
   - Installs: `kernel-7.0.11-100.fc43` (downgrade)
4. **Generate initramfs**: Creates boot files for new kernel
5. **Update bootloader**: Configures GRUB for new kernel
6. **Commit changes**: Finalizes new OS image
7. **Squash layers**: Optimizes image size

**Result**: `/var/tmp/coreos-derived.ociarchive` (new OS image with replaced kernel)

### Stage 3: Rebase to New Image

```bash
# Point system to new image
rpm-ostree rebase "ostree-unverified-image:oci-archive:/var/tmp/coreos-derived.ociarchive"

# Creates new deployment at ostree:0
# Old deployment moves to ostree:1
```

**What happens**:
- New deployment staged (not active yet)
- Bootloader updated to boot new deployment
- System ready for reboot

### Stage 4: Verify After Reboot

```bash
# After reboot, verify new kernel is running
kver="7.0.11-100.fc43.ppc64le"
un=$(uname -r)

if [ "$un" != "$kver" ]; then
  echo "❌ FAILURE: Expected $kver but found $un"
else
  echo "✅ SUCCESS: Kernel switch successful"
fi

# Verify kernel files exist
ls -l /usr/lib/modules/$kver/initramfs.img
ls -l /usr/lib/modules/$kver/vmlinuz
```

## Why This Tests Important Functionality

### 1. Container-Based Updates
CoreOS uses OCI containers for OS updates. This test validates:
- Container image creation from running system
- Container image modification (kernel replacement)
- System rebase to modified container image

### 2. Kernel Replacement
Critical for:
- **Security updates**: Apply kernel CVE fixes
- **Bug fixes**: Fix kernel bugs without full OS update
- **Compatibility**: Downgrade kernel for hardware/software compatibility

### 3. Downgrade Capability
Tests rollback scenarios:
- Downgrade from Fedora 44 kernel to Fedora 43 kernel
- Validates that older kernels can be installed
- Ensures initramfs generation works for older kernels

### 4. rpm-ostree Override Mechanism
Tests the `rpm-ostree override replace` command:
- Package replacement in immutable system
- Dependency resolution
- Initramfs regeneration
- Bootloader updates

### 5. Initramfs Generation
Ensures boot files are created correctly:
- `initramfs.img` generated for new kernel
- `vmlinuz` kernel binary present
- Bootloader configuration updated

## Example Output Analysis

```bash
# ✅ DNF download worked:
Downloading Packages:
 kernel-0:7.0.11-100.fc43.ppc64le                 100% | 557.8 KiB/s | 237.6 KiB
 kernel-core-0:7.0.11-100.fc43.ppc64le            100% |  17.3 MiB/s |  16.2 MiB
 kernel-modules-core-0:7.0.11-100.fc43.ppc64le    100% |  34.5 MiB/s |  31.7 MiB
 kernel-modules-0:7.0.11-100.fc43.ppc64le         100% |  29.7 MiB/s |  49.5 MiB

# ✅ Podman build worked:
STEP 3/3: RUN rpm-ostree override replace /tmp/buildcontext/*rpm
Installing 4 packages:
  kernel-7.0.11-100.fc43.ppc64le (@commandline)
  kernel-core-7.0.11-100.fc43.ppc64le (@commandline)
  kernel-modules-7.0.11-100.fc43.ppc64le (@commandline)
  kernel-modules-core-7.0.11-100.fc43.ppc64le (@commandline)

Downgrading: kernel-core;7.0.11-100.fc43;ppc64le;local
Downgrading: kernel-modules-core;7.0.11-100.fc43;ppc64le;local
Downgrading: kernel-modules;7.0.11-100.fc43;ppc64le;local
Downgrading: kernel;7.0.11-100.fc43;ppc64le;local

Cleanup: kernel;7.0.11-200.fc44;ppc64le;installed
Cleanup: kernel-modules;7.0.11-200.fc44;ppc64le;installed
Cleanup: kernel-core;7.0.11-200.fc44;ppc64le;installed
Cleanup: kernel-modules-core;7.0.11-200.fc44;ppc64le;installed

Generating initramfs  ← Critical: Boot files created

# Result: New OS image with Fedora 43 kernel ready to boot
```

## Key Concepts

### OSTree Deployments

```bash
# Before kernel replace:
* ostree:0  ← Current (7.0.11-200.fc44) - booted
  ostree:1  ← Previous deployment

# After rpm-ostree rebase (before reboot):
  ostree:0  ← New (7.0.11-100.fc43) - staged
* ostree:1  ← Current (7.0.11-200.fc44) - still booted
  ostree:2  ← Previous deployment

# After reboot:
* ostree:0  ← New (7.0.11-100.fc43) - NOW BOOTED ✅
  ostree:1  ← Old (7.0.11-200.fc44) - rollback option
  ostree:2  ← Previous deployment
```

### OCI Archives

- **Base archive**: Current system as container image
- **Derived archive**: Modified system with new kernel
- **Format**: OCI (Open Container Initiative) standard
- **Storage**: `/var/tmp/coreos*.ociarchive`

### rpm-ostree Commands

```bash
# Create container from deployment
ostree container encapsulate --repo=/ostree/repo ${checksum} "${imagespec}"

# Replace packages in container (during build)
rpm-ostree override replace /tmp/buildcontext/*rpm

# Rebase system to new container
rpm-ostree rebase "ostree-unverified-image:${imagespec}"

# Check deployment status
rpm-ostree status
```

## Summary

**Why DNF + Podman?**

| Step | Tool | Purpose | Why Needed |
|------|------|---------|------------|
| Download | DNF | Get kernel RPMs | Can't install directly on immutable system |
| Build | Podman | Create new OS image | CoreOS requires container-based updates |
| Replace | rpm-ostree | Swap kernel packages | Handles dependencies and initramfs |
| Rebase | rpm-ostree | Point to new image | Stages new deployment for boot |
| Verify | uname/ls | Check kernel switch | Confirms test success |

**Together**: Simulates real-world kernel update/downgrade scenario and validates the entire container-based OS update mechanism that CoreOS uses in production.

## Related Files

- `kernel-replace-stage1-setup.sh` - Stage 1: Build base OCI archive
- `kernel-replace-stage2-build-derived.sh` - Stage 2: Download kernel and build derived image
- `kernel-replace-stage3-rebase.sh` - Stage 3: Rebase to new kernel
- `kernel-replace-stage4-verify.sh` - Stage 4: Verify kernel switch
- `kernel-replace-auto-all-stages.sh` - Auto-run all stages with state management
- `kernel-replace-README.md` - Complete usage guide

## References

- [Fedora CoreOS Documentation](https://docs.fedoraproject.org/en-US/fedora-coreos/)
- [OSTree Documentation](https://ostreedev.github.io/ostree/)
- [rpm-ostree Documentation](https://coreos.github.io/rpm-ostree/)
- [OCI Specification](https://github.com/opencontainers/image-spec)