#!/usr/bin/env bash

set -e

dd if=/dev/zero of=steamlink-debian.img bs=1M count=1024

# Use parted to create a partition table and a single primary partition
parted --script steamlink-debian.img mklabel msdos        # Create an msdos partition table
parted --script steamlink-debian.img mkpart primary ext3 1MiB 100%  # Create a primary partition

sync

# Set up a loop device with partition mapping
LOOP_DEV=$(losetup --show -P -f steamlink-debian.img)

sync

# Format the first partition with ext3
mkfs.ext3 "${LOOP_DEV}p1"

sync

# Mount the partition
mkdir -p /mnt/disk
mount "${LOOP_DEV}p1" /mnt/disk
tar -xpf rootfs.tar -C /mnt/disk/
rm -rf /mnt/disk/.dockerenv
umount -l /mnt/disk

# Detach the loop device
losetup -d $LOOP_DEV

# Compress the image file
xz -z steamlink-debian.img

# Make the image file readable for non-root users
chmod 777 steamlink-debian.img.xz