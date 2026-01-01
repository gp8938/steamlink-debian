#!/usr/bin/env bash

set -e

export ARCH=arm; export LOCALVERSION="-steam"

mkdir -p boot
cd steamlink-sdk
source setenv.sh
# Avoid overriding the host compiler for kernel host tools (e.g. certs/extract-cert)
# `setenv.sh` sets CC/CXX/CPP to the cross toolchain which would make host tools
# compile against the SDK sysroot (missing host headers). Unset them so the native
# host compiler is used for tools while CROSS_COMPILE remains set for target builds.
unset CC CXX CPP
# Also ensure host pkg-config and sysroot-related variables are cleared so
# the host build doesn't add includes from the ARM sysroot (which causes
# `gnu/stubs-soft.h` missing errors when building host tools on x86).
unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR HOSTPKG_CONFIG
cd ../linux-$KERNEL_VERSION
# Debug: show current directory and basic sanity checks
echo "[kernel/build.sh] PWD: $(pwd)"
echo "[kernel/build.sh] Makefile exists:" && [ -f Makefile ] && echo yes || echo no
echo "[kernel/build.sh] scripts dir exists:" && [ -d scripts ] && echo yes || echo no
ls -la | sed -n '1,20p'
# Try to update configuration from provided .config.
# Prefer `olddefconfig` when available (keeps current config options),
# otherwise fall back to `defconfig` so build can proceed.
# Prefer `olddefconfig`. Run it and if it exits non-zero, fall back to `defconfig`.
if ! make olddefconfig; then
	echo "make olddefconfig failed; falling back to make defconfig"
	make defconfig || { echo "make defconfig also failed — aborting"; exit 1; }
fi

make -j$(nproc)
make modules
rm -rf ../build-modules
mkdir -p ../build-modules
INSTALL_MOD_PATH=$PWD/../build-modules make modules_install