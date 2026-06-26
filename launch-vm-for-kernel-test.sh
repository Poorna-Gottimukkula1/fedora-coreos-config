#!/bin/bash
# Helper script to launch CoreOS VM with adequate resources for kernel-replace test
# Run this from the coreos-assembler directory

set -euo pipefail

# Default values
MEMORY=6144  # 6GB RAM (safe for all stages)
VCPUS=2      # 2 CPUs minimum
IGNITION=""  # Optional custom ignition config

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -c|--vcpus)
            VCPUS="$2"
            shift 2
            ;;
        -i|--ignition)
            IGNITION="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Launch CoreOS VM with adequate resources for kernel-replace test"
            echo ""
            echo "Options:"
            echo "  -m, --memory MB     Memory in MB (default: 6144 = 6GB)"
            echo "  -c, --vcpus NUM     Number of vCPUs (default: 2)"
            echo "  -i, --ignition PATH Path to custom ignition config (optional)"
            echo "  -h, --help          Show this help"
            echo ""
            echo "Examples:"
            echo "  # Launch with defaults (6GB RAM, 2 CPUs)"
            echo "  $0"
            echo ""
            echo "  # Launch with 8GB RAM and 4 CPUs"
            echo "  $0 -m 8192 -c 4"
            echo ""
            echo "  # Launch with custom ignition config"
            echo "  $0 -i /var/tmp/mantle-qemu1600990472/config.ign"
            echo ""
            echo "Recommended configurations:"
            echo "  Minimum:  -m 4096 -c 2  (4GB RAM, 2 CPUs)"
            echo "  Safe:     -m 6144 -c 2  (6GB RAM, 2 CPUs) [DEFAULT]"
            echo "  Fast:     -m 8192 -c 4  (8GB RAM, 4 CPUs)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Find latest qcow2 image
QCOW2_IMAGE=$(find builds/latest/ppc64le/ -name "*.qcow2" | head -n1)

if [ -z "$QCOW2_IMAGE" ]; then
    echo "ERROR: No qcow2 image found in builds/latest/ppc64le/"
    echo "Please build an image first with: cosa build"
    exit 1
fi

echo "=========================================="
echo "Launching CoreOS VM for Kernel Replace Test"
echo "=========================================="
echo "Image:    $QCOW2_IMAGE"
echo "Memory:   ${MEMORY}MB ($(echo "scale=1; $MEMORY/1024" | bc)GB)"
echo "vCPUs:    $VCPUS"
if [ -n "$IGNITION" ]; then
    echo "Ignition: $IGNITION"
else
    echo "Ignition: Default (auto-generated)"
fi
echo "=========================================="
echo ""

# Build cosa run command
COSA_CMD="cosa run --qemu-image $QCOW2_IMAGE -m $MEMORY"

# Add ignition if specified
if [ -n "$IGNITION" ]; then
    COSA_CMD="$COSA_CMD --ignition $IGNITION"
fi

# Add devshell console
COSA_CMD="$COSA_CMD -c"

echo "Command: $COSA_CMD"
echo ""
echo "After VM boots:"
echo "  1. Login as 'core' user (password-less with SSH key)"
echo "  2. Switch to root: sudo -i"
echo "  3. Create test directory: mkdir -p /root/kernel-test && cd /root/kernel-test"
echo "  4. Copy the 4 stage scripts to /root/kernel-test/"
echo "  5. Make executable: chmod +x kernel-replace-stage*.sh"
echo "  6. Run Stage 1: ./kernel-replace-stage1-setup.sh"
echo ""
echo "Press Ctrl+C to abort, or Enter to continue..."
read

# Execute cosa run
exec $COSA_CMD

# Made with Bob
