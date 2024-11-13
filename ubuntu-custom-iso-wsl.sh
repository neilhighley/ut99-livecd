#!/bin/bash
# Script to create a custom Ubuntu 22.04 Live CD with Wine, UT99, and persistence using WSL
# Must be run with administrative privileges in WSL
# WSL --install -d Ubuntu-22.04
# WSL --unregister Ubuntu-22.04
# If you get read errors after fiddling with the script, it is
# better to just unregister then re-install the WSL
#
# This script should work just as well with docker with a few tweaks.
#
# Change Log
# 2024-11-11 Created
#
set -e  # Exit on error

# Configuration
WORK_DIR="/tmp/custom-ubuntu-live"
CHROOT_DIR="$WORK_DIR/chroot"
ISO_DIR="$WORK_DIR/iso"
DEST_ISO="/mnt/d/p/ut99/unreal-linux-boot.iso"
UT_99_FILES="/mnt/d/p/ut99/ut99-files"
PERSISTENCE_SIZE="1024" # Size in MB for persistence file

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to check dependencies
check_dependencies() {
    local DEPS=(
        "debootstrap"
        "squashfs-tools"
        "xorriso"
        "isolinux"
        "syslinux-utils"
        "grub-pc-bin"
        "grub-efi-amd64-bin"
        "mtools"
        "cpio"
        "dosfstools"
    )

    log "Checking dependencies..."
    for dep in "${DEPS[@]}"; do
        if ! dpkg -l | grep -q "^ii  $dep "; then
            log "Installing $dep..."
            apt-get install -y "$dep"
        fi
    done
}

# Function to verify WSL environment
verify_environment() {
    if ! grep -q microsoft /proc/version; then
        log "Error: This script must be run in WSL"
        exit 1
    fi

    if [ "$EUID" -ne 0 ]; then 
        log "Error: Please run as root (use sudo)"
        exit 1
    fi

    if [ ! -d "$UT_99_FILES" ]; then
        log "Error: UT99 files directory not found at $UT_99_FILES"
        exit 1
    fi

    log "ISO DIRECTORY SET TO : $ISO_DIR"
    log "WORK DIRECTORY SET TO : $WORK_DIR"
    log "UT99 FILES FOUND AT : $UT_99_FILES"
    log "DESTINATION ISO WILL BE SAVED AT : $DEST_ISO"
}

# Function to clean existing work directory
clean_environment() {
    log "Cleaning existing work environment..."
    
    # Kill any processes using the chroot
    if [ -d "$CHROOT_DIR" ]; then
        lsof "$CHROOT_DIR" 2>/dev/null | awk '{print $2}' | grep -v PID | sort -u | xargs -r kill
    fi
    
    # Unmount everything in reverse order
    for mount in "$CHROOT_DIR/dev/pts" "$CHROOT_DIR/dev" "$CHROOT_DIR/proc" "$CHROOT_DIR/sys"; do
        if mountpoint -q "$mount" 2>/dev/null; then
            umount -lf "$mount" || log "Warning: Could not unmount $mount"
        fi
    done
    
    # Force unmount any remaining mounts
    if [ -d "$CHROOT_DIR" ]; then
        grep "$CHROOT_DIR" /proc/mounts | cut -d' ' -f2 | sort -r | while read -r mount_point; do
            umount -lf "$mount_point" 2>/dev/null || true
        done
    fi

    # Remove work directory if it exists
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi

    if [ -f "$DEST_ISO" ]; then
        log "Destination ISO exists. Deleting..."
        rm -f "$DEST_ISO"
    fi
    
    # Create fresh directories
    mkdir -p "$WORK_DIR" "$CHROOT_DIR" "$ISO_DIR/casper" "$ISO_DIR/boot/grub" "$ISO_DIR/isolinux"
}

