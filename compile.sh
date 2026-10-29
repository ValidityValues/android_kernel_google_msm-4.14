#!/usr/bin/env bash
# Pixel 4 (floral) Android 4.14 kernel build + AnyKernel3 package.
# Options: KERNEL_NAME, JOBS.
set -Ee pipefail
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
# Remove any untracked KernelSU-Next leftovers and old Kconfig/Makefile wiring before baseline builds.
rm -rf "$ROOT/KernelSU-Next" "$ROOT/drivers/kernelsu" "$ROOT"/KernelSU-Next.incomplete.*
python3 - "$ROOT" <<'PY_CLEAN_KSU'
from pathlib import Path
import sys

root = Path(sys.argv[1])
exact_lines = {
    "drivers/Makefile": {"obj-$(CONFIG_KSU) += kernelsu/"},
    "drivers/Kconfig": {'source "drivers/kernelsu/Kconfig"'},
}
for rel, stale_lines in exact_lines.items():
    path = root / rel
    if not path.is_file():
        raise SystemExit("Cannot validate clean baseline: missing " + rel)
    original = path.read_text()
    kept = [line for line in original.splitlines() if line.strip() not in stale_lines]
    cleaned = "\n".join(kept) + ("\n" if original.endswith("\n") else "")
    if cleaned != original:
        path.write_text(cleaned)
PY_CLEAN_KSU
OUT_DIR="$ROOT/out"
TOOLCHAIN_DIR="$ROOT/.toolchains"
DIST_DIR="$ROOT/dist"
# Never reuse object files or ZIPs from an earlier build; keep only the downloaded toolchain cache.
rm -rf "$OUT_DIR" "$DIST_DIR"
mkdir -p "$OUT_DIR" "$TOOLCHAIN_DIR" "$DIST_DIR"
LOG="$OUT_DIR/compile.log"
ARCH=arm64
DEFCONFIG=floral_defconfig
CROSS_COMPILE=aarch64-linux-android-
CLANG_REV=clang-r416183b
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android12-release/$CLANG_REV.tar.gz"
CLANG_ROOT="$TOOLCHAIN_DIR/$CLANG_REV"
CLANG_BIN="$CLANG_ROOT/bin"
CLANG_ARCHIVE="$TOOLCHAIN_DIR/downloads/$CLANG_REV.tar.gz"
AK3_SOURCE="$TOOLCHAIN_DIR/AnyKernel3"
AK3_COMMIT=41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1

if [ -z "$KERNEL_NAME" ]; then KERNEL_NAME='Validity Pixel 4 Kernel'; fi
if ! printf '%s\n' "$KERNEL_NAME" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._ +()-]{0,79}$'; then
  echo '[ERROR] KERNEL_NAME must be 1-80 chars: letters, digits, spaces, . _ + ( ) -' >&2; exit 2
fi
SAFE_KERNEL_NAME="$(printf '%s' "$KERNEL_NAME" | sed -E 's/[[:space:]]+/-/g; s/[^A-Za-z0-9._+-]/_/g')"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
run_logged() {
  log "+ $*"
  local -a pipeline_status
  local rc
  # Put the pipeline in an if-condition so set -e/ERR cannot hide the
  # original command status behind tee's successful exit status.
  if "$@" 2>&1 | tee -a "$LOG"; then
    pipeline_status=("${PIPESTATUS[@]}")
    return 0
  else
    pipeline_status=("${PIPESTATUS[@]}")
    rc="${pipeline_status[0]:-1}"
    if [ "$rc" -eq 0 ]; then rc="${pipeline_status[1]:-1}"; fi
    log "[ERROR] Command failed (exit $rc): $*"
    return "$rc"
  fi
}
on_error() { rc=$?; echo "[ERROR] Build stopped (exit $rc); out/ and toolchain cache were not cleaned." >&2; echo "[INFO] Log: $LOG" >&2; [ ! -f "$LOG" ] || tail -n 40 "$LOG" >&2; exit "$rc"; }
trap on_error ERR

