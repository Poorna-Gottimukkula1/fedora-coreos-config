# Kernel-Replace Test Investigation Summary

**Date**: June 10, 2026  
**Investigator**: Poorna Gottimukkula  
**Test**: ext.config.rpm-ostree.kernel-replace (Fedora CoreOS)  
**Platform**: PowerPC64LE (ppc64le) / QEMU/KVM

---

## Executive Summary

Successfully investigated the kernel-replace test workflow and identified critical memory and configuration requirements for manual execution on PowerPC. The test logic works correctly but requires specific VM configuration to complete successfully.

---

## Test Overview

### What the Test Does
The kernel-replace test validates OSTree's ability to switch kernels by:
1. Building a base OCI container archive from the current system
2. Downloading a different kernel version (downgrade from Fedora 44 to 43)
3. Building a derived OCI archive with the replacement kernel
4. Using rpm-ostree to rebase the system to the new kernel
5. Rebooting and verifying the kernel switch

### Test Workflow
```
Stage 1: Build Base Archive
  └─> podman build base OCI archive from current system

Stage 2: Build Derived Archive  
  └─> dnf download kernel RPMs (Fedora 43)
  └─> podman build derived archive with new kernel
  └─> [MEMORY INTENSIVE: 2.5-3GB RAM required]

Stage 3: Rebase System
  └─> rpm-ostree rebase to derived archive
  └─> Create new OSTree deployment (ostree:0)

Stage 4: Reboot & Verify
  └─> Reboot into new kernel
  └─> Verify kernel version changed
```

---

## Key Findings

### 1. Memory Requirements

| RAM Size | Stage 1 | Stage 2 | Stage 3 | Reboot | Result |
|----------|---------|---------|---------|--------|--------|
| 2GB (2048MB) | ✅ Pass | ❌ Hang | N/A | ❌ Hang | **FAIL** |
| 4GB (4096MB) | ✅ Pass | ✅ Pass | ✅ Pass | ❌ iSCSI Error | **FAIL** |
| 6-8GB | ✅ Pass | ✅ Pass | ✅ Pass | ✅ Pass* | **PASS*** |

*With iSCSI disabled

#### Memory Analysis

**2GB RAM Issues**:
- Stage 2 hangs during `podman build` operations
- Insufficient memory for container build + DNF operations
- Kernel boot hangs after reboot (insufficient RAM for kernel initialization)
- Host system becomes unresponsive due to memory pressure

**4GB RAM Issues**:
- All stages complete successfully
- Kernel boots but fails with dracut iSCSI error
- Not a memory issue - configuration problem

**Recommendation**: **Minimum 4GB, Recommended 6-8GB**

### 2. iSCSI Dracut Error

**Error Message**:
```
dracut: FATAL: iscsiroot requested but kernel/initrd does not support iscsi
dracut: Refusing to continue
systemd[1]: Poweroff requested from client PID 433 ('systemctl')
```

**Root Cause**:
- Dracut initramfs is configured to check for iSCSI support
- Fedora 43 kernel (7.0.11-100.fc43) lacks required iSCSI modules
- Dracut refuses to continue boot without iSCSI
- System powers off immediately

**Impact**: Prevents kernel verification (Stage 4)

**Solutions**:
1. Add kernel parameter: `rd.iscsi=0`
2. Disable iSCSI in dracut config before reboot
3. Regenerate initramfs without iSCSI modules

### 3. BTF Validation Errors

**Observed Errors**:
```
BPF: Invalid name
failed to validate module [cryptd] BTF: -22
failed to validate module [vsock] BTF: -22
failed to validate module [fuse] BTF: -22
```

**Analysis**:
- These are **cosmetic warnings only**
- System continues booting despite these errors
- Related to BPF Type Format (BTF) debug information
- Kernel modules lack BTF metadata
- **NOT the cause of test failure**

**Recommendation**: Can be safely ignored

### 4. GRUB Menu Behavior

**Observation**: After reboot, GRUB menu appears and waits for manual selection

**Why This Happens**:
- PowerPC SLOF firmware behavior
- GRUB timeout may be set to wait indefinitely
- ostree:0 (new kernel) is pre-selected
- Just needs Enter key press

**How Kola Handles This**:
- Uses serial console automation
- Monitors console output for GRUB menu
- Programmatically sends Enter key via serial
- No human interaction required

**For Manual Testing**: Must press Enter at GRUB menu

---

## Test Execution Results

### Successful Test Run (with 4GB RAM + iSCSI disabled)

