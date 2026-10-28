#!/usr/bin/env bash
# Pixel 4 (floral) Android 4.14 kernel build + AnyKernel3 package.
# Options: KERNEL_NAME, KSU_NEXT, KSU_HOOK_MODE=manual, LTO_MODE=thin|full|none, JOBS.
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
KSU_COMMIT=b933b1f728116a456fbebf27b6a8772a640cdf23

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
if [ -z "$KSU_NEXT" ]; then
  if [ -t 0 ]; then read -r -p 'Integrate KernelSU-Next? [y/N] ' answer || true; else answer=n; fi
  case "${answer,,}" in y|yes) KSU_NEXT=y ;; *) KSU_NEXT=n ;; esac
fi
case "${KSU_NEXT,,}" in y|yes|true|1|on) KSU_ENABLED=1 ;; n|no|false|0|off) KSU_ENABLED=0 ;; *) echo '[ERROR] KSU_NEXT must be true/false or y/n.' >&2; exit 2 ;; esac
if [ "$KSU_ENABLED" -eq 1 ] && [ -z "$KSU_HOOK_MODE" ]; then KSU_HOOK_MODE=manual; fi
if [ "$KSU_ENABLED" -eq 1 ] && [ "${KSU_HOOK_MODE,,}" != manual ]; then
  echo '[ERROR] Only KSU_HOOK_MODE=manual is supported; kprobes are disabled for this device.' >&2
  exit 2
fi

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
  KSU_ACTUAL_COMMIT="$(git -C "$KSU_DIR" rev-parse HEAD)"
  if [ "$KSU_ACTUAL_COMMIT" != "$KSU_COMMIT" ]; then
    echo "[ERROR] KernelSU-Next legacy revision changed; expected $KSU_COMMIT, got $KSU_ACTUAL_COMMIT. Re-audit the API before changing KSU_COMMIT." >&2
    exit 1
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

  # KernelSU-Next's legacy branch may select path_umount() when
  # KSU_HAS_PATH_UMOUNT is defined, but this Linux 4.14 tree does not provide
  # that symbol. Force its existing pre-5.9 sys_umount() compatibility path.
  KSU_UMOUNT="$KSU_DIR/kernel/feature/kernel_umount.c"
  if [ -f "$KSU_UMOUNT" ]; then
    python3 - "$KSU_UMOUNT" <<'PY_UMOUNT'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()
original = s

old_include = "#ifndef KSU_HAS_PATH_UMOUNT\n#include <linux/syscalls.h>\n#endif"
new_include = "#include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n#include <linux/syscalls.h>\n#endif"
already_patched_include = "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n#include <linux/syscalls.h>\n#endif"
if old_include in s:
    s = s.replace(old_include, new_include, 1)
elif new_include in s:
    pass
elif already_patched_include in s:
    s = s.replace(already_patched_include, new_include, 1)
else:
    raise SystemExit("Could not safely patch KernelSU kernel_umount.c syscalls include guard.")

old_cond = re.compile(
    r"(?m)^#if LINUX_VERSION_CODE >= KERNEL_VERSION\(5, 9, 0\) \|\|[ \t]*\\\r?\n[ \t]*defined\(KSU_HAS_PATH_UMOUNT\)$"
)
s, count = old_cond.subn("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)", s, count=1)
if count == 0 and "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\nextern int path_umount" not in s:
    raise SystemExit("Could not safely patch KernelSU path_umount version guard.")

if s != original:
    p.write_text(s)
    print("Patched KernelSU kernel_umount.c for Linux 4.14 sys_umount compatibility.")
else:
    print("KernelSU kernel_umount.c compatibility patch already applied.")
PY_UMOUNT
  fi
fi

if [ "$KSU_ENABLED" -eq 1 ]; then
  # Integrate the current KernelSU-Next legacy API at direct kernel call sites.
  # The web guide refers to old sys_read/sys_reboot handlers not defined by
  # this branch; use the actual vfs-read helper exported by this branch.
  python3 - "$ROOT" "$KSU_DIR" <<'PY_MANUAL'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
