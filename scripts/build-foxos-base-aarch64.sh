#!/usr/bin/env bash
set -euo pipefail

BUILD_TIMEOUT_MINUTES="${BUILD_TIMEOUT_MINUTES:-45}"
BUILD_TIMEOUT_SECONDS=$(( BUILD_TIMEOUT_MINUTES * 60 ))

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$ROOT_DIR/output"

mkdir -p "$OUTDIR"

# 1) Upstream Fedora Cloud Base qcow2 (aarch64)
CLOUD_URL="https://archives.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-42-1.1.aarch64.qcow2"
CLOUD_SRC="$OUTDIR/Fedora-Cloud-Base-Generic-42-1.1.aarch64.qcow2"

# 2) Our final base image
BASE_IMG="$OUTDIR/FoxOS-Base-aarch64.qcow2"

# 3) Cloud-init seed image
SEED_IMG="$OUTDIR/foxos-seed-aarch64.iso"

echo "[FOXOS-BUILDER] Root dir : $ROOT_DIR"
echo "[FOXOS-BUILDER] Out dir  : $OUTDIR"

# ---------- Fetch Fedora Cloud image ----------
if [[ ! -f "$CLOUD_SRC" ]]; then
  echo "[FOXOS-BUILDER] Downloading Fedora Cloud Base aarch64..."
  echo "  From: $CLOUD_URL"
  echo "  To  : $CLOUD_SRC"
  curl -L "$CLOUD_URL" -o "$CLOUD_SRC"
else
  echo "[FOXOS-BUILDER] Using existing cloud image: $CLOUD_SRC"
fi

# ---------- Prepare working base image ----------
echo "[FOXOS-BUILDER] Creating FoxOS base qcow2..."
rm -f "$BASE_IMG"
qemu-img convert -O qcow2 "$CLOUD_SRC" "$BASE_IMG"

# ---------- Build cloud-init seed ----------
SEED_DIR="$(mktemp -d)"
trap 'rm -rf "$SEED_DIR"' EXIT

USER_DATA="$SEED_DIR/user-data"
META_DATA="$SEED_DIR/meta-data"

FOXOS_PASS_HASH='$6$aTsl7oq3GQkz7eGq$osmaiVfI6rOuhmmhONMtxpLt8IqPnPmtTQUINUY4erWDFa6iDVJfK3xXngVM1aQBXvxbpVtoqhSvL07Dvypkj1'

cat > "$USER_DATA" <<EOF
#cloud-config
users:
  - name: foxos
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [wheel]
    lock_passwd: false
    passwd: ${FOXOS_PASS_HASH}

ssh_pwauth: true
disable_root: true
chpasswd:
  expire: false

runcmd:
  - [ bash, -c, 'echo "[FOXOS] ARM base provisioning via cloud-init..."' ]
  - [ bash, -c, 'touch /var/lib/foxos-base-built' ]

power_state:
  mode: poweroff
  message: "FoxOS ARM base provisioning complete – powering off"
  timeout: 30
  condition: true
EOF

cat > "$META_DATA" <<EOF
instance-id: foxos-base-aarch64
local-hostname: foxos-base-aarch64
EOF

echo "[FOXOS-BUILDER] Creating cloud-init seed image..."
cloud-localds "$SEED_IMG" "$USER_DATA" "$META_DATA"

# ---------- Boot once under QEMU (emulated ARM) ----------
echo "[FOXOS-BUILDER] Booting QEMU aarch64 to apply cloud-init..."
echo "  Timeout: ${BUILD_TIMEOUT_MINUTES} minutes. VM should power off on its own."

if ! timeout "${BUILD_TIMEOUT_SECONDS}" qemu-system-aarch64 \
  -machine virt \
  -cpu cortex-a72 \
  -m 2048 \
  -nographic \
  -drive if=virtio,file="$BASE_IMG",format=qcow2 \
  -drive if=virtio,file="$SEED_IMG",format=raw \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0 \
  -serial mon:stdio \
  -no-reboot
then
  echo "[FOXOS-BUILDER] ERROR: QEMU timed out after ${BUILD_TIMEOUT_MINUTES} minutes." >&2
  echo "[FOXOS-BUILDER] The guest likely failed to boot or cloud-init did not power off." >&2
  exit 1
fi

echo "[FOXOS-BUILDER] QEMU exited successfully; proceeding to sparsify image..."
export LIBGUESTFS_BACKEND=direct

set +e
virt-sparsify --in-place "$BASE_IMG"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  echo "[FOXOS-BUILDER] WARNING: virt-sparsify failed (rc=$RC), continuing with non-sparsified image."
fi

echo "[FOXOS-BUILDER] Done. Final aarch64 image:"
qemu-img info "$BASE_IMG"

echo "[FOXOS-BUILDER] QEMU finished. FoxOS ARM base image ready:"
echo "  $BASE_IMG"
