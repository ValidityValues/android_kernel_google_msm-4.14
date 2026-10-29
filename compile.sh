#!/usr/bin/env bash
# Pixel 4 (floral) Android 4.14 kernel build + AnyKernel3 package.
# Options: KERNEL_NAME, LTO_MODE=thin|full|none, JOBS.
set -Ee pipefail
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
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
if [ -z "$LTO_MODE" ]; then LTO_MODE=thin; fi
LTO_MODE="$(printf '%s' "$LTO_MODE" | tr '[:upper:]' '[:lower:]')"
case "$LTO_MODE" in
  thin|full|none) ;;
  *) echo '[ERROR] LTO_MODE must be thin, full, or none.' >&2; exit 2 ;;
esac
if ! printf '%s\n' "$KERNEL_NAME" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._ +()-]{0,79}$'; then
  echo '[ERROR] KERNEL_NAME must be 1-80 chars: letters, digits, spaces, . _ + ( ) -' >&2; exit 2
fi
SAFE_KERNEL_NAME="$(printf '%s' "$KERNEL_NAME" | sed -E 's/[[:space:]]+/-/g; s/[^A-Za-z0-9._+-]/_/g')"
KERNEL_VERSION_TAG="$(printf '%s' "$SAFE_KERNEL_NAME" | cut -c1-20)"
LOCALVERSION="-$KERNEL_VERSION_TAG"
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

for cmd in git curl tar make gcc zip bc bison flex perl python3 lz4 sed; do
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
run_logged make -C "$ROOT" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" "$DEFCONFIG"
# Prefer ThinLTO by default: it retains LTO/CFI while reducing the high
# memory/time cost of full LTO during vmlinux.o linking.
case "$LTO_MODE" in
  thin)
    log '[INFO] LTO mode: ThinLTO (CFI remains enabled).'
    run_logged "$ROOT/scripts/config" --file "$OUT_DIR/.config" --enable LTO_CLANG --enable THINLTO --enable CFI_CLANG ;;
  full)
    log '[WARNING] LTO mode: full LTO (high memory usage).'
    run_logged "$ROOT/scripts/config" --file "$OUT_DIR/.config" --enable LTO_CLANG --disable THINLTO --enable CFI_CLANG ;;
  none)
    log '[WARNING] LTO mode: disabled (CFI/LTO protection will be disabled).'
    run_logged "$ROOT/scripts/config" --file "$OUT_DIR/.config" --disable CFI_CLANG --disable THINLTO --disable LTO_CLANG ;;
esac

run_logged "$ROOT/scripts/config" --file "$OUT_DIR/.config" --disable LOCALVERSION_AUTO --set-str LOCALVERSION ''
run_logged make -C "$ROOT" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" olddefconfig
case "$LTO_MODE" in
  thin)
    for sym in LTO_CLANG THINLTO CFI_CLANG; do grep -q "^CONFIG_$sym=y$" "$OUT_DIR/.config" || { echo "[ERROR] CONFIG_$sym=y did not survive olddefconfig for ThinLTO." >&2; exit 1; }; done ;;
  full)
    for sym in LTO_CLANG CFI_CLANG; do grep -q "^CONFIG_$sym=y$" "$OUT_DIR/.config" || { echo "[ERROR] CONFIG_$sym=y did not survive olddefconfig for full LTO." >&2; exit 1; }; done
    if grep -q '^CONFIG_THINLTO=y$' "$OUT_DIR/.config"; then echo '[ERROR] THINLTO unexpectedly enabled in full mode.' >&2; exit 1; fi ;;
  none)
    if grep -qE '^CONFIG_(LTO_CLANG|CFI_CLANG)=y$' "$OUT_DIR/.config"; then echo '[ERROR] LTO/CFI remained enabled after selecting LTO_MODE=none.' >&2; exit 1; fi ;;
esac
if [ -z "$JOBS" ]; then JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)"; fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo '[ERROR] JOBS must be a positive integer.' >&2; exit 2; }
log "Compiling clean Image.lz4 baseline with $JOBS jobs (no integration patches)."
run_logged make -C "$ROOT" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" -j"$JOBS" Image.lz4
IMAGE="$OUT_DIR/arch/arm64/boot/Image.lz4"
[ -s "$IMAGE" ] || { echo "[ERROR] Compiled image not found: $IMAGE" >&2; exit 1; }
KERNELRELEASE="$(make -s -C "$ROOT" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" kernelrelease)"
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
AK3_ACTUAL_COMMIT="$(git -C "$AK3_SOURCE" rev-parse HEAD)"
[ "$AK3_ACTUAL_COMMIT" = "$AK3_COMMIT" ] || { echo "[ERROR] AnyKernel3 revision mismatch: $AK3_ACTUAL_COMMIT" >&2; exit 1; }
[ -s "$AK3_SOURCE/tools/ak3-core.sh" ] && [ -s "$AK3_SOURCE/anykernel.sh" ]
STAGE_DIR="$(mktemp -d "$OUT_DIR/anykernel3-stage.XXXXXX")"
cp -a "$AK3_SOURCE/." "$STAGE_DIR/"; rm -rf "$STAGE_DIR/.git" "$STAGE_DIR/ramdisk" "$STAGE_DIR/patch"
for f in zImage zImage-dtb Image Image-dtb Image.gz Image.gz-dtb Image.bz2 Image.bz2-dtb Image.lzo Image.lzo-dtb Image.lzma Image.lzma-dtb Image.xz Image.xz-dtb Image.lz4 Image.lz4-dtb Image.fit dtb kernel_dtb dtbo.img; do rm -f "$STAGE_DIR/$f"; done
# Kernel-only update: do not package a different ROM's DTB/DTBO. AnyKernel3 will preserve
# the boot image's current ramdisk and embedded DTB and leave the dtbo partition untouched.
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
# Kernel-only replacement: avoid unpacking/repacking an untouched ramdisk.
split_boot;
flash_boot;
AK3
sed -i "s|__KERNEL_NAME__|$KERNEL_NAME|" "$STAGE_DIR/anykernel.sh"
ZIP_TMP="$ZIP_OUT.tmp.$$"; rm -f "$ZIP_TMP"
log "Packaging $IMAGE into $ZIP_OUT"
(cd "$STAGE_DIR" && zip -qr9 "$ZIP_TMP" .)
zip -T "$ZIP_TMP" | tee -a "$LOG"; mv -f "$ZIP_TMP" "$ZIP_OUT"; rm -rf "$STAGE_DIR"
log 'SUCCESS'; log "Kernel name: $KERNEL_NAME"; log "Kernel release: $KERNELRELEASE"; log "Kernel image: $IMAGE"; log "AnyKernel3 revision: $AK3_ACTUAL_COMMIT"; log "AnyKernel3 ZIP: $ZIP_OUT"; log "Build log: $LOG"