ksu = Path(sys.argv[2])

def read(rel):
    p = root / rel
    if not p.is_file():
        raise SystemExit("Manual KSU hook: missing source file: " + rel)
    return p, p.read_text()

# execve/execveat, native and compat.
p, s = read("fs/exec.c")
if "extern int ksu_handle_execveat_ksud(" not in s:
    needle = '#include "internal.h"'
    if needle not in s:
        raise SystemExit("Manual KSU hook: fs/exec.c include anchor not found")
    s = s.replace(needle, needle + '''

#ifdef CONFIG_KSU
struct user_arg_ptr;
extern int ksu_handle_execveat_ksud(int *fd, struct filename **filename_ptr,
                                    struct user_arg_ptr *argv,
                                    struct user_arg_ptr *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                                        void *argv, void *envp, int *flags);
#endif''', 1)

def patch_exec_function(source, name, use_params):
    pattern = re.compile(r"(?ms)^(?:static\s+)?int\s+" + re.escape(name) + r"\b[^{]*\n\{.*?^}")
    m = pattern.search(source)
    if not m:
        raise SystemExit("Manual KSU hook: function not found in fs/exec.c: " + name)
    body = m.group(0)
    marker = "/* KSU-NEXT manual hook: " + name + " */"
    if marker in body:
        return source
    ret = re.compile(r"(?m)^\treturn do_execveat_common\(([^;]+)\);")
    match = ret.search(body)
    if not match:
        raise SystemExit("Manual KSU hook: do_execveat_common return not found in " + name)
    if use_params:
        call = (
            "#ifdef CONFIG_KSU\n"
            "\t" + marker + "\n"
            "\tksu_handle_execveat_ksud(&fd, &filename, &argv, &envp, &flags);\n"
            "\tksu_handle_execveat_sucompat(&fd, &filename, (void *)__argv, (void *)__envp, &flags);\n"
            "\treturn do_execveat_common(fd, filename, argv, envp, flags);\n"
            "#else\n"
            "\treturn do_execveat_common(" + match.group(1) + ");\n"
            "#endif"
        )
    else:
        call = (
            "#ifdef CONFIG_KSU\n"
            "\t" + marker + "\n"
            "\t{\n"
            "\t\tint ksu_fd = AT_FDCWD;\n"
            "\t\tint ksu_flags = 0;\n"
            "\t\tksu_handle_execveat_ksud(&ksu_fd, &filename, &argv, &envp, &ksu_flags);\n"
            "\t\tksu_handle_execveat_sucompat(&ksu_fd, &filename, (void *)__argv, (void *)__envp, &ksu_flags);\n"
            "\t\treturn do_execveat_common(ksu_fd, filename, argv, envp, ksu_flags);\n"
            "\t}\n"
            "#else\n"
            "\treturn do_execveat_common(" + match.group(1) + ");\n"
            "#endif"
        )
    updated, n = ret.subn(lambda _: call, body, count=1)
    if n != 1:
        raise SystemExit("Manual KSU hook: failed to insert exec hook in " + name)
    return source[:m.start()] + updated + source[m.end():]

for name, use_params in (
    ("do_execve", False),
    ("do_execveat", True),
    ("compat_do_execve", False),
    ("compat_do_execveat", True),
):
    s = patch_exec_function(s, name, use_params)
p.write_text(s)

# faccessat.
p, s = read("fs/open.c")
decl = '''#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
                                int *mode, int *flags);
#endif'''
if "extern int ksu_handle_faccessat(" not in s:
    needle = '#include "internal.h"'
    if needle not in s:
        raise SystemExit("Manual KSU hook: fs/open.c include anchor not found")
    s = s.replace(needle, needle + "\n\n" + decl, 1)