for cmd in git curl tar make gcc zip bc bison flex perl python3 lz4 lz4c sed od cmp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] Missing build dependency: $cmd" >&2; exit 2; }
done
# Download the pinned Android Clang release and retain partial downloads for retries.
if [ ! -x "$CLANG_BIN/clang" ] || [ ! -x "$CLANG_BIN/ld.lld" ] || [ ! -x "$CLANG_BIN/llvm-objcopy" ]; then
  mkdir -p "$(dirname "$CLANG_ARCHIVE")"
  if [ ! -s "$CLANG_ARCHIVE" ] || ! tar -tzf "$CLANG_ARCHIVE" >/dev/null 2>&1; then
    part="$CLANG_ARCHIVE.part"
    if [ -s "$part" ]; then curl --fail --location --show-error --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 --continue-at - "$CLANG_URL" -o "$part";
    else curl --fail --location --show-error --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 "$CLANG_URL" -o "$part"; fi
    tar -tzf "$part" >/dev/null; mv "$part" "$CLANG_ARCHIVE"
  fi
  stage="$TOOLCHAIN_DIR/.clang-extracting"; rm -rf "$stage"; mkdir -p "$stage"
  log "Extracting $CLANG_REV"; tar -xzf "$CLANG_ARCHIVE" -C "$stage"
  [ -x "$stage/bin/clang" ] && [ -x "$stage/bin/ld.lld" ] && [ -x "$stage/bin/llvm-objcopy" ]
  rm -rf "$CLANG_ROOT"; mv "$stage" "$CLANG_ROOT"; rm -f "$CLANG_ARCHIVE"
fi
export PATH="$CLANG_BIN:$PATH"
log "Compiler: $($CLANG_BIN/clang --version | head -n 1)"

log "Configuring $DEFCONFIG (kernel name: $KERNEL_NAME)"
run_logged make -C "$ROOT" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= "$DEFCONFIG"
# Match LineageOS's build.config.floral_no-cfi profile: it checks floral_defconfig,
# then disables clang LTO/CFI options before olddefconfig. Keep device/DTB settings intact.
for sym in MODULES MODVERSIONS BUILD_ARM64_APPENDED_DTB_IMAGE BUILD_ARM64_DT_OVERLAY; do
  grep -q "^CONFIG_$sym=y$" "$OUT_DIR/.config" || { echo "[ERROR] floral_defconfig lost CONFIG_$sym=y before no-CFI overrides." >&2; exit 1; }
done
run_logged "$ROOT/scripts/config" --file "$OUT_DIR/.config" --disable LTO --disable LTO_CLANG --disable CFI --disable CFI_PERMISSIVE --disable CFI_CLANG --disable THINLTO --disable LOCALVERSION_AUTO --set-str LOCALVERSION ''
run_logged make -C "$ROOT" O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= olddefconfig
for sym in LTO LTO_CLANG CFI CFI_PERMISSIVE CFI_CLANG THINLTO; do
  if grep -q "^CONFIG_$sym=y$" "$OUT_DIR/.config"; then
    echo "[ERROR] CONFIG_$sym=y remains enabled in the official floral_no-cfi profile." >&2
    exit 1
  fi
done
for sym in MODULES MODVERSIONS BUILD_ARM64_APPENDED_DTB_IMAGE BUILD_ARM64_DT_OVERLAY; do
  grep -q "^CONFIG_$sym=y$" "$OUT_DIR/.config" || { echo "[ERROR] floral_no-cfi profile lost CONFIG_$sym=y." >&2; exit 1; }
done
grep -q '^# CONFIG_LOCALVERSION_AUTO is not set$' "$OUT_DIR/.config" || { echo '[ERROR] LOCALVERSION_AUTO must be disabled.' >&2; exit 1; }
grep -q '^CONFIG_LOCALVERSION=""$' "$OUT_DIR/.config" || { echo '[ERROR] CONFIG_LOCALVERSION must be empty for the baseline.' >&2; exit 1; }
if [ -e "$ROOT/KernelSU-Next" ] || [ -e "$ROOT/drivers/kernelsu" ]; then
  echo '[ERROR] KernelSU-Next files remain in the clean baseline source tree.' >&2
  exit 1
fi
if grep -Eq 'CONFIG_KSU|kernelsu' "$ROOT/drivers/Makefile" "$ROOT/drivers/Kconfig"; then
  echo '[ERROR] KernelSU Kconfig/Makefile wiring remains in the clean baseline source tree.' >&2
  exit 1
fi
if grep -q '^CONFIG_KSU' "$OUT_DIR/.config"; then
  echo '[ERROR] KernelSU options remain in the clean baseline .config.' >&2
  exit 1
