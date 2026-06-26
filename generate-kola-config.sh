#!/bin/bash
# Script to generate a config.ign similar to what Kola generates for external tests
# This mimics the configuration used for tests like kernel-replace

set -euo pipefail

# Configuration variables
SSH_KEY="${SSH_KEY:-$(cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "")}"
TEST_NAME="${TEST_NAME:-ext.config.rpm-ostree.kernel-replace}"
TEST_EXECUTABLE="${TEST_EXECUTABLE:-kernel-replace}"
OUTPUT_FILE="${OUTPUT_FILE:-config.ign}"
IGNITION_VERSION="${IGNITION_VERSION:-3.2.0}"

# Check if SSH key is available
if [ -z "$SSH_KEY" ]; then
    echo "Error: No SSH key found. Please set SSH_KEY environment variable or ensure ~/.ssh/id_rsa.pub exists"
    exit 1
fi

# Escape SSH key for JSON
SSH_KEY_ESCAPED=$(echo "$SSH_KEY" | sed 's/"/\\"/g')

# Generate the systemd unit content
SYSTEMD_UNIT_CONTENT="[Unit]
[Service]
RemainAfterExit=yes
EnvironmentFile=-/run/kola-runext-env
Environment=KOLA_UNIT=kola-runext.service
Environment=KOLA_TEST=${TEST_NAME}
Environment=KOLA_TEST_EXE=${TEST_EXECUTABLE}
Environment=KOLA_EXT_DATA=/var/opt/kola/extdata
ExecStart=/usr/local/bin/kola-runext-${TEST_EXECUTABLE}"

# Escape systemd unit content for JSON
SYSTEMD_UNIT_ESCAPED=$(echo "$SYSTEMD_UNIT_CONTENT" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')

# Generate Zincati disable config (base64 encoded)
ZINCATI_CONFIG="[updates]
	enabled = false"
ZINCATI_BASE64=$(echo "$ZINCATI_CONFIG" | base64 -w 0)

# Generate the Ignition config
cat > "$OUTPUT_FILE" << EOF
{
  "ignition": {
    "version": "${IGNITION_VERSION}"
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": [
          "${SSH_KEY_ESCAPED}"
        ]
      }
    ]
  },
  "storage": {
    "files": [
      {
        "path": "/etc/zincati/config.d/90-disable-auto-updates.toml",
        "contents": {
          "source": "data:text/plain;charset=utf-8;base64,${ZINCATI_BASE64}"
        },
        "mode": 420
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "name": "kola-runext.service",
        "contents": "${SYSTEMD_UNIT_ESCAPED}",
        "enabled": false
      }
    ]
  }
}
EOF

echo "Generated Ignition config: $OUTPUT_FILE"
echo ""
echo "Configuration details:"
echo "  - Ignition version: ${IGNITION_VERSION}"
echo "  - Test name: ${TEST_NAME}"
echo "  - Test executable: ${TEST_EXECUTABLE}"
echo "  - SSH key configured for 'core' user"
echo "  - Zincati auto-updates disabled"
echo "  - Systemd unit: kola-runext.service"
echo ""
echo "To use with QEMU:"
echo "  qemu-system-ppc64 -drive if=none,id=ignition,format=raw,file=${OUTPUT_FILE},readonly=on \\"
echo "    -device virtio-blk,serial=ignition,drive=ignition ..."

# Made with Bob