needle = "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n{\n"
marker = "/* KSU-NEXT manual hook: faccessat */"
if marker not in s:
    if needle not in s:
        raise SystemExit("Manual KSU hook: faccessat syscall anchor not found")
    start = s.index(needle) + len(needle)
    point = s.find("\tif (mode & ~S_IRWXO)", start)
    if point < 0:
        raise SystemExit("Manual KSU hook: faccessat post-declaration anchor not found")
    call = "\t" + marker + "\n#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\n"
    s = s[:point] + call + s[point:]
p.write_text(s)

# vfs_read: current legacy helper uses a struct file**/buffer/count/pos API.
p, s = read("fs/read_write.c")
needle = "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)\n{\n"
decl = """#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook;
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
                               size_t *count_ptr, loff_t **pos);
#endif

"""
if "extern int ksu_handle_vfs_read(" not in s:
    if needle not in s:
        raise SystemExit("Manual KSU hook: vfs_read function anchor not found")
    s = s.replace(needle, decl + needle, 1)
body = needle + "\tssize_t ret;\n"
if "KSU-NEXT manual hook: vfs_read" not in s:
    if body not in s:
        raise SystemExit("Manual KSU hook: vfs_read declaration anchor not found")
    call = body + """#ifdef CONFIG_KSU
\t/* KSU-NEXT manual hook: vfs_read */
\tif (unlikely(ksu_vfs_read_hook))
\t\tksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif

"""
    s = s.replace(body, call, 1)
p.write_text(s)

# newfstatat native and compat.
p, s = read("fs/stat.c")
decl = '''#ifdef CONFIG_KSU
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif'''
if "extern int ksu_handle_stat(" not in s:
    needle = '#include <linux/uaccess.h>'
    if needle not in s:
        raise SystemExit("Manual KSU hook: fs/stat.c include anchor not found")
    s = s.replace(needle, needle + "\n\n" + decl, 1)
needle = ("SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,\n"
          "\t\tstruct stat __user *, statbuf, int, flag)\n{\n")
marker = "/* KSU-NEXT manual hook: newfstatat */"
target = "\tstruct kstat stat;\n\tint error;\n\n\terror = vfs_fstatat(dfd, filename, &stat, flag);"
if marker not in s:
    start = s.find(needle)
    if start < 0:
        raise SystemExit("Manual KSU hook: newfstatat syscall anchor not found")
    pos = s.find(target, start)
    if pos < 0:
        raise SystemExit("Manual KSU hook: newfstatat post-declaration anchor not found")
    hook = "\t" + marker + "\n#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n\n"
    s = s[:pos] + target.replace("\n\n\terror = vfs_fstatat", "\n\n" + hook + "\terror = vfs_fstatat") + s[pos + len(target):]
needle = ("COMPAT_SYSCALL_DEFINE4(newfstatat, unsigned int, dfd,\n"
          "\t\t       const char __user *, filename,\n"
          "\t\t       struct compat_stat __user *, statbuf, int, flag)\n{\n")
marker = "/* KSU-NEXT manual hook: compat_newfstatat */"
target = "\tstruct kstat stat;\n\tint error;\n\n\terror = vfs_fstatat(dfd, filename, &stat, flag);"
if marker not in s:
    start = s.find(needle)
    if start < 0:
        raise SystemExit("Manual KSU hook: compat newfstatat anchor not found")
    pos = s.find(target, start)
    if pos < 0:
        raise SystemExit("Manual KSU hook: compat newfstatat post-declaration anchor not found")
    hook = "\t" + marker + "\n#ifdef CONFIG_KSU\n\tksu_handle_stat((int *)&dfd, &filename, &flag);\n#endif\n\n"
    s = s[:pos] + target.replace("\n\n\terror = vfs_fstatat", "\n\n" + hook + "\terror = vfs_fstatat") + s[pos + len(target):]
p.write_text(s)

