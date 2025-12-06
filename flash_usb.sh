#!/bin/bash
set -e

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./flash_usb.sh)"
  exit 1
fi

# Check for required tools
for cmd in parted resize2fs e2fsck partprobe; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is not installed. Please install it (e.g. sudo apt install parted e2fsprogs)"
        exit 1
    fi
done

# Find the most recent image file
IMAGE=$(ls -t steamlink-debian-*.img.xz 2>/dev/null | head -n 1)

if [ -z "$IMAGE" ]; then
    echo "No steamlink-debian-*.img.xz files found in the current directory."
    read -e -p "Enter path to image file: " IMAGE
else
    echo "Found most recent image: $IMAGE"
    read -e -p "Press Enter to use this image, or type a new path: " INPUT_IMAGE
    if [ -n "$INPUT_IMAGE" ]; then
        IMAGE="$INPUT_IMAGE"
    fi
fi

if [ ! -f "$IMAGE" ]; then
    echo "Error: File $IMAGE not found."
    exit 1
fi

echo ""
echo "=== Select Target USB Drive ==="
echo "Available USB devices:"
# List devices with transport type 'usb'
lsblk -d -o NAME,MODEL,SIZE,TRAN,TYPE | grep "usb" || echo "No USB devices detected via transport type."

echo ""
echo "All block devices (be careful!):"
lsblk -d -o NAME,MODEL,SIZE,TRAN,TYPE

echo ""
read -p "Enter the device name to flash (e.g., sdb): " DEVICE_NAME

# Remove /dev/ prefix if user typed it
DEVICE_NAME=${DEVICE_NAME#/dev/}
DEVICE="/dev/$DEVICE_NAME"

if [ ! -b "$DEVICE" ]; then
    echo "Error: Device $DEVICE not found."
    exit 1
fi

# Safety check: try to prevent flashing system drive
if lsblk -no MOUNTPOINT "$DEVICE" | grep -q "^/$"; then
    echo "CRITICAL ERROR: $DEVICE appears to be your root filesystem!"
    exit 1
fi

echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "WARNING: ALL DATA ON $DEVICE WILL BE PERMANENTLY DESTROYED"
echo "Target: $DEVICE ($(lsblk -dn -o MODEL $DEVICE))"
echo "Image:  $IMAGE"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""

read -p "Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Operation cancelled."
    exit 0
fi

# Unmount any mounted partitions on the target device
echo "Unmounting partitions on $DEVICE..."
for part in $(lsblk -ln -o NAME "$DEVICE"); do
    # Skip the device itself, unmount partitions
    if [ "$part" != "$DEVICE_NAME" ]; then
        umount "/dev/$part" 2>/dev/null || true
    fi
done

echo "Flashing image... (This may take a while)"

# Check if pv is installed for a nice progress bar, otherwise use dd status=progress
if command -v pv >/dev/null; then
    # Get uncompressed size for progress bar (approximate if xz -l fails)
    # xz -l output format is complex, just use file size * compression ratio guess or just pipe
    # Actually, pv can measure data passing through.
    # We can't easily know the uncompressed size without decompressing it first or parsing xz -l
    
    # Try to get uncompressed size in bytes using robot mode for raw numbers
    UNCOMPRESSED_SIZE=$(xz --robot --list "$IMAGE" | tail -n 1 | awk '{print $6}')
    
    # Check if UNCOMPRESSED_SIZE is a valid number
    if [[ "$UNCOMPRESSED_SIZE" =~ ^[0-9]+$ ]]; then
        xz -d -T0 -c "$IMAGE" | pv -s "$UNCOMPRESSED_SIZE" | dd of="$DEVICE" bs=4M conv=fsync
    else
        # Fallback if size detection fails
        xz -d -T0 -c "$IMAGE" | pv | dd of="$DEVICE" bs=4M conv=fsync
    fi
else
    echo "Tip: Install 'pv' for a better progress bar (sudo apt install pv)"
    xz -d -T0 -c "$IMAGE" | dd of="$DEVICE" bs=4M status=progress conv=fsync
fi

echo ""
echo "Flashing complete!"
echo "Syncing disks..."
sync

echo "Expanding partition to fill the drive..."
# Inform kernel of partition table changes
partprobe "$DEVICE" || true
sleep 2

# Determine partition name
if [[ "$DEVICE" =~ [0-9]$ ]]; then
    PARTITION="${DEVICE}p1"
else
    PARTITION="${DEVICE}1"
fi

# Resize partition 1 to 100% of the drive
parted -s "$DEVICE" resizepart 1 100%
partprobe "$DEVICE" || true
sleep 2

# Resize filesystem
echo "Resizing filesystem on $PARTITION..."
echo "1. Checking filesystem integrity..."
# -f: Force check even if clean
# -C 0: Show progress bar to stdout
# -y: Assume yes to all questions (non-interactive repair)
e2fsck -f -y -C 0 "$PARTITION" || true

echo "2. Expanding filesystem (this involves writing inode tables and may be slow)..."
# -p: Print progress bars
resize2fs -p "$PARTITION"

echo "Syncing disks..."
sync
echo "Safe to remove $DEVICE."