fi
if [ -z "$JOBS" ]; then JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)"; fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo '[ERROR] JOBS must be a positive integer.' >&2; exit 2; }
log "Compiling stock floral artifacts (Image.lz4 and all DTBs) with $JOBS jobs; no integration patches."
# The installer deliberately preserves the installed ROM's DTBO partition; do not
# call the dtbo.img packaging target, which requires Google's separate mkdtimg prebuilts.
run_logged make -C "$ROOT" O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= -j"$JOBS" Image.lz4 dtbs
IMAGE="$OUT_DIR/arch/arm64/boot/Image.lz4"
RAW_IMAGE="$OUT_DIR/arch/arm64/boot/Image"
DTB_BASE="$OUT_DIR/arch/arm64/boot/dts/google/qcom-base"
[ -s "$IMAGE" ] || { echo "[ERROR] Compiled image not found: $IMAGE" >&2; exit 1; }
[ -s "$RAW_IMAGE" ] || { echo "[ERROR] Uncompressed Image is missing: $RAW_IMAGE" >&2; exit 1; }
# ARM64 Image header magic ("ARM\\x64") lives at byte offset 0x38.
IMAGE_MAGIC="$(od -An -tx1 -j56 -N4 "$RAW_IMAGE" | tr -d '[:space:]')"
[ "$IMAGE_MAGIC" = "41524d64" ] || { echo "[ERROR] Raw Image has an unexpected ARM64 header magic: $IMAGE_MAGIC" >&2; exit 1; }
log "Validating Image.lz4 decodes byte-for-byte to the raw ARM64 Image."
if ! lz4c -d -c "$IMAGE" | cmp -s - "$RAW_IMAGE"; then
  echo '[ERROR] Image.lz4 fails decompression or differs from the raw ARM64 Image.' >&2
  exit 1
fi
[ -s "$DTB_BASE/sm8150.dtb" ] || { echo "[ERROR] Compiled sm8150.dtb missing." >&2; exit 1; }
[ -s "$DTB_BASE/sm8150-v2.dtb" ] || { echo "[ERROR] Compiled sm8150-v2.dtb missing." >&2; exit 1; }
for dtb in "$DTB_BASE/sm8150.dtb" "$DTB_BASE/sm8150-v2.dtb"; do
  DTB_MAGIC="$(od -An -tx1 -N4 "$dtb" | tr -d '[:space:]')"
  [ "$DTB_MAGIC" = "d00dfeed" ] || { echo "[ERROR] Invalid flattened device-tree header in $dtb: $DTB_MAGIC" >&2; exit 1; }
done
KERNELRELEASE="$(make -s -C "$ROOT" O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= kernelrelease)"
EXPECTED_RELEASE="$(awk '$1 == "VERSION" && $2 == "=" { v=$3 } $1 == "PATCHLEVEL" && $2 == "=" { p=$3 } $1 == "SUBLEVEL" && $2 == "=" { s=$3 } $1 == "EXTRAVERSION" && $2 == "=" { e=$3 } END { printf "%s.%s.%s%s", v, p, s, e }' "$ROOT/Makefile")"
[ "$KERNELRELEASE" = "$EXPECTED_RELEASE" ] || { echo "[ERROR] Kernel release $KERNELRELEASE does not match base release $EXPECTED_RELEASE; refuse a module-incompatible suffix." >&2; exit 1; }
SAFE_RELEASE="$(printf '%s' "$KERNELRELEASE" | sed 's/[^A-Za-z0-9._+-]/_/g')"
ZIP_OUT="$DIST_DIR/AnyKernel3-$SAFE_KERNEL_NAME-flame-$SAFE_RELEASE.zip"
# Use a reviewed AnyKernel3 revision rather than cloning a moving master on every build.
if [ ! -d "$AK3_SOURCE/.git" ]; then
  [ ! -e "$AK3_SOURCE" ] || mv "$AK3_SOURCE" "$AK3_SOURCE.incomplete.$(date +%Y%m%d%H%M%S)"
  mkdir -p "$AK3_SOURCE"
  run_logged git -C "$AK3_SOURCE" init
  run_logged git -C "$AK3_SOURCE" remote add origin https://github.com/osm0sis/AnyKernel3.git