# setresuid is handled by KernelSU-Next's direct non-kprobe LSM task_fix_setuid hook.
# Replace the current branch's stale ksu_handle_sys_reboot check with checks
# for the actual call sites inserted above.
p = ksu / "kernel/Kbuild"
s = p.read_text()
# This legacy branch uses mixed declarations; suppress this warning only inside
# KernelSU-Next so the older kernel's gnu89 -Werror policy remains unchanged.
if "ccflags-y += -Wno-declaration-after-statement" not in s:
    s = "ccflags-y += -Wno-declaration-after-statement\n" + s
old = 'HAVE_KSU_HOOK := $(shell grep -q "ksu_handle_sys_reboot" $(srctree)/kernel/reboot.c && echo 0 || echo 1)'
new = ('HAVE_KSU_HOOK := $(shell grep -q "ksu_handle_execveat_ksud" $(srctree)/fs/exec.c && '
       'grep -q "ksu_handle_execveat_sucompat" $(srctree)/fs/exec.c && '
       'grep -q "ksu_handle_faccessat" $(srctree)/fs/open.c && '
       'grep -q "ksu_handle_vfs_read" $(srctree)/fs/read_write.c && '
       'grep -q "ksu_handle_stat" $(srctree)/fs/stat.c && echo 0 || echo 1)')
if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit("Manual KSU hook: unable to update legacy KernelSU Kbuild prerequisite check")
p.write_text(s)

checks = {
    "fs/exec.c": (
        "KSU-NEXT manual hook: do_execve",
        "KSU-NEXT manual hook: do_execveat",
        "KSU-NEXT manual hook: compat_do_execve",
        "KSU-NEXT manual hook: compat_do_execveat",
    ),
    "fs/open.c": ("KSU-NEXT manual hook: faccessat",),
    "fs/read_write.c": ("KSU-NEXT manual hook: vfs_read",),
    "fs/stat.c": (
        "KSU-NEXT manual hook: newfstatat",
        "KSU-NEXT manual hook: compat_newfstatat",
    ),
}
for rel, markers in checks.items():
    _, s = read(rel)
    for marker in markers:
        if marker not in s:
            raise SystemExit("Manual KSU hook verification failed: " + rel + " missing " + marker)

print("KernelSU-Next manual hooks patched and verified (execve/execveat native+compat, faccessat, vfs_read, newfstatat native+compat; setresuid via non-kprobe LSM hook).")
PY_MANUAL
fi
log "Configuring $DEFCONFIG (kernel name: $KERNEL_NAME)"
run_logged make -C "$ROOT" O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" "$DEFCONFIG"
if [ "$KSU_ENABLED" -eq 1 ]; then
  case "${KSU_HOOK_MODE,,}" in
    manual)
      log '[INFO] KernelSU-Next hook mode: manual; kprobes and syscall-table hooks are disabled.'
      run_logged "$ROOT/scripts/config" --file "$OUT_DIR/.config" --enable KSU --enable KSU_MANUAL_HOOK --disable KSU_KPROBES_HOOK --disable KSU_SYSCALL_TABLE_HOOK --disable KPROBES --disable KRETPROBES --disable KPROBE_EVENTS
      EXPECTED='KSU KSU_MANUAL_HOOK' ;;
    *) echo "[ERROR] Only KSU_HOOK_MODE=manual is supported (got: $KSU_HOOK_MODE)." >&2; exit 2 ;;
  esac
fi
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
if [ "$KSU_ENABLED" -eq 1 ]; then
  for sym in $EXPECTED; do grep -q "^CONFIG_$sym=y$" "$OUT_DIR/.config" || { echo "[ERROR] CONFIG_$sym=y did not survive olddefconfig." >&2; exit 1; }; done
  if grep -qE '^CONFIG_(KPROBES|KRETPROBES|KPROBE_EVENTS|KSU_KPROBES_HOOK)=y$' "$OUT_DIR/.config"; then
    echo '[ERROR] Kprobes-related configuration remained enabled in manual mode.' >&2; exit 1
  fi
fi
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
