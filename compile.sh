#!/usr/bin/env bash
# Pixel 4 (floral) Android 4.14 kernel build + AnyKernel3 package.
# Options: KERNEL_NAME, KSU_NEXT, KSU_HOOK_MODE=kprobes|manual, JOBS.
set -Ee pipefail
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
OUT_DIR="$ROOT/out"
TOOLCHAIN_DIR="$ROOT/.toolchains"
DIST_DIR="$ROOT/dist"
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
KSU_REPO_URL=https://github.com/KernelSU-Next/KernelSU-Next.git
KSU_BRANCH=legacy

if [ -z "$KERNEL_NAME" ]; then KERNEL_NAME='Validity Pixel 4 Kernel'; fi
if ! printf '%s\n' "$KERNEL_NAME" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._ +()-]{0,79}$'; then
  echo '[ERROR] KERNEL_NAME must be 1-80 chars: letters, digits, spaces, . _ + ( ) -' >&2; exit 2
fi
SAFE_KERNEL_NAME="$(printf '%s' "$KERNEL_NAME" | sed -E 's/[[:space:]]+/-/g; s/[^A-Za-z0-9._+-]/_/g')"
KERNEL_VERSION_TAG="$(printf '%s' "$SAFE_KERNEL_NAME" | cut -c1-20)"
LOCALVERSION="-$KERNEL_VERSION_TAG"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
run_logged() { log "+ $*"; "$@" 2>&1 | tee -a "$LOG"; }
on_error() { rc=$?; echo "[ERROR] Build stopped (exit $rc); out/ and toolchain cache were not cleaned." >&2; echo "[INFO] Log: $LOG" >&2; [ ! -f "$LOG" ] || tail -n 40 "$LOG" >&2; exit "$rc"; }
trap on_error ERR

for cmd in git curl tar make gcc zip bc bison flex perl python3 lz4 sed; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] Missing build dependency: $cmd" >&2; exit 2; }
done
if [ -z "$KSU_NEXT" ]; then
  if [ -t 0 ]; then read -r -p 'Integrate KernelSU-Next? [y/N] ' answer || true; else answer=n; fi
  case "${answer,,}" in y|yes) KSU_NEXT=y ;; *) KSU_NEXT=n ;; esac
fi
case "${KSU_NEXT,,}" in y|yes|true|1|on) KSU_ENABLED=1 ;; n|no|false|0|off) KSU_ENABLED=0 ;; *) echo '[ERROR] KSU_NEXT must be true/false or y/n.' >&2; exit 2 ;; esac
if [ "$KSU_ENABLED" -eq 1 ] && [ -z "$KSU_HOOK_MODE" ]; then echo '[ERROR] Set KSU_HOOK_MODE=kprobes or manual.' >&2; exit 2; fi

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

if [ "$KSU_ENABLED" -eq 1 ]; then
  KSU_DIR="$ROOT/KernelSU-Next"
  if [ -d "$KSU_DIR/.git" ]; then
    run_logged git -C "$KSU_DIR" fetch --depth=1 origin "$KSU_BRANCH"
    run_logged git -C "$KSU_DIR" checkout -B "$KSU_BRANCH" FETCH_HEAD
  else
    [ ! -e "$KSU_DIR" ] || mv "$KSU_DIR" "$KSU_DIR.incomplete.$(date +%Y%m%d%H%M%S)"
    git clone --depth=1 --branch "$KSU_BRANCH" "$KSU_REPO_URL" "$KSU_DIR" 2>&1 | tee -a "$LOG"
  fi
  run_logged git -C "$KSU_DIR" submodule update --init --recursive
  [ -f "$KSU_DIR/kernel/Kconfig" ]
  [ ! -e "$ROOT/drivers/kernelsu" ] || [ -L "$ROOT/drivers/kernelsu" ] || { echo '[ERROR] drivers/kernelsu exists but is not a symlink.' >&2; exit 1; }
  ln -sfn ../KernelSU-Next/kernel "$ROOT/drivers/kernelsu"
  python3 - "$ROOT/drivers/Makefile" "$ROOT/drivers/Kconfig" <<'PY_KSU'
