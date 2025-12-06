#!/usr/bin/env bash

set -e

export ARCH=arm; export LOCALVERSION="-steam"

mkdir -p boot
cd steamlink-sdk
source setenv.sh
cd ../linux-$KERNEL_VERSION
make olddefconfig
make -j$(nproc)
make modules
rm -rf ../build-modules
mkdir -p ../build-modules
INSTALL_MOD_PATH=$PWD/../build-modules make modules_install