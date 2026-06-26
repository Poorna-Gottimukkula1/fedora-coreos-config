# Kernel Replace Test - Staged Execution with Memory Monitoring

This directory contains a staged version of the Fedora CoreOS kernel-replace test, broken down into individual scripts with memory monitoring at each step.

## Problem Analysis

The original monolithic test (`manual-kernel-replace-test-full.sh`) was experiencing crashes due to:
- **Memory pressure**: Building OCI archives and running podman builds are memory-intensive
- **Resource exhaustion**: Multiple concurrent operations competing for CPU/memory
- **Insufficient VM resources**: Original VM had only 2GB RAM

## Solution: Staged Execution

The test is now split into 4 independent stages, allowing you to:
- Monitor memory usage between stages
- Identify which stage causes resource issues
- Run stages with breaks to allow system recovery
- Adjust VM resources if needed

## Scripts Overview

### Stage 1: `kernel-replace-stage1-setup.sh`
**Purpose**: Build base OCI archive and test rebase mechanisms

**Operations**:
- Creates base OCI archive from current deployment
- Tests rebase to container image
- Tests rebase back to ostree
- Disables zincati auto-updates

**Memory Impact**: Medium (ostree encapsulation)

**Output**: `/var/tmp/coreos.ociarchive`

### Stage 2: `kernel-replace-stage2-build-derived.sh`
**Purpose**: Download previous kernel and build derived OCI archive

**Operations**:
- Downloads Fedora kernel from previous release (or CentOS Stream)
- Creates Containerfile with kernel override
- Builds derived OCI archive using podman
- Cleans up build context

**Memory Impact**: HIGH (podman build with squash)

**Output**: 
- `/var/tmp/coreos-derived.ociarchive`
- `/var/kola-kernel.evr` (kernel version file)

### Stage 3: `kernel-replace-stage3-rebase.sh`
**Purpose**: Rebase to derived kernel

**Operations**:
- Rebases system to derived OCI archive
- Lists container images in ostree repo
- Shows new deployment status

**Memory Impact**: Medium (rpm-ostree rebase)

**Output**: New deployment ready for reboot

### Stage 4: `kernel-replace-stage4-verify.sh`
**Purpose**: Verify kernel switch after reboot

**Operations**:
- Verifies running kernel matches expected version
- Checks kernel files (initramfs.img, vmlinuz)
- Shows final deployment status

**Memory Impact**: Low (verification only)

**Output**: Test success/failure status

## Usage Instructions

### Prerequisites

1. **Start VM with adequate resources**:
   ```bash
   # From coreos-assembler directory
   cosa run --qemu-image builds/latest/ppc64le/fedora-coreos-*.qcow2 \
            --memory 4096 \      # 4GB RAM (increased from 2GB)
            --vcpus 2 \          # 2 CPUs
            --devshell-console
   ```

2. **Copy scripts to VM**:
   ```bash
   # In VM console, create scripts directory
   mkdir -p /root/kernel-test
   cd /root/kernel-test
   
   # Copy the 4 stage scripts to this directory
   # (use scp, paste content, or mount shared directory)
   ```

3. **Make scripts executable**:
   ```bash
   chmod +x kernel-replace-stage*.sh
   ```

### Execution Steps

#### Step 1: Run Stage 1
```bash
cd /root/kernel-test
./kernel-replace-stage1-setup.sh
```

**What to watch**:
- Initial memory status
- Memory after ostree encapsulation
- Final memory status
- Archive size

**Expected output**: Base OCI archive created at `/var/tmp/coreos.ociarchive`

**Optional**: Reboot here if you want to start fresh for Stage 2
```bash
systemctl reboot
```

---

#### Step 2: Run Stage 2
```bash
cd /root/kernel-test
./kernel-replace-stage2-build-derived.sh
```

**What to watch**:
- Memory before kernel download
- Memory after download
- Memory before podman build (CRITICAL)
- Memory after podman build
- Archive sizes (base vs derived)

**Expected output**: Derived OCI archive created at `/var/tmp/coreos-derived.ociarchive`

**If this stage fails**:
- Check memory status: `free -h`
- Check disk space: `df -h /var/tmp`
- Consider increasing VM memory to 6GB or 8GB
- Try running after a reboot to clear caches

---

#### Step 3: Run Stage 3
```bash
cd /root/kernel-test
./kernel-replace-stage3-rebase.sh
```

**What to watch**:
- Memory before rebase
- Memory after rebase
- New deployment status

**Expected output**: System ready for reboot with new kernel deployment

**Required**: Reboot to boot into new kernel
```bash
systemctl reboot
```

---

#### Step 4: Run Stage 4 (After Reboot)
```bash
cd /root/kernel-test
./kernel-replace-stage4-verify.sh
```

**What to watch**:
- Post-reboot memory status
- Kernel version match
- Kernel files verification