from pathlib import Path
import sys
mf, kf = map(Path, sys.argv[1:])
text = mf.read_text(); line = 'obj-$(CONFIG_KSU) += kernelsu/'
if line not in text: mf.write_text(text.rstrip() + '\n' + line + '\n')
text = kf.read_text(); line = 'source "drivers/kernelsu/Kconfig"'
if line not in text:
    pos = text.rfind('endmenu')
    if pos < 0: raise SystemExit('Could not find endmenu in drivers/Kconfig')
    kf.write_text(text[:pos] + line + '\n' + text[pos:])
PY_KSU
  # The 4.14 tree backports __poll_t, but KSU legacy has a conflicting <4.16 fallback.
  KSU_EVENT="$KSU_DIR/kernel/infra/event_queue.h"
  if grep -Eq 'typedef[[:space:]]+unsigned[[:space:]]+(__bitwise[[:space:]]+)?__poll_t;' "$ROOT/include/uapi/linux/types.h" && grep -Fq 'typedef unsigned int __poll_t;' "$KSU_EVENT"; then
    python3 - "$KSU_EVENT" <<'PY_POLL'
from pathlib import Path
import re, sys
p = Path(sys.argv[1]); s = p.read_text()
pat = r'(?m)^#if LINUX_VERSION_CODE < KERNEL_VERSION\(4, 16, 0\)\r?\ntypedef unsigned int __poll_t;\r?\n#endif\r?\n?'
s, n = re.subn(pat, '', s, count=1)
if not n: raise SystemExit('Found __poll_t conflict, but guarded block did not match.')
p.write_text(s)
PY_POLL
  fi
fi

log "Configuring $DEFCONFIG (kernel name: $KERNEL_NAME)"
run_logged make -C "$ROOT" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" "$DEFCONFIG"
if [ "$KSU_ENABLED" -eq 1 ]; then
  case "${KSU_HOOK_MODE,,}" in
    kprobes|kprobe)
      log '[WARNING] Kprobes is experimental on Linux 4.14; Shadow Call Stack will be disabled (reduced return-address protection).'
      run_logged "$ROOT/scripts/config" --file "$OUT_DIR/.config" --disable SHADOW_CALL_STACK --enable ROP_PROTECTION_NONE --enable KPROBES --enable KRETPROBES --enable KPROBE_EVENTS --enable KSU --disable KSU_MANUAL_HOOK --enable KSU_KPROBES_HOOK
      EXPECTED='KPROBES KRETPROBES KPROBE_EVENTS KSU KSU_KPROBES_HOOK ROP_PROTECTION_NONE' ;;
    manual)
      if ! grep -q 'ksu_handle_sys_reboot' "$ROOT/kernel/reboot.c"; then echo '[ERROR] Manual mode requires KernelSU-Next manual-hook patches; this source branch does not have them.' >&2; exit 2; fi
      run_logged "$ROOT/scripts/config" --file "$OUT_DIR/.config" --enable KPROBES --enable KPROBE_EVENTS --enable KSU --enable KSU_MANUAL_HOOK --disable KSU_KPROBES_HOOK
      EXPECTED='KPROBES KPROBE_EVENTS KSU KSU_MANUAL_HOOK' ;;
    *) echo "[ERROR] KSU_HOOK_MODE must be kprobes or manual (got: $KSU_HOOK_MODE)." >&2; exit 2 ;;
  esac
