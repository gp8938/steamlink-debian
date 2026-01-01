ARG DEBIAN_VERSION=bullseye
FROM docker.io/arm32v7/debian:$DEBIAN_VERSION-slim

ARG KERNEL_VERSION=5.10.228
ARG DEBIAN_VERSION=bullseye

# Set locale and debconf to avoid warnings
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LC_CTYPE=en_US.UTF-8 \
    DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends locales && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen && \
    apt-get remove -y locales && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY ./kernel-$KERNEL_VERSION/ /boot/
RUN mkdir -p /lib/modules && mv /boot/$KERNEL_VERSION-steam /lib/modules/$KERNEL_VERSION-steam

COPY ./rootfs/boot/* /boot/
COPY ./rootfs/usr/bin/* /usr/bin/
COPY ./rootfs/steamlink/ /steamlink/

# Add repositories
RUN rm -rf /etc/apt/sources.list.d/* || true
RUN echo "deb http://deb.debian.org/debian $DEBIAN_VERSION main non-free non-free-firmware" > /etc/apt/sources.list
RUN echo "deb http://security.debian.org/debian-security $DEBIAN_VERSION-security main non-free non-free-firmware" >> /etc/apt/sources.list
RUN echo "deb http://deb.debian.org/debian $DEBIAN_VERSION-updates main non-free non-free-firmware" >> /etc/apt/sources.list

# Remove non-free-firmware if DEBIAN_VERSION is bullseye
RUN if [ "$DEBIAN_VERSION" = "bullseye" ]; then sed -i 's/non-free-firmware//g' /etc/apt/sources.list; fi

# Install basic system components
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-timesyncd dbus ca-certificates dhcpcd5 nano vim openssh-server sudo ifupdown net-tools udev iputils-ping wget dosfstools unzip binutils libatomic1 initramfs-tools e2fsprogs parted firmware-libertas wireless-regdb

# Create initramfs
RUN mkinitramfs -o /boot/initramfs-linux-steam.img $KERNEL_VERSION-steam

RUN useradd -s /bin/bash -m debian
RUN echo "debian:steamlink" | chpasswd

# Add debian user to sudoers
RUN usermod -a -G sudo debian

# Enable basic services
RUN systemctl enable ssh
RUN systemctl enable dbus
RUN systemctl enable networking
RUN systemctl enable systemd-timesyncd

# Set hostname
RUN echo "steamlink" > /etc/hostname
RUN echo "127.0.1.1 steamlink" >> /etc/hosts

# Generate SSH host keys
RUN ssh-keygen -A

# /etc/network/interfaces setup
ARG STATIC_IP=192.168.1.7
ARG STATIC_NETMASK=255.255.255.0
ARG STATIC_GATEWAY=192.168.1.254
ARG STATIC_DNS="1.1.1.1 8.8.8.8"

RUN echo "auto lo" > /etc/network/interfaces && \
    echo "iface lo inet loopback" >> /etc/network/interfaces && \
    echo "" >> /etc/network/interfaces && \
    echo "allow-hotplug eth0" >> /etc/network/interfaces && \
    echo "auto eth0" >> /etc/network/interfaces && \
    echo "iface eth0 inet static" >> /etc/network/interfaces && \
    echo "    address $STATIC_IP" >> /etc/network/interfaces && \
    echo "    netmask $STATIC_NETMASK" >> /etc/network/interfaces && \
    echo "    gateway $STATIC_GATEWAY" >> /etc/network/interfaces && \
    echo "    dns-nameservers $STATIC_DNS" >> /etc/network/interfaces

RUN apt-get --yes clean