# Kernel Panic Bug Report - Fedora 43 Kernel 7.0.12 on PowerPC64LE

**Date**: June 11, 2026  
**Reporter**: Poorna Gottimukkula  
**Severity**: CRITICAL - Kernel panic during boot  
**Architecture**: ppc64le (PowerPC64 Little Endian)

---

## Summary

Fedora CoreOS kernel 7.0.12-100.fc43.ppc64le experiences a kernel panic during early boot initialization on PowerPC64LE systems. The panic occurs in the cgroup subsystem initialization, preceded by an ftrace initialization failure.

---

## Environment

- **Kernel Version**: 7.0.12-100.fc43.ppc64le
- **Build Date**: Tue Jun 9 17:42:09 UTC 2026
- **Compiler**: gcc (GCC) 15.2.1 20260123 (Red Hat 15.2.1-7)
- **Linker**: GNU ld version 2.45.1-4.fc43
- **Platform**: IBM pSeries (emulated by qemu) POWER10
- **Firmware**: SLOF,HEAD
- **Hypervisor**: linux,kvm
- **Memory**: 8GB (0x200000000)
- **CPUs**: 1 CPU configured
- **Fedora CoreOS Version**: 44.20260607.20.dev0

---

## Reproduction Steps

1. Boot Fedora CoreOS with kernel 7.0.12-100.fc43.ppc64le
2. System starts boot process
3. Kernel panic occurs during early initialization

**Command to reproduce**:
```bash
cosa kola run -p qemu --qemu-memory 8192 ext.config.rpm-ostree.kernel-replace
```

---

## Error Messages

### 1. ftrace Initialization Failure

```
[    0.000000] ftrace-powerpc: 0xc0000000015f0168: expected (60000000) != found (00000000)
[    0.000000] ------------[ ftrace bug ]------------
[    0.000000] ftrace failed to modify
[    0.000000] [<c0000000015f0168>] netdev_nl_stats_by_netdev+0x8/0x240
[    0.000000]  actual:   00:00:00:00
[    0.000000] Initializing ftrace call sites
[    0.000000] ftrace record flags: 0
[    0.000000]  (0)
[    0.000000]  expected tramp: c000000000084848
[    0.000000] ------------[ cut here ]------------
[    0.000000] WARNING: kernel/trace/ftrace.c:2254 at ftrace_bug+0x27c/0x2e4, CPU#0: swapper/0
```

### 2. Kernel Panic in cgroup_init

```
[    0.023928] Oops: Exception in kernel mode, sig: 4 [#1]
[    0.024004] LE PAGE_SIZE=64K MMU=Radix  SMP NR_CPUS=8192 NUMA pSeries
[    0.024096] Modules linked in:
[    0.024154] CPU: 0 UID: 0 PID: 0 Comm: swapper/0 Tainted: G        W           7.0.12-100.fc43.ppc64le #1 PREEMPT(lazy)
[    0.024313] Tainted: [W]=WARN
[    0.024368] Hardware name: IBM pSeries (emulated by qemu) POWER10 (architected) 0x800200 0xf000006 of:SLOF,HEAD hv:linux,kvm pSeries
[    0.024558] NIP:  c000000001622fb0 LR: c00000000304a32c CTR: c000000001622fb0
[    0.024670] REGS: c000000003e97b10 TRAP: 0700   Tainted: G        W            (7.0.12-100.fc43.ppc64le)
[    0.024796] MSR:  8000000002088033 <SF,VEC,EE,IR,DR,RI,LE>  CR: 24000822  XER: 00000092
[    0.024922] CFAR: c00000000304a328 IRQMASK: 0
[    0.025833] NIP [c000000001622fb0] cgrp_css_alloc+0x0/0x90
[    0.025913] LR [c00000000304a32c] cgroup_init_subsys+0xd4/0x2e4
[    0.026009] Call Trace:
[    0.026048] [c000000003e97db0] [c00000000304a2ec] cgroup_init_subsys+0x94/0x2e4 (unreliable)
[    0.026180] [c000000003e97e50] [c00000000304aa8c] cgroup_init+0x290/0x6f8
[    0.026276] [c000000003e97f30] [c00000000300edfc] start_kernel+0x60c/0x62c
[    0.026377] [c000000003e97fe0] [c00000000000e998] start_here_common+0x1c/0x20
[    0.026487] Code: 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 <00000000> 00000000 00000000 00000000
[    0.026698] ---[ end trace 0000000000000000 ]---
[    0.026773]
[    1.026816] Kernel panic - not syncing: Attempted to kill the idle task!
```

