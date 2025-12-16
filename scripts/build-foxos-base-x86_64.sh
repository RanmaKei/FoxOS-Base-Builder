#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$ROOT_DIR/output"
KS_DIR="$ROOT_DIR/ks"

IMG="$OUTDIR/FoxOS-Base-x86_64.qcow2"
HASHFILE="$IMG.sha256"
KS="$KS_DIR/foxos-base-ks-x86_64.cfg"

FEDORA_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/42/Everything/x86_64/os/"
TREEINFO_URL="${FEDORA_URL%/}/.treeinfo"

# Stores last-seen upstream signature
UPSTREAM_STAMP="$OUTDIR/.fedora-treeinfo-x86_64.sha256"

mkdir -p "$OUTDIR"

log() { echo "[FOXOS-BUILDER] $*"; }
have_tty() { [ -t 0 ] && [ -t 1 ]; }

# Controls
FORCE_REBUILD="${FORCE_REBUILD:-0}"                 # always rebuild
AUTO_REBUILD_ON_UPSTREAM_CHANGE="${AUTO_REBUILD_ON_UPSTREAM_CHANGE:-0}"  # CI-friendly: rebuild automatically when upstream changes

prompt_rebuild_5s_default_no() {
  if ! have_tty; then
    log "No TTY detected (CI). Defaulting to NO (keep existing) unless AUTO_REBUILD_ON_UPSTREAM_CHANGE=1."
    return 1
  fi

  log "Press 'y' then Enter within 5 seconds to REBUILD (delete + rebuild)."
  log "Timeout/anything else = keep existing."
  local ans=""
  if read -r -t 5 ans; then
    [[ "${ans,,}" == "y" ]]
    return $?
  else
    return 1
  fi
}

write_hashfile() {
  log "Writing hash file: $HASHFILE"
  (cd "$(dirname "$IMG")" && sha256sum "$(basename "$IMG")" > "$(basename "$HASHFILE")")
}

verify_local_hash_ok() {
  [[ -f "$IMG" && -f "$HASHFILE" ]] && sha256sum -c "$HASHFILE" >/dev/null 2>&1
}

# Returns:
# 0 = upstream changed
# 1 = upstream unchanged OR couldn't check (treated as unchanged for safety)
upstream_changed() {
  local new_hash old_hash

  # If network is down or curl missing, don't force rebuild.
  if ! new_hash="$(curl -fsSL "$TREEINFO_URL" | sha256sum | awk '{print $1}' 2>/dev/null)"; then
    log "WARNING: Could not fetch $TREEINFO_URL; skipping upstream check."
    return 1
  fi

  old_hash=""
  [[ -f "$UPSTREAM_STAMP" ]] && old_hash="$(cat "$UPSTREAM_STAMP" 2>/dev/null || true)"

  # Always update stamp for next run
  echo "$new_hash" > "$UPSTREAM_STAMP"

  if [[ -n "$old_hash" && "$new_hash" != "$old_hash" ]]; then
    return 0
  fi

  return 1
}

build_image() {
  log "Starting virt-install (x86_64)..."
  virt-install \
    --name foxos-base-x86_64 \
    --ram 2048 \
    --vcpus 2 \
    --disk path="$IMG",size=16,format=qcow2 \
    --os-variant fedora-unknown \
    --location "$FEDORA_URL" \
    --initrd-inject="$KS" \
    --extra-args="inst.ks=file:/$(basename "$KS") console=ttyS0,115200n8" \
    --graphics none \
    --virt-type qemu \
    --wait=-1 \
    --noreboot

  set +e
  virt-sparsify --in-place "$IMG"
  RC=$?
  set -e
  if [[ $RC -ne 0 ]]; then
    log "WARNING: virt-sparsify failed (rc=$RC), continuing with non-sparsified image."
  fi

  qemu-img info "$IMG"
  write_hashfile
  log "Build complete. Image at: $IMG"
}

# ---- Main flow ----

# Force rebuild overrides everything
if [[ "$FORCE_REBUILD" == "1" ]]; then
  log "FORCE_REBUILD=1 set: removing old image + hash."
  rm -f "$IMG" "$HASHFILE"
  build_image
  exit 0
fi

# If we have a verified local image, only rebuild if upstream changed (and user/CI allows)
if verify_local_hash_ok; then
  log "Local image verified OK."

  if upstream_changed; then
    log "Upstream Fedora install tree changed since last run."

    if [[ "$AUTO_REBUILD_ON_UPSTREAM_CHANGE" == "1" ]]; then
      log "AUTO_REBUILD_ON_UPSTREAM_CHANGE=1: rebuilding automatically."
      rm -f "$IMG" "$HASHFILE"
      build_image
      exit 0
    fi

    if prompt_rebuild_5s_default_no; then
      log "Rebuilding due to upstream change (user approved)."
      rm -f "$IMG" "$HASHFILE"
      build_image
    else
      log "Keeping existing image (user declined rebuild)."
      qemu-img info "$IMG" || true
    fi
  else
    log "Upstream unchanged (or check skipped). Keeping existing image."
    qemu-img info "$IMG" || true
  fi

  exit 0
fi

# If image missing OR hash missing/failed -> rebuild
if [[ -f "$IMG" && -f "$HASHFILE" ]]; then
  log "WARNING: Local hash check failed; rebuilding."
elif [[ -f "$IMG" && ! -f "$HASHFILE" ]]; then
  log "Local image exists but no hash file; cannot verify."
  if prompt_rebuild_5s_default_no; then
    log "User approved rebuild."
  else
    log "Keeping existing image (unverified)."
    qemu-img info "$IMG" || true
    exit 0
  fi
fi

log "Rebuilding: removing old image + hash."
rm -f "$IMG" "$HASHFILE"
build_image