fi
run_logged git -C "$AK3_SOURCE" fetch --depth=1 origin "$AK3_COMMIT"
run_logged git -C "$AK3_SOURCE" checkout --detach FETCH_HEAD
run_logged git -C "$AK3_SOURCE" clean -fdx
AK3_ACTUAL_COMMIT="$(git -C "$AK3_SOURCE" rev-parse HEAD)"
[ "$AK3_ACTUAL_COMMIT" = "$AK3_COMMIT" ] || { echo "[ERROR] AnyKernel3 revision mismatch: $AK3_ACTUAL_COMMIT" >&2; exit 1; }
[ -s "$AK3_SOURCE/tools/ak3-core.sh" ] && [ -s "$AK3_SOURCE/anykernel.sh" ]
STAGE_DIR="$(mktemp -d "$OUT_DIR/anykernel3-stage.XXXXXX")"
cp -a "$AK3_SOURCE/." "$STAGE_DIR/"
rm -rf "$STAGE_DIR/.git" "$STAGE_DIR/.github" "$STAGE_DIR/ramdisk" "$STAGE_DIR/patch" "$STAGE_DIR/modules" "$STAGE_DIR/vendor_dlkm" "$STAGE_DIR/vendor_dlkm.img" "$STAGE_DIR/system_dlkm" "$STAGE_DIR/system_dlkm.img"
for f in zImage zImage-dtb Image Image-dtb Image.gz Image.gz-dtb Image.bz2 Image.bz2-dtb Image.lzo Image.lzo-dtb Image.lzma Image.lzma-dtb Image.xz Image.xz-dtb Image.lz4 Image.lz4-dtb Image.fit dtb kernel_dtb dtbo.img; do rm -f "$STAGE_DIR/$f"; done
# Kernel-only update: keep DTB/DTBO from the installed ROM. The standard AnyKernel3
# flow repacks the source ramdisk and preserves the boot image's separate DTB field.
cp "$IMAGE" "$STAGE_DIR/Image.lz4"
printf '%s\n' "$KERNELRELEASE" > "$STAGE_DIR/version"
cat > "$STAGE_DIR/anykernel.sh" <<'AK3'
### AnyKernel3 kernel-only installer for Google Pixel 4 (flame)
properties() { '
kernel.string=__KERNEL_NAME__
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=flame
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
. tools/ak3-core.sh;
# Use the standard AnyKernel3 flow: preserve the source boot image's DTB and
# kernel command line, repack its ramdisk using detected compression, replace the
# kernel payload only, and do not flash DTBO/vendor_dlkm/system_dlkm images.
dump_boot;
write_boot;
AK3
sed -i "s|__KERNEL_NAME__|$KERNEL_NAME|" "$STAGE_DIR/anykernel.sh"
for required in Image.lz4 version anykernel.sh tools/ak3-core.sh; do
  [ -s "$STAGE_DIR/$required" ] || { echo "[ERROR] AnyKernel3 package is missing $required." >&2; exit 1; }
done
grep -Fq 'BLOCK=boot;' "$STAGE_DIR/anykernel.sh"
grep -Fq 'IS_SLOT_DEVICE=1;' "$STAGE_DIR/anykernel.sh"
grep -Fq '. tools/ak3-core.sh;' "$STAGE_DIR/anykernel.sh"
grep -Fq 'dump_boot;' "$STAGE_DIR/anykernel.sh"
grep -Fq 'write_boot;' "$STAGE_DIR/anykernel.sh"
! grep -Fq 'split_boot;' "$STAGE_DIR/anykernel.sh"
! grep -Fq 'flash_boot;' "$STAGE_DIR/anykernel.sh"
! grep -Fq 'reset_ak;' "$STAGE_DIR/anykernel.sh"
bash -n "$STAGE_DIR/anykernel.sh"
ZIP_TMP="$ZIP_OUT.tmp.$$"; rm -f "$ZIP_TMP"
log "Packaging $IMAGE into $ZIP_OUT"
(cd "$STAGE_DIR" && zip -qr9 "$ZIP_TMP" .)
zip -T "$ZIP_TMP" | tee -a "$LOG"; mv -f "$ZIP_TMP" "$ZIP_OUT"; rm -rf "$STAGE_DIR"
log 'SUCCESS'; log "Kernel name: $KERNEL_NAME"; log "Kernel release: $KERNELRELEASE"; log "Kernel image: $IMAGE"; log "AnyKernel3 revision: $AK3_ACTUAL_COMMIT"; log "AnyKernel3 ZIP: $ZIP_OUT"; log "Build log: $LOG"