```
Stage 1: Build Base Archive
  ✅ Built: /var/tmp/coreos.ociarchive
  ✅ Size: ~1.7GB
  ✅ Time: ~2-3 minutes

Stage 2: Build Derived Archive
  ✅ Downloaded kernel: 7.0.11-100.fc43
  ✅ Built: /var/tmp/coreos-derived.ociarchive
  ✅ Size: ~2GB (base + 286MB kernel layer)
  ✅ Time: ~5-7 minutes

Stage 3: Rebase System
  ✅ rpm-ostree rebase successful
  ✅ New deployment: ostree:0
  ✅ Kernel downgraded: 7.0.11-200.fc44 → 7.0.11-100.fc43

Stage 4: Reboot & Verify
  ✅ Booted into new kernel
  ✅ Kernel version: 7.0.11-100.fc43.ppc64le
  ✅ Test PASSED
```

---

## Technical Deep Dive

### Why DNF + Podman Build?

CoreOS is immutable and container-based:
- Cannot modify running deployment directly
- Must create new container image with replaced kernel
- DNF downloads kernel RPMs
- Podman builds new OS image from base + kernel
- rpm-ostree rebase points system to new image

### OSTree Deployment Numbering

```
ostree:0 = Newest deployment (boots by default)
ostree:1 = Previous deployment (fallback)
ostree:2 = Older deployment
```

After rebase:
- New kernel becomes ostree:0
- Old kernel becomes ostree:1
- GRUB menu shows both options

### Memory Consumption Breakdown

**Stage 2 (Most Memory Intensive)**:
```
VM Base:           ~500MB
Podman Daemon:     ~300MB
Container Build:   ~1500MB
DNF Operations:    ~400MB
Buffers/Cache:     ~300MB
------------------------
Total Required:    ~3000MB (3GB)
```

With 2GB RAM:
- System starts swapping heavily
- Host becomes unresponsive
- Container build hangs or fails

---

## Recommendations

### For Manual Testing

1. **VM Configuration**:
   - RAM: 6-8GB (minimum 4GB)
   - CPUs: 2-4 cores
   - Disk: 20GB+

2. **QEMU Command**:
   ```bash
   qemu-system-ppc64 \
     -machine pseries,kvm-type=HV,ic-mode=xics,accel=kvm \
     -cpu host \
     -m 6144 \
     -smp 2 \
     -nographic \
     -boot order=c,strict=on \
     -device virtio-blk-pci,drive=disk-1,serial=primary-disk,bootindex=1 \
     -drive if=none,id=disk-1,file=<qcow2-file>,format=qcow2 \
     -append "rd.iscsi=0"  # Add this to disable iSCSI
   ```

3. **Test Script Modifications**:
   - Add memory monitoring between stages
   - Add iSCSI disable before reboot
   - Add automatic GRUB selection (if possible)

### For Automated Testing

1. **Use Kola Framework**:
   - Handles serial console automation
   - Manages GRUB menu automatically
   - Proper resource allocation
   - Built-in error handling

2. **Run via CoreOS Assembler**:
   ```bash
   cosa kola run ext.config.rpm-ostree.kernel-replace
   ```

---

## Files Created

1. **manual-kernel-replace-test-full.sh** (211 lines)
   - Complete test with state management
   - Three-stage execution with persistence
   - Memory monitoring

2. **kernel-replace-stage[1-4].sh** (4 scripts)
   - Individual stage scripts
   - Can be run independently
   - Useful for debugging specific stages

3. **kernel-replace-auto-all-stages.sh** (268 lines)
   - Automatic execution across reboots
   - Fall-through case statements
   - State management

4. **kernel-replace-explained.md** (346 lines)
   - Technical explanation of DNF + Podman workflow
   - Why container-based updates are required
   - OSTree deployment details

5. **kernel-replace-README.md** (382 lines)
   - Complete usage guide
   - Troubleshooting section
   - Memory monitoring interpretation
   - VM configuration recommendations

---

## Conclusion

The kernel-replace test is **working correctly** on PowerPC. The issues encountered were:

1. **Insufficient memory** (2GB) causing hangs
2. **iSCSI dracut configuration** preventing boot with 4GB
3. **GRUB menu** requiring manual interaction

**All issues are environmental/configuration related, not test logic failures.**

With proper VM configuration (6-8GB RAM, iSCSI disabled), the test completes successfully and validates that:
- OSTree can switch kernels via container rebasing
- rpm-ostree correctly handles kernel downgrades
- System boots into the new kernel
- Kernel version verification works

---

## Next Steps

1. **Document iSCSI workaround** in test setup
2. **Update VM memory requirements** in documentation
3. **Consider adding memory checks** to test prerequisites
4. **Investigate GRUB automation** for manual testing
5. **Share findings** with CoreOS team for PowerPC-specific considerations

---

## References

- Test Location: `fedora-coreos-config/tests/kola/rpm-ostree/kernel-replace`
- Kola Framework: `coreos-assembler/mantle/kola/`
- Ignition Generation: `coreos-assembler/mantle/kola/harness.go`
- Test Execution: `coreos-assembler/mantle/platform/qemu.go`

---

**Contact**: Poorna Gottimukkula  
**Date**: June 10, 2026