# Function to set up base system
setup_base_system() {
    log "Setting up base system..."
    debootstrap --arch=amd64 jammy "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu/

    # Configure repositories
    cat > "$CHROOT_DIR/etc/apt/sources.list" << EOF
deb http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse
EOF

    # Ensure mount points exist
    mkdir -p "$CHROOT_DIR/dev" "$CHROOT_DIR/dev/pts" "$CHROOT_DIR/proc" "$CHROOT_DIR/sys"

    # Mount necessary filesystems with error checking
    mount --bind /dev "$CHROOT_DIR/dev" || { log "Error mounting /dev"; exit 1; }
    mount --bind /dev/pts "$CHROOT_DIR/dev/pts" || { log "Error mounting /dev/pts"; exit 1; }
    mount -t proc proc "$CHROOT_DIR/proc" || { log "Error mounting /proc"; exit 1; }
    mount -t sysfs sysfs "$CHROOT_DIR/sys" || { log "Error mounting /sys"; exit 1; }
}

# Function to install packages in chroot
install_packages() {
    log "Installing packages in chroot..."
    
    # Create policy-rc.d to prevent services from starting in chroot
    cat > "$CHROOT_DIR/usr/sbin/policy-rc.d" << EOF
#!/bin/sh
exit 101
EOF
    chmod +x "$CHROOT_DIR/usr/sbin/policy-rc.d"

    # Prepare chroot environment
    cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"

    chroot "$CHROOT_DIR" /bin/bash << 'EOCHROOT'
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Enable 32-bit architecture
dpkg --add-architecture i386

# Update package list
apt-get update -y

# Install kernel packages first
apt-get install -y \
    linux-generic \
    linux-image-generic \
    linux-headers-generic

# Verify kernel installation
if [ ! -f /boot/vmlinuz-* ]; then
    echo "ERROR: Kernel installation failed!"
    exit 1
fi

# Install required dependencies for Wine
apt-get install -y \
    wget \
    gpg \
    software-properties-common

# Add Wine repository
wget -nc https://dl.winehq.org/wine-builds/winehq.key
mv winehq.key /usr/share/keyrings/winehq-archive.key

# Add Wine repository for Ubuntu 22.04
wget -nc https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources
mv winehq-jammy.sources /etc/apt/sources.list.d/

# Update package list again after adding Wine repository
apt-get update -y

# Install Wine with 32-bit support
apt-get install -y \
    wine64 \
    wine32 \
    libwine \
    wine-stable \
    winetricks

# Install desktop and required packages
apt-get install -y \
    --no-install-recommends \
    ubuntu-desktop \
    casper \
    live-boot \
    live-boot-initramfs-tools \
    live-tools \
    discover \
    laptop-detect \
    os-prober \
    network-manager \
    resolvconf \
    net-tools \
    wireless-tools \
    locales \
    systemd-sysv 

# Install additional ubuntu required packages
apt-get install -y \
    plymouth-theme-ubuntu-logo \
    ubuntu-standard \
    ubuntu-minimal

# Generate locale
locale-gen en_GB.UTF-8

# Set up live session user
useradd -m -s /bin/bash ubuntu
echo "ubuntu:ubuntu" | chpasswd
adduser ubuntu sudo

# Enable autologin for live session
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ubuntu --noclear %I \$TERM
EOF

# Clean up
apt-get clean
rm -rf /tmp/*
rm -rf /var/lib/apt/lists/*

# Remove policy-rc.d
rm -f /usr/sbin/policy-rc.d
EOCHROOT

    # Remove temporary policy-rc.d if something went wrong
    rm -f "$CHROOT_DIR/usr/sbin/policy-rc.d"

    # Verify kernel installation from outside chroot
    if [ ! -f "$CHROOT_DIR/boot/vmlinuz-"* ]; then
        log "Error: Kernel not found after installation"
        ls -la "$CHROOT_DIR/boot/"
        exit 1
    fi

    log "Package installation completed successfully"
}

# Function to set up UT99
setup_ut99() {
    log "Setting up UT99..."
    
    # Create UT99 directory in chroot
    mkdir -p "$CHROOT_DIR/opt/ut99"
    
    # Copy UT99 files
    cp -r "$UT_99_FILES"/* "$CHROOT_DIR/opt/ut99/" || {
        log "Error copying UT99 files"
        exit 1
    }
    
    # Create launch script with Wine configuration
    cat > "$CHROOT_DIR/usr/local/bin/launch-ut99" << 'EOF'
#!/bin/bash

# Set up Wine prefix
export WINEPREFIX="$HOME/.wine_ut99"
export WINEARCH=win32

# Initialize Wine prefix if it doesn't exist
if [ ! -d "$WINEPREFIX" ]; then
    wineboot --init
    
    # Wait for Wine initialization
    sleep 5
    
    # Configure Wine for better gaming performance
    winetricks dxvk
fi

# Launch UT99
cd /opt/ut99
wine System/UnrealTournament.exe
EOF
    chmod +x "$CHROOT_DIR/usr/local/bin/launch-ut99"
    
    # Create desktop shortcut
    cat > "$CHROOT_DIR/usr/share/applications/ut99.desktop" << 'EOF'
[Desktop Entry]
Name=Unreal Tournament 99
Comment=Launch Unreal Tournament 99
Exec=/usr/local/bin/launch-ut99
Icon=/opt/ut99/ut-icon.xpm
Terminal=false
Type=Application
Categories=Game;
EOF
}
# Function to create persistence
setup_persistence() {
    log "Setting up persistence..."
    
    # Create persistence configuration
    mkdir -p "$ISO_DIR/persistence"
    cat > "$ISO_DIR/persistence/persistence.conf" << EOF
/ union
/home union
/opt union
EOF
    
    # Create persistence image
    dd if=/dev/zero of="$ISO_DIR/casper/persistence.img" bs=1M count="$PERSISTENCE_SIZE"
    mkfs.ext4 -F -L persistence "$ISO_DIR/casper/persistence.img"
}

# Function to create squashfs
create_squashfs() {
    log "Creating squashfs..."
    
    # Ensure all processes are out of the chroot
    lsof "$CHROOT_DIR" 2>/dev/null | awk '{print $2}' | grep -v PID | sort -u | xargs -r kill

    # Properly unmount everything in reverse order
    for mount in "$CHROOT_DIR/dev/pts" "$CHROOT_DIR/dev" "$CHROOT_DIR/proc" "$CHROOT_DIR/sys"; do
        if mountpoint -q "$mount" 2>/dev/null; then
            umount -lf "$mount" || log "Warning: Could not unmount $mount"
        fi
    done

    # Clean up any remaining mounts
    grep "$CHROOT_DIR" /proc/mounts | cut -d' ' -f2 | sort -r | while read -r mount_point; do
        umount -lf "$mount_point" 2>/dev/null || true
    done
    
    # Create exclusion list with absolute paths
    cat > "$WORK_DIR/exclude.list" << EOF
$CHROOT_DIR/proc/*
$CHROOT_DIR/sys/*
$CHROOT_DIR/dev/*
$CHROOT_DIR/run/*
$CHROOT_DIR/tmp/*
$CHROOT_DIR/mnt/*
EOF
    
    # Remove any existing squashfs
    rm -f "$ISO_DIR/casper/filesystem.squashfs"
    
    # Ensure ISO directory exists
    mkdir -p "$ISO_DIR/casper"
    
    log "Starting squashfs creation..."
    
    # Create squashfs with verbose output and error checking
    if ! mksquashfs "$CHROOT_DIR" "$ISO_DIR/casper/filesystem.squashfs" \
        -ef "$WORK_DIR/exclude.list" \
        -comp gzip \
        -b 1M \
        -no-recovery \
        -no-progress \
        -info; then
        log "Error: mksquashfs failed"
        exit 1
    fi
    
    # Verify the squashfs was created
    if [ ! -f "$ISO_DIR/casper/filesystem.squashfs" ]; then
        log "Error: squashfs file was not created"
        exit 1
    fi
    
    # Check the size of the created squashfs
    SQUASHFS_SIZE=$(stat -c %s "$ISO_DIR/casper/filesystem.squashfs")
    if [ "$SQUASHFS_SIZE" -lt 100000000 ]; then  # Adjust this minimum size as needed
        log "Error: squashfs file is suspiciously small ($SQUASHFS_SIZE bytes)"
        exit 1
    fi
    
    log "Squashfs creation completed successfully"
}

# Function to set up bootloader
setup_bootloader() {
    log "Setting up bootloader..."
    
    # Find and copy kernel and initrd
    KERNEL_VERSION=$(ls "$CHROOT_DIR/boot/vmlinuz-"* | sort -V | tail -n1 | sed 's/.*vmlinuz-//')
    cp "$CHROOT_DIR/boot/vmlinuz-$KERNEL_VERSION" "$ISO_DIR/casper/vmlinuz"
    cp "$CHROOT_DIR/boot/initrd.img-$KERNEL_VERSION" "$ISO_DIR/casper/initrd.gz"
    
    # Create GRUB EFI directory structure
    mkdir -p "$ISO_DIR/EFI/BOOT"
    
    # Create GRUB configuration
    mkdir -p "$ISO_DIR/boot/grub"
    cat > "$ISO_DIR/boot/grub/grub.cfg" << EOF
set timeout=10
set default=0

menuentry "Ubuntu Live with UT99 (Persistent)" {
    linux /casper/vmlinuz boot=casper persistent quiet splash ---
    initrd /casper/initrd.gz
}

menuentry "Ubuntu Live with UT99 (No Persistence)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd.gz
}

menuentry "Ubuntu Live with UT99 (Recovery Mode)" {
    linux /casper/vmlinuz boot=casper noapic noacpi nosplash irqpoll ---
    initrd /casper/initrd.gz
}
EOF

    # Create EFI bootloader
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$ISO_DIR/EFI/BOOT/BOOTX64.EFI" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"

    # Create FAT image for EFI
    (cd "$ISO_DIR" && \
     dd if=/dev/zero of=efi.img bs=1M count=5 && \
     mkfs.vfat efi.img && \
     mmd -i efi.img ::/EFI ::/EFI/BOOT && \
     mcopy -i efi.img ./EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/
    )

    # Create isolinux configuration
    mkdir -p "$ISO_DIR/isolinux"
    cat > "$ISO_DIR/isolinux/isolinux.cfg" << EOF
UI vesamenu.c32
TIMEOUT 100

MENU TITLE Ubuntu Live with UT99
DEFAULT live
LABEL live
  MENU LABEL Ubuntu Live with UT99 (Persistent)
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd.gz boot=casper persistent quiet splash ---
LABEL live-nopersist
  MENU LABEL Ubuntu Live with UT99 (No Persistence)
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd.gz boot=casper quiet splash ---
EOF

    # Copy isolinux files
    cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/"
}


# Function to create ISO
create_iso() {
    log "Creating ISO..."
    
    # Create manifest
    chroot "$CHROOT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' > "$ISO_DIR/casper/filesystem.manifest"
    
    # Generate md5sum
    cd "$ISO_DIR"
    find . -type f -print0 | xargs -0 md5sum | grep -v "\./md5sum.txt" > md5sum.txt
    
    # Create ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "UBUNTU_LIVE" \
        -appid "Ubuntu Live with UT99" \
        -publisher "Custom Build" \
        -preparer "Custom Build" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "$DEST_ISO" \
        "$ISO_DIR"
}

# Main execution
main() {
    log "Starting Ubuntu Live CD creation process..."
    
    verify_environment
    check_dependencies
    clean_environment
    setup_base_system
    install_packages
    setup_ut99
    setup_persistence
    create_squashfs
    setup_bootloader
    create_iso
    
    log "Live CD creation completed successfully!"
}

# Run main function
main

exit 0
