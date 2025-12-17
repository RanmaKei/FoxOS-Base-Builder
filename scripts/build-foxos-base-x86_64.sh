#!/usr/bin/env bash
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "ERROR: This script must be run with bash." >&2; exit 2; }

BUILD_TIMEOUT_MINUTES="${BUILD_TIMEOUT_MINUTES:-45}"
BUILD_TIMEOUT_SECONDS=$(( BUILD_TIMEOUT_MINUTES * 60 ))

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$ROOT_DIR/output"
mkdir -p "$OUTDIR"

# Upstream Fedora Cloud images dir (x86_64)
CLOUD_DIR_URL="https://archives.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/"

# Final artifact
BASE_IMG="$OUTDIR/FoxOS-Base-x86_64.qcow2"
BASE_HASHFILE="$BASE_IMG.sha256"

# Cloud-init seed IMG
SEED_IMG="$OUTDIR/foxos-x86-seed.img"

# Controls
FORCE_REBUILD="${FORCE_REBUILD:-0}"                  # force rebuild final image
AUTO_UPDATE_CLOUD="${AUTO_UPDATE_CLOUD:-0}"          # CI-friendly: download newer upstream automatically
FORCE_REDOWNLOAD_CLOUD="${FORCE_REDOWNLOAD_CLOUD:-0}" # always redownload latest upstream

log() { echo "[FOXOS-BUILDER] $*"; }
have_tty() { [[ -t 0 && -t 1 ]]; }

prompt_yes_5s_default_no() {
  local msg="$1"
  log "$msg"
  if ! have_tty; then
    log "No TTY detected (CI). Defaulting to NO."
    return 1
  fi
  log "Press 'y' then Enter within 5 seconds to proceed. Timeout/other = NO."
  local ans=""
  if read -r -t 5 ans; then
    [[ "${ans,,}" == "y" ]]
  else
    return 1
  fi
}

write_hashfile() {
  local file="$1" hashfile="$2"
  (cd "$(dirname "$file")" && sha256sum "$(basename "$file")" > "$(basename "$hashfile")")
}

verify_hashfile() {
  local hashfile="$1"
  sha256sum -c "$hashfile" >/dev/null 2>&1
}

download_file() {
  local url="$1" dest="$2"
  log "Downloading:"
  log "  From: $url"
  log "  To  : $dest"
  curl -fL --retry 3 --retry-delay 2 "$url" -o "$dest"
}

get_latest_cloud_filename() {
  curl -fsSL "$CLOUD_DIR_URL" \
    | grep -oE 'Fedora-Cloud-Base-Generic-42-[0-9.]+\.x86_64\.qcow2' \
    | sort -V \
    | tail -n 1
}

# ---- Determine latest upstream ----
LATEST_CLOUD_FILE="$(get_latest_cloud_filename || true)"
if [[ -z "${LATEST_CLOUD_FILE:-}" ]]; then
  log "ERROR: Could not determine latest Fedora Cloud qcow2 from:"
  log "  $CLOUD_DIR_URL"
  exit 1
fi

CLOUD_URL="${CLOUD_DIR_URL}${LATEST_CLOUD_FILE}"
CLOUD_SRC="$OUTDIR/${LATEST_CLOUD_FILE}"
CLOUD_HASHFILE="$CLOUD_SRC.sha256"

log "Out dir  : $OUTDIR"
log "Latest upstream cloud image detected:"
log "  $CLOUD_URL"

# ---- If final image exists and is verified, skip unless forced ----
if [[ "$FORCE_REBUILD" != "1" && -f "$BASE_IMG" && -f "$BASE_HASHFILE" ]]; then
  log "Verifying existing final image: $BASE_HASHFILE"
  if verify_hashfile "$BASE_HASHFILE"; then
    log "Final image hash OK. Skipping rebuild."
    qemu-img info "$BASE_IMG" || true
    exit 0
  else
    log "WARNING: Final image hash FAILED. Will rebuild."
    rm -f "$BASE_IMG" "$BASE_HASHFILE"
  fi
fi

# ---- Decide whether to fetch newest upstream cloud image ----
need_cloud_download=0

if [[ "$FORCE_REDOWNLOAD_CLOUD" == "1" ]]; then
  log "FORCE_REDOWNLOAD_CLOUD=1 set: will redownload latest upstream."
  need_cloud_download=1