fi
run_logged "$ROOT/scripts/config" --file "$OUT_DIR/.config" --disable LOCALVERSION_AUTO --set-str LOCALVERSION ''
run_logged make -C "$ROOT" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" olddefconfig
if [ "$KSU_ENABLED" -eq 1 ]; then for sym in $EXPECTED; do grep -q "^CONFIG_$sym=y$" "$OUT_DIR/.config" || { echo "[ERROR] CONFIG_$sym=y did not survive olddefconfig." >&2; exit 1; }; done; fi
if [ -z "$JOBS" ]; then JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)"; fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo '[ERROR] JOBS must be a positive integer.' >&2; exit 2; }
log "Compiling Image.lz4 with $JOBS jobs; existing out/ objects are retained."
run_logged make -C "$ROOT" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" -j"$JOBS" Image.lz4
IMAGE="$OUT_DIR/arch/arm64/boot/Image.lz4"
[ -s "$IMAGE" ] || { echo "[ERROR] Compiled image not found: $IMAGE" >&2; exit 1; }
KERNELRELEASE="$(make -s -C "$ROOT" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" kernelrelease)"
SAFE_RELEASE="$(printf '%s' "$KERNELRELEASE" | sed 's/[^A-Za-z0-9._+-]/_/g')"
KSU_TAG=''; if [ "$KSU_ENABLED" -eq 1 ]; then KSU_TAG=-ksun; fi
ZIP_OUT="$DIST_DIR/AnyKernel3-$SAFE_KERNEL_NAME-flame-$SAFE_RELEASE$KSU_TAG.zip"
if [ ! -f "$AK3_SOURCE/tools/ak3-core.sh" ] || [ ! -f "$AK3_SOURCE/anykernel.sh" ]; then
  if [ -d "$AK3_SOURCE/.git" ]; then run_logged git -C "$AK3_SOURCE" fetch --depth=1 origin master; run_logged git -C "$AK3_SOURCE" reset --hard FETCH_HEAD;
  else [ ! -e "$AK3_SOURCE" ] || mv "$AK3_SOURCE" "$AK3_SOURCE.incomplete.$(date +%Y%m%d%H%M%S)"; git clone --depth=1 --branch master https://github.com/osm0sis/AnyKernel3.git "$AK3_SOURCE" 2>&1 | tee -a "$LOG"; fi
fi
[ -f "$AK3_SOURCE/tools/ak3-core.sh" ] && [ -f "$AK3_SOURCE/anykernel.sh" ]
STAGE_DIR="$(mktemp -d "$OUT_DIR/anykernel3-stage.XXXXXX")"
cp -a "$AK3_SOURCE/." "$STAGE_DIR/"; rm -rf "$STAGE_DIR/.git" "$STAGE_DIR/ramdisk" "$STAGE_DIR/patch"
for f in zImage zImage-dtb Image Image-dtb Image.gz Image.gz-dtb Image.bz2 Image.bz2-dtb Image.lzo Image.lzo-dtb Image.lzma Image.lzma-dtb Image.xz Image.xz-dtb Image.lz4 Image.lz4-dtb Image.fit dtb kernel_dtb dtbo.img; do rm -f "$STAGE_DIR/$f"; done
cp "$IMAGE" "$STAGE_DIR/Image.lz4"
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
BLOCK=auto;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
. tools/ak3-core.sh;
dump_boot;
write_boot;
AK3
sed -i "s|__KERNEL_NAME__|$KERNEL_NAME|" "$STAGE_DIR/anykernel.sh"
ZIP_TMP="$ZIP_OUT.tmp.$$"; rm -f "$ZIP_TMP"
log "Packaging $IMAGE into $ZIP_OUT"
(cd "$STAGE_DIR" && zip -qr9 "$ZIP_TMP" .)
zip -T "$ZIP_TMP" | tee -a "$LOG"; mv -f "$ZIP_TMP" "$ZIP_OUT"; rm -rf "$STAGE_DIR"
log 'SUCCESS'; log "Kernel name: $KERNEL_NAME"; log "Kernel release: $KERNELRELEASE"; log "Kernel image: $IMAGE"; log "AnyKernel3 ZIP: $ZIP_OUT"; log "Build log: $LOG"
if [ "$KSU_ENABLED" -eq 1 ]; then log "KernelSU-Next enabled; hook mode: $KSU_HOOK_MODE"; else log 'KernelSU-Next disabled'; fi
