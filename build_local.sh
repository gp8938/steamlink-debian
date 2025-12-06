#!/bin/bash
set -e

# Default values matching the workflow
KERNEL_VERSION="${1:-5.10.228}"
KERNEL_BRANCH="${2:-v5.x}"
DEBIAN_VERSION="${3:-bullseye}"

# Network Configuration (Static IP)
# Force user to provide IP and Gateway if not set
if [ -z "$STATIC_IP" ]; then
    read -p "Enter Static IP (e.g. 192.168.1.7): " STATIC_IP
fi

if [ -z "$STATIC_GATEWAY" ]; then
    read -p "Enter Gateway IP (e.g. 192.168.1.254): " STATIC_GATEWAY
fi

if [ -z "$STATIC_IP" ] || [ -z "$STATIC_GATEWAY" ]; then
    echo "Error: Static IP and Gateway are required!"
    exit 1
fi

STATIC_NETMASK="${STATIC_NETMASK:-255.255.255.0}"
STATIC_DNS="${STATIC_DNS:-1.1.1.1 8.8.8.8}"

if [ "$KERNEL_VERSION" == "latest-lts" ]; then
    echo "Fetching latest LTS kernel version..."
    LATEST_LTS=$(wget -qO- https://www.kernel.org/releases.json | python3 -c "import sys, json; print(next(r['version'] for r in json.load(sys.stdin)['releases'] if r['moniker'] == 'longterm'))")
    
    if [ -z "$LATEST_LTS" ]; then
        echo "Error: Failed to fetch latest LTS version."
        exit 1
    fi
    
    KERNEL_VERSION="$LATEST_LTS"
    
    # Determine branch based on major version
    MAJOR_VER=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    KERNEL_BRANCH="v${MAJOR_VER}.x"
    
    echo "Detected latest LTS: $KERNEL_VERSION (Branch: $KERNEL_BRANCH)"

    echo "Fetching latest Debian stable version..."
    LATEST_DEBIAN=$(wget -qO- https://ftp.debian.org/debian/dists/stable/Release | grep "^Codename:" | awk '{print $2}')
    
    if [ -n "$LATEST_DEBIAN" ]; then
        DEBIAN_VERSION="$LATEST_DEBIAN"
        echo "Detected latest Debian stable: $DEBIAN_VERSION"
    else
        echo "Warning: Failed to fetch latest Debian version. Keeping default: $DEBIAN_VERSION"
    fi
fi

echo "Starting build with:"
echo "  KERNEL_VERSION: $KERNEL_VERSION"
echo "  KERNEL_BRANCH:  $KERNEL_BRANCH"
echo "  DEBIAN_VERSION: $DEBIAN_VERSION"
echo "  STATIC_IP:      $STATIC_IP"
echo "  STATIC_GATEWAY: $STATIC_GATEWAY"

# Check for required tools
for cmd in docker wget tar xz; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is not installed."
        exit 1
    fi
done

# --- Step 1: Build Kernel ---
echo "=== Step 1: Building Kernel ==="

# Download Kernel
if [ ! -f "linux-$KERNEL_VERSION.tar.xz" ]; then
    echo "Downloading kernel source..."
    wget "https://cdn.kernel.org/pub/linux/kernel/$KERNEL_BRANCH/linux-$KERNEL_VERSION.tar.xz"
else
    echo "Kernel source tarball already exists."
fi

# Extract Kernel
if [ ! -d "linux-$KERNEL_VERSION" ]; then
    echo "Extracting kernel source..."
    tar -xf "linux-$KERNEL_VERSION.tar.xz"
else
    echo "Kernel source directory already exists."
fi

# Copy Config
echo "Copying kernel config..."
CONFIG_FILE="./kernel/$KERNEL_VERSION.config"

if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "./linux-$KERNEL_VERSION/.config"
else
    echo "Config file $CONFIG_FILE not found."
    # Find the closest matching config
    # Get list of available configs in kernel/
    AVAILABLE_CONFIGS=$(ls kernel/*.config 2>/dev/null | sed 's/kernel\///;s/\.config//' | sort -V)
    
    if [ -z "$AVAILABLE_CONFIGS" ]; then
        echo "Error: No config files found in kernel/ directory."
        exit 1
    fi
    
    # Simple fallback: use the highest version available
    # Ideally we would find the closest version, but highest is usually best for newer kernels
    FALLBACK_VERSION=$(echo "$AVAILABLE_CONFIGS" | tail -n 1)
    FALLBACK_CONFIG="./kernel/$FALLBACK_VERSION.config"
    
    echo "Falling back to closest config: $FALLBACK_CONFIG"
    cp "$FALLBACK_CONFIG" "./linux-$KERNEL_VERSION/.config"
fi

# Build Kernel
echo "Running kernel build script..."
export KERNEL_VERSION
# Ensure the script is executable
chmod +x ./kernel/build.sh
./kernel/build.sh

# Prepare Artifacts
echo "Preparing kernel artifacts..."
mkdir -p boot

# Move modules
# Note: build.sh installs to ./build-modules
if [ -d "build-modules/lib/modules/$KERNEL_VERSION-steam" ]; then
    echo "Moving modules..."
    rm -rf "boot/$KERNEL_VERSION-steam"
    mv "build-modules/lib/modules/$KERNEL_VERSION-steam" "boot/"
    rm -rf "build-modules"
else
    echo "Warning: Modules not found in build-modules. Build might have failed or path is different."
fi

# Move zImage, dtb, and config
# We look inside the linux source directory
pushd "linux-$KERNEL_VERSION" > /dev/null
    echo "Moving zImage..."
    cp arch/arm/boot/zImage ../boot/
    
    echo "Moving DTB..."
    # Find the dtb file (handling potential multiple matches or paths)
    find . -name berlin2cd-valve-steamlink.dtb -exec cp {} ../boot/ \;
    
    echo "Moving config..."
    cp .config "../boot/config-$KERNEL_VERSION-steam"
popd > /dev/null

# Clean up build/source symlinks in the modules dir
rm -rf "boot/$KERNEL_VERSION-steam/build"
rm -rf "boot/$KERNEL_VERSION-steam/source"

echo "Kernel build artifacts prepared in boot/"

# Prepare directory structure for Docker build
# The Dockerfile expects artifacts in kernel-$KERNEL_VERSION/
if [ -d "kernel-$KERNEL_VERSION" ]; then
    rm -rf "kernel-$KERNEL_VERSION"
fi
mv boot "kernel-$KERNEL_VERSION"


# --- Step 2: Build RootFS ---
echo "=== Step 2: Building RootFS ==="

# Check if QEMU emulation is set up for Docker (needed for arm/v7 build on x86)
if ! docker buildx ls | grep -q "linux/arm/v7"; then
    echo "Warning: Docker might not support linux/arm/v7. You may need to run: docker run --privileged --rm tonistiigi/binfmt --install all"
fi

echo "Building Docker image..."
# Using --load to load the image into the local docker daemon so we can export it
docker buildx build --platform linux/arm/v7 \
    --build-arg KERNEL_VERSION="$KERNEL_VERSION" \
    --build-arg DEBIAN_VERSION="$DEBIAN_VERSION" \
    --build-arg STATIC_IP="$STATIC_IP" \
    --build-arg STATIC_NETMASK="$STATIC_NETMASK" \
    --build-arg STATIC_GATEWAY="$STATIC_GATEWAY" \
    --build-arg STATIC_DNS="$STATIC_DNS" \
    --load \
    -f rootfs/Dockerfile \
    -t steamlink-debian:latest \
    .

echo "Exporting RootFS tarball..."
# Remove existing container if it exists
docker rm -f steamlink-debian-rootfs 2>/dev/null || true

docker create -t -i --name steamlink-debian-rootfs steamlink-debian:latest
docker export steamlink-debian-rootfs -o rootfs.tar
docker rm steamlink-debian-rootfs

echo "RootFS tarball created: rootfs.tar"


# --- Step 3: Create Disk Image ---
echo "=== Step 3: Creating Disk Image ==="
echo "This step requires sudo privileges to mount and format the image."

# Ensure the rootfs build script is executable
chmod +x ./rootfs/build.sh

# Run the image creation script with sudo
sudo ./rootfs/build.sh

# Rename and move the final artifact
FINAL_IMAGE="steamlink-debian-$DEBIAN_VERSION-$KERNEL_VERSION.img.xz"
echo "Renaming output to $FINAL_IMAGE..."
mv steamlink-debian.img.xz "$FINAL_IMAGE"

echo "Build complete!"
echo "Output image: $FINAL_IMAGE"
