#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$ROOT_DIR/output"
KS_DIR="$ROOT_DIR/ks"

IMG="$OUTDIR/FoxOS-Base-x86_64.qcow2"
KS="$KS_DIR/foxos-base-ks-x86_64.cfg"

mkdir -p "$OUTDIR"

echo "[FOXOS-BUILDER] Removing old image (if any)"
rm -f "$IMG"

echo "[FOXOS-BUILDER] Starting virt-install (x86_64)..."
virt-install \
  --name foxos-base-x86_64 \
  --ram 2048 \
  --vcpus 2 \
  --disk path="$IMG",size=20,format=qcow2 \
  --os-variant fedora-unknown \
  --location "https://download.fedoraproject.org/pub/fedora/linux/releases/42/Everything/x86_64/os/" \
  --initrd-inject="$KS" \
  --extra-args="inst.ks=file:/$(basename "$KS") console=ttyS0,115200n8" \
  --graphics none \
  --virt-type qemu \
  --wait=-1 \
  --noreboot

echo "[FOXOS-BUILDER] Build complete. Image at: $IMG"
