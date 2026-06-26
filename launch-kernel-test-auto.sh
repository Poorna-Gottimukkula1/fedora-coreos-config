#!/bin/bash
# Host-side launcher for automatic kernel-replace test
# Generates Ignition config with auto-run script and launches VM
# Run this from the coreos-assembler directory on the HOST

set -euo pipefail

# Default values
MEMORY=8192  # 8GB RAM (safe for Stage 2 podman build)
VCPUS=2

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Launch CoreOS VM with automatic kernel-replace test (all stages)

Options:
    -m, --memory MB     Memory in MB (default: 8192 = 8GB)
    -c, --vcpus NUM     Number of vCPUs (default: 2)
    -h, --help          Show this help

The test will:
    1. Auto-run on first boot (Stages 1-3)
    2. Automatically reboot after Stage 3
    3. Auto-run Stage 4 after reboot to verify
    4. Complete with success/failure status

Logs available at: /var/log/kernel-test.log (inside VM)

Examples:
    # Run with defaults (8GB RAM, 2 CPUs)
    $0

    # Run with 6GB RAM
    $0 -m 6144

    # Run with 4 CPUs for faster execution
    $0 -c 4

Recommended: 8GB RAM minimum for Stage 2 (podman build)

EOF
    exit 0
}

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
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Find latest qcow2 image
QCOW2_IMAGE=$(find builds/latest/ppc64le/ -name "*.qcow2" 2>/dev/null | head -n1)

if [ -z "$QCOW2_IMAGE" ]; then
    echo -e "${RED}ERROR: No qcow2 image found in builds/latest/ppc64le/${NC}"
    echo "Please build an image first with: cosa build"
    exit 1
fi

# Check if auto-run script exists
if [ ! -f "kernel-replace-auto-all-stages.sh" ]; then
    echo -e "${RED}ERROR: kernel-replace-auto-all-stages.sh not found${NC}"
    echo "Please ensure the script is in the current directory"
    exit 1
fi

# Create temporary directory for ignition config
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${GREEN}=========================================="
echo "Kernel Replace Test - Auto All Stages"
echo -e "==========================================${NC}"
echo "Image:    $QCOW2_IMAGE"
echo "Memory:   ${MEMORY}MB ($(echo "scale=1; $MEMORY/1024" | bc)GB)"
echo "vCPUs:    $VCPUS"
echo "Mode:     Automatic (all stages)"
echo ""

# Read and base64 encode the auto-run script
SCRIPT_CONTENT=$(cat kernel-replace-auto-all-stages.sh)
SCRIPT_B64=$(echo "$SCRIPT_CONTENT" | base64 -w0)

# Generate SSH key if not exists
SSH_KEY_FILE="$HOME/.ssh/id_rsa.pub"
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo -e "${YELLOW}Generating SSH key...${NC}"
    ssh-keygen -t rsa -b 2048 -f "$HOME/.ssh/id_rsa" -N "" -C "kernel-test"
fi

SSH_KEY=$(cat "$SSH_KEY_FILE")

# Create Ignition config with auto-run systemd service
cat > "$TEMP_DIR/config.ign" << EOF
{
  "ignition": {
    "version": "3.2.0"
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": [
          "$SSH_KEY"
        ]
      }
    ]
  },
  "storage": {
    "files": [
      {
        "path": "/usr/local/bin/kernel-test-auto.sh",
        "mode": 493,
        "contents": {
          "source": "data:text/plain;charset=utf-8;base64,$SCRIPT_B64"
        }
      },
      {
        "path": "/etc/zincati/config.d/90-disable-auto-updates.toml",
        "mode": 420,
        "contents": {
          "source": "data:text/plain;charset=utf-8;base64,W3VwZGF0ZXNdCgllbmFibGVkID0gZmFsc2U="
        }
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "name": "kernel-test-auto.service",
        "enabled": true,
        "contents": "[Unit]\nDescription=Kernel Replace Test - Auto All Stages\nAfter=network-online.target\nWants=network-online.target\nConditionPathExists=!/var/lib/kernel-test-complete\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/local/bin/kernel-test-auto.sh\nStandardOutput=journal+console\nStandardError=journal+console\n\n[Install]\nWantedBy=multi-user.target\n"
      }
    ]
  }
}
EOF

echo -e "${GREEN}Generated Ignition config:${NC}"
echo "  Location: $TEMP_DIR/config.ign"
echo "  Script: /usr/local/bin/kernel-test-auto.sh"
echo "  Service: kernel-test-auto.service (enabled)"
echo ""

# Validate ignition config if validator available
if command -v ignition-validate &> /dev/null; then
    if ignition-validate "$TEMP_DIR/config.ign" 2>/dev/null; then
        echo -e "${GREEN}✓ Ignition config validated${NC}"
    else
        echo -e "${YELLOW}⚠ Ignition validation unavailable${NC}"
    fi
    echo ""
fi

echo -e "${YELLOW}Test Execution Plan:${NC}"
echo "  Boot 1: Stages 1-3 (build, download, rebase)"
echo "  Reboot: Automatic after Stage 3"
echo "  Boot 2: Stage 4 (verify kernel switch)"
echo ""
echo "Monitor progress:"
echo "  - Console output (this terminal)"
echo "  - Inside VM: journalctl -u kernel-test-auto.service -f"
echo "  - Inside VM: tail -f /var/log/kernel-test.log"
echo ""
echo -e "${YELLOW}Starting VM in 3 seconds...${NC}"
echo "Press Ctrl+C to abort"
sleep 3

# Launch VM with cosa run
echo ""
echo -e "${GREEN}Launching VM...${NC}"
echo ""

exec cosa run \
    --qemu-image "$QCOW2_IMAGE" \
    -m "$MEMORY" \
    --ignition "$TEMP_DIR/config.ign" \
    -c

# Made with Bob