**Expected output**: 
```
✅ SUCCESS: Kernel switch to 7.0.11-100.fc43.ppc64le was successful
✅ Found: /usr/lib/modules/7.0.11-100.fc43.ppc64le/initramfs.img
✅ Found: /usr/lib/modules/7.0.11-100.fc43.ppc64le/vmlinuz
TEST COMPLETED SUCCESSFULLY!
```

## Memory Monitoring

Each script includes `check_memory()` function that displays:
- **RAM usage**: `free -h` output
- **Disk space**: `/var/tmp` usage (where archives are stored)
- **Podman info**: Storage driver status (Stage 2 only)

### Interpreting Memory Output

**Good memory state**:
```
              total        used        free      shared  buff/cache   available
Mem:           3.8Gi       1.2Gi       1.8Gi        50Mi       800Mi       2.4Gi
```

**Memory pressure warning**:
```
              total        used        free      shared  buff/cache   available
Mem:           3.8Gi       3.2Gi       200Mi       50Mi       400Mi       400Mi
```
- Available < 500MB: Risk of OOM (Out of Memory)
- Consider stopping and increasing VM memory

**Disk space check**:
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda4        20G  8.5G   11G  44% /var
```
- Need at least 5GB free in `/var/tmp` for OCI archives

## Troubleshooting

### Stage 2 Fails with "Network error: Software caused connection abort"

**Cause**: Memory exhaustion during podman build

**Solutions**:
1. Increase VM memory to 6GB or 8GB
2. Reboot before running Stage 2 to clear caches
3. Run `podman system prune -a` to free podman storage
4. Check if other processes are consuming memory: `ps aux --sort=-%mem | head`

### Stage 2 Hangs During Podman Build

**Cause**: Insufficient CPU or memory

**Solutions**:
1. Increase VM CPUs to 4: `--vcpus 4`
2. Increase VM memory to 8GB: `--memory 8192`
3. Monitor from another terminal: `watch -n 1 free -h`

### Disk Space Issues

**Symptoms**: "No space left on device"

**Solutions**:
```bash
# Check space
df -h /var/tmp

# Clean up old archives
rm -f /var/tmp/coreos*.ociarchive

# Clean podman storage
podman system prune -a -f

# Clean rpm-ostree cache
rpm-ostree cleanup -m
```

### VM Becomes Unresponsive

**Cause**: OOM killer terminated critical processes

**Solutions**:
1. Force reboot from host: `Ctrl+C` in QEMU console
2. Restart with more memory
3. Run stages one at a time with reboots between

## Recommended VM Configuration

Based on testing, recommended minimum resources:

```bash
cosa run --qemu-image builds/latest/ppc64le/fedora-coreos-*.qcow2 \
         --memory 6144 \      # 6GB RAM (safe for all stages)
         --vcpus 2 \          # 2 CPUs minimum
         --devshell-console
```

For faster execution:
```bash
cosa run --qemu-image builds/latest/ppc64le/fedora-coreos-*.qcow2 \
         --memory 8192 \      # 8GB RAM
         --vcpus 4 \          # 4 CPUs
         --devshell-console
```

## Cleanup

After successful test completion:

```bash
# Remove kernel version file
rm -f /var/kola-kernel.evr

# Remove OCI archives (saves ~2-4GB)
rm -f /var/tmp/coreos*.ociarchive

# Clean podman storage
podman system prune -a -f

# Clean rpm-ostree
rpm-ostree cleanup -m
```

## Comparison with Original Test

| Aspect | Original (`manual-kernel-replace-test-full.sh`) | Staged Version |
|--------|------------------------------------------------|----------------|
| Execution | Single script with reboots | 4 separate scripts |
| Memory monitoring | None | Detailed at each stage |
| Failure isolation | Hard to identify failing stage | Easy to pinpoint |
| Resource management | All operations in sequence | Can pause between stages |
| Debugging | Difficult | Easy with per-stage logs |
| Flexibility | Fixed execution path | Can skip/repeat stages |

## Files Generated

- `/var/tmp/coreos.ociarchive` - Base OCI archive (~1-2GB)
- `/var/tmp/coreos-derived.ociarchive` - Derived OCI archive with new kernel (~1-2GB)
- `/var/kola-kernel.evr` - Expected kernel version (small text file)

## Success Criteria

✅ Stage 1: Base OCI archive created successfully  
✅ Stage 2: Derived OCI archive built with previous kernel  
✅ Stage 3: System rebased to derived image  
✅ Stage 4: Kernel version matches expected, all files present  

## Notes

- Each stage is idempotent (can be re-run safely)
- Stage 2 is the most resource-intensive
- Rebooting between stages can help with memory pressure
- Memory monitoring helps identify resource bottlenecks
- Scripts include detailed progress output for debugging

---

**Created by**: Bob  
**Based on**: `fedora-coreos-config/tests/kola/rpm-ostree/kernel-replace`  
**Purpose**: Debugging and understanding kernel replacement mechanism with resource monitoring