#!/usr/bin/env bash
#
# mayhem/build.sh — builds Haiku's userland file-system shell (src/tools/fs_shell, the same code
# `jam bfs_shell` builds) with the BFS driver, plus the libFuzzer harness over it, and the
# un-sanitized bfs_shell the functional test (mayhem/test.sh) drives.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
H="$SRC"
FSSH="$H/src/tools/fs_shell"
FSDIR="$H/src/add-ons/kernel/file_systems"

# Same defines and include directories as src/tools/fs_shell/Jamfile + src/tools/bfs_shell/Jamfile,
# for a Linux host.
INC=(-I"$H/headers/build" -I"$H/headers/build/os" -I"$H/headers/build/os/kernel"
     -I"$H/headers/build/os/storage" -I"$H/headers/build/os/support"
     -I"$H/headers/private/fs_shell" -I"$H/headers/private/shared"
     -I"$H/headers/private/file_systems" -I"$H/headers/private" -I"$FSSH" -I"$FSDIR/bfs" -I"$FSDIR/shared")
DEF=(-DFS_SHELL=1 -DHAIKU_BUILD_COMPATIBILITY_H -D__STRICT_ANSI__ -D_GNU_SOURCE
     -D_FILE_OFFSET_BITS=64 -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS
     -DHAIKU_HOST_PLATFORM_LINUX -DHAIKU_HOST_PLATFORM_64_BIT -DARCH_x86_64 -D_NO_INLINE_ASM
     -Wno-multichar)

# fs_shell kernel emulation ("fs_shell_kernel.o" in the Jamfile)
KERNEL_SRC=(atomic block_cache byte_order command_cp convertutf disk_device_manager driver_settings
            errno fcntl fd file_cache hash kernel_export KPath list lock module node_monitor
            partition_support path_util sem stat stat_util stdio string thread time uio unistd vfs)
SHELL_SRC=(external_commands_unix)
SRCS=()
for f in "${KERNEL_SRC[@]}" "${SHELL_SRC[@]}"; do SRCS+=("$FSSH/$f.cpp"); done
SRCS+=("$H/src/system/kernel/fs/rootfs.cpp" "$H/src/system/kernel/cache/file_map.cpp")

# The BFS driver and its shell commands (src/tools/bfs_shell/Jamfile)
for f in bfs_disk_system BlockAllocator BPlusTree Attribute CheckVisitor Debug FileSystemVisitor \
         Index Inode Journal Query ResizeVisitor Volume kernel_interface; do
  SRCS+=("$FSDIR/bfs/$f.cpp")
done
SRCS+=("$FSDIR/shared/DeviceOpener.cpp" "$FSDIR/shared/QueryParserUtils.cpp")
SRCS+=("$H/src/tools/bfs_shell/additional_commands.cpp" "$H/src/tools/bfs_shell/command_checkfs.cpp"
       "$H/src/tools/bfs_shell/command_resizefs.cpp")

# The host compatibility "libroot" fs_shell links against (src/build/libroot/Jamfile): errno/semaphore/
# thread/attribute emulation. Built from source, linked statically.
ROOT_SRC=()
for f in atomic byteorder errors fs fs_attr fs_descriptors misc sem thread; do
  ROOT_SRC+=("$H/src/build/libroot/$f.cpp")
done
ROOT_INC=(-I"$H/headers/build" -I"$H/headers/build/os" -I"$H/headers/build/os/app"
          -I"$H/headers/build/os/drivers" -I"$H/headers/build/os/kernel"
          -I"$H/headers/build/os/interface" -I"$H/headers/build/os/storage"
          -I"$H/headers/build/os/support" -I"$H/headers/build/private/kernel"
          -I"$H/headers/build/private/libroot" -I"$H/headers/build/private/system"
          -I"$H/headers/private/system")
ROOT_DEF=(-D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS
          -DHAIKU_HOST_PLATFORM_LINUX -DHAIKU_HOST_PLATFORM_64_BIT -DARCH_x86_64 -D_NO_INLINE_ASM
          -include "$H/headers/build/BeOSBuildCompatibility.h" -DHAIKU_HOST_USE_XATTR -D_HAIKU_BUILD_DONT_REMAP_FD_FUNCTIONS=1
          '-DHAIKU_BUILD_ATTRIBUTES_DIR="/nonexistent"' -Wno-multichar)

# compile_all <objdir> <flags...> : one object per source, in parallel
compile_all() {
  local out="$1"; shift
  mkdir -p "$out"
  printf '%s\n' "${SRCS[@]}" | xargs -P "$MAYHEM_JOBS" -I{} bash -c '
    f="$1"; out="$2"; shift 2
    extra=(); [ "$(basename "$f")" = QueryParserUtils.cpp ] && extra=(-fno-sanitize=alignment)
    exec "$CXX" -std=c++11 -w -fno-rtti -c "$f" "$@" "${extra[@]}" -o "$out/$(basename "${f%.cpp}").o"' _ {} "$out" \
    "${INC[@]}" "${DEF[@]}" "$@"
  printf '%s\n' "${ROOT_SRC[@]}" | xargs -P "$MAYHEM_JOBS" -I{} bash -c '
    f="$1"; out="$2"; shift 2
    extra=(); [ "$(basename "$f")" = errors.cpp ] && extra=(-DBUILDING_HAIKU_ERROR_MAPPER=1)
    exec "$CXX" -std=c++11 -w -c "$f" "${extra[@]}" "$@" -o "$out/root_$(basename "${f%.cpp}").o"' _ {} "$out" \
    "${ROOT_INC[@]}" "${ROOT_DEF[@]}" "$@"
}

# 1) Sanitized + instrumented project objects, for the fuzz harness.
#    fuzzer-no-link: SanCov on the fuzzed code; the engine is linked per binary below.
FUZZ_FLAGS=($SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1)
OBJ="$SRC/mayhem/build/fuzz"
rm -rf "$OBJ"
compile_all "$OBJ" "${FUZZ_FLAGS[@]}"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

# fssh.cpp is compiled into the harness translation unit (its `main` renamed).
$CXX -std=c++11 -w -fno-rtti "${FUZZ_FLAGS[@]}" "${INC[@]}" "${DEF[@]}" -DFS_HARNESS_CHECKFS=1 \
  "-DFS_HARNESS_BASE_DIR=\"$SRC/mayhem/fuzz_bfs/base\"" \
  -c "$SRC/mayhem/fs_harness.cpp" -o "$OBJ/fs_harness.o"

PROJECT_OBJS=()
for o in "$OBJ"/*.o; do
  case "$(basename "$o")" in fs_harness.o|standalone_main.o) ;; *) PROJECT_OBJS+=("$o") ;; esac
done
$CXX "${FUZZ_FLAGS[@]}" $LIB_FUZZING_ENGINE "$OBJ/fs_harness.o" "${PROJECT_OBJS[@]}" -o /mayhem/fuzz_bfs
$CXX "${FUZZ_FLAGS[@]}" "$OBJ/standalone_main.o" "$OBJ/fs_harness.o" "${PROJECT_OBJS[@]}" \
  -o /mayhem/fuzz_bfs-standalone

# 2) Plain (NORMAL flags) bfs_shell for the functional test.
TOBJ="$SRC/mayhem/build/test"
rm -rf "$TOBJ"
compile_all "$TOBJ" -O1 $COVERAGE_FLAGS
$CXX -std=c++11 -w -fno-rtti -O1 $COVERAGE_FLAGS "${INC[@]}" "${DEF[@]}" -c "$FSSH/fssh.cpp" -o "$TOBJ/fssh.o"
$CXX -O1 $COVERAGE_FLAGS "$TOBJ"/*.o -o "$SRC/mayhem/build/bfs_shell"