else
  if [[ -f "$CLOUD_SRC" ]]; then
    if [[ -f "$CLOUD_HASHFILE" ]]; then
      log "Verifying existing newest cloud image: $CLOUD_HASHFILE"
      if verify_hashfile "$CLOUD_HASHFILE"; then
        log "Cloud image hash OK. Using existing: $CLOUD_SRC"
      else
        log "WARNING: Cloud image hash FAILED. Will redownload."
        need_cloud_download=1
      fi
    else
      log "Newest cloud image exists but no hash file found: $CLOUD_HASHFILE"
      if prompt_yes_5s_default_no "Redownload newest upstream cloud image to ensure integrity?"; then
        need_cloud_download=1
      else
        log "Using existing newest cloud image (unverified): $CLOUD_SRC"
      fi
    fi
  else
    log "Newest upstream image not found locally: $CLOUD_SRC"
    if [[ "$AUTO_UPDATE_CLOUD" == "1" ]]; then
      log "AUTO_UPDATE_CLOUD=1: will download newer version automatically."
      need_cloud_download=1
    else
      if prompt_yes_5s_default_no "A newer Fedora Cloud image is available (${LATEST_CLOUD_FILE}). Download it now?"; then
        need_cloud_download=1
      else
        log "Not downloading newer upstream image."
        exit 1
      fi
    fi
  fi
fi

if [[ "$need_cloud_download" == "1" ]]; then
  rm -f "$CLOUD_SRC" "$CLOUD_HASHFILE"
  download_file "$CLOUD_URL" "$CLOUD_SRC"
  write_hashfile "$CLOUD_SRC" "$CLOUD_HASHFILE"
  log "Wrote hash: $CLOUD_HASHFILE"
fi

# ---- Prepare working base image ----
log "Creating FoxOS base qcow2..."
rm -f "$BASE_IMG" "$BASE_HASHFILE"
qemu-img convert -O qcow2 "$CLOUD_SRC" "$BASE_IMG"

# ---- Build cloud-init seed ----
SEED_DIR="$(mktemp -d)"
trap 'rm -rf "$SEED_DIR"' EXIT

USER_DATA="$SEED_DIR/user-data.yaml"
META_DATA="$SEED_DIR/meta-data.yaml"

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
  - [ bash, -lc, 'echo "[FOXOS] x86_64 base provisioning via cloud-init..."' ]
  - [ bash, -lc, 'touch /var/lib/foxos-base-built' ]

power_state:
  mode: poweroff
  message: "FoxOS x86_64 base provisioning complete - powering off"
  timeout: 30
  condition: true
EOF

cat > "$META_DATA" <<EOF
instance-id: foxos-base-x86_64
local-hostname: foxos-base-x86_64
EOF

log "Creating cloud-init seed image..."
rm -f "$SEED_IMG"
cloud-localds "$SEED_IMG" "$USER_DATA" "$META_DATA"

# ---- Boot once under QEMU (x86_64) ----
log "Booting QEMU x86_64 to apply cloud-init..."
log "  Timeout: ${BUILD_TIMEOUT_MINUTES} minutes. VM should power off on its own."

# KVM if available; falls back to TCG if not
ACCEL_ARGS=()
if [[ -e /dev/kvm ]]; then
  ACCEL_ARGS=(-enable-kvm -cpu host)
else
  ACCEL_ARGS=(-cpu qemu64)
fi

if ! timeout "${BUILD_TIMEOUT_SECONDS}" qemu-system-x86_64 \
  "${ACCEL_ARGS[@]}" \
  -m 2048 \
  -nographic \
  -drive if=virtio,file="$BASE_IMG",format=qcow2 \
  -drive if=virtio,file="$SEED_IMG",format=raw \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -serial mon:stdio \
  -no-reboot
then
  log "ERROR: QEMU timed out after ${BUILD_TIMEOUT_MINUTES} minutes."
  log "The guest likely failed to boot or cloud-init did not power off."
  exit 1
fi

log "QEMU exited successfully; proceeding to sparsify image..."
export LIBGUESTFS_BACKEND=direct

set +e
virt-sparsify --in-place "$BASE_IMG"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  log "WARNING: virt-sparsify failed (rc=$RC), continuing with non-sparsified image."
fi

write_hashfile "$BASE_IMG" "$BASE_HASHFILE"

log "Done. Final x86_64 image:"
qemu-img info "$BASE_IMG"
log "Final image hash saved: $BASE_HASHFILE"
log "FoxOS x86_64 base image ready: $BASE_IMG"