---

## Analysis

### Root Cause

1. **ftrace Initialization Failure**:
   - ftrace fails to modify function `netdev_nl_stats_by_netdev` at address `0xc0000000015f0168`
   - Expected instruction: `60000000` (nop)
   - Found instruction: `00000000` (invalid/null)
   - This suggests memory corruption or incorrect code patching

2. **Cascading Failure**:
   - ftrace failure taints the kernel with warning flag
   - System continues boot despite ftrace failure
   - Kernel panics when attempting to initialize cgroup subsystem
   - Panic occurs in `cgrp_css_alloc` function (address shows all zeros)

3. **Memory/Code Corruption**:
   - The code at `cgrp_css_alloc` appears to be all zeros
   - This indicates either:
     - Incorrect relocation during kernel load
     - Memory corruption during early boot
     - Build/linking issue specific to PowerPC

### Impact

- **Severity**: CRITICAL
- **Affected Systems**: All PowerPC64LE systems running kernel 7.0.12-100.fc43
- **Workaround**: Use previous kernel version 7.0.11-100.fc43 (confirmed working)
- **Blocks**: All testing and production use of this kernel version on PowerPC

---

## Comparison with Working Kernel

| Aspect | 7.0.11-100.fc43 (Working) | 7.0.12-100.fc43 (Broken) |
|--------|---------------------------|--------------------------|
| ftrace init | ✅ Success | ❌ Failure |
| cgroup init | ✅ Success | ❌ Kernel panic |
| Boot result | ✅ Boots to login | ❌ Panic before userspace |
| Memory tested | 4GB, 8GB | 8GB |

---

## Additional Observations

1. **Architecture-Specific**: This appears to be PowerPC-specific, as ftrace patching differs by architecture

2. **Build Issue**: The all-zero code at `cgrp_css_alloc` suggests a build or linking problem

3. **Timing**: Issue occurs very early in boot (before userspace starts)

4. **Not Memory-Related**: Occurs with 8GB RAM (sufficient memory)

---

## Recommended Actions

### Immediate

1. **Revert to 7.0.11-100.fc43** for PowerPC systems
2. **Block 7.0.12-100.fc43** from PowerPC deployments
3. **Investigate build process** for PowerPC-specific issues

### Investigation

1. **Compare build logs** between 7.0.11 and 7.0.12
2. **Check ftrace patching code** for PowerPC changes
3. **Verify relocation handling** for PowerPC kernel
4. **Test on physical PowerPC hardware** (not just QEMU)

### Long-term

1. **Add PowerPC-specific CI tests** for kernel builds
2. **Implement early boot validation** for ftrace initialization
3. **Add memory/code integrity checks** during kernel init

---

## Related Issues

- BTF validation errors (separate issue, non-fatal)
- iSCSI dracut errors (configuration issue, separate)
- Memory-dependent boot hangs with 2GB RAM (separate issue)

---

## Attachments

Full console log available showing:
- Complete boot sequence
- ftrace failure details
- Kernel panic stack trace
- Register dump at panic

---

## Contact

**Reporter**: Poorna Gottimukkula  
**Email**: [your-email]  
**Team**: [your-team]  
**Date**: June 11, 2026

---

## Priority Justification

**CRITICAL** because:
1. Complete boot failure (kernel panic)
2. Affects all PowerPC64LE systems
3. No workaround except kernel downgrade
4. Blocks all testing and production use
5. Indicates potential memory corruption or build issue

This issue should be escalated to the Fedora kernel team immediately.