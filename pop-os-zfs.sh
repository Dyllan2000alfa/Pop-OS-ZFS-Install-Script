#!/bin/bash

set -eux

#
# Configuration
# -------------

read –p "Disk to install ZFS on. Disk entered will be erased without a further prompt. Should be drive ID. EX: if /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-0-1 type scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-0-1" CFG_DISK_ID
read -p "System Hostname" CFG_HOSTNAME
read -p "Timezone" CFG_TIMEZONE
read -p "Username" CFG_USERNAME
read -p "User Fullname" CFG_FULLNAME
read -sp "User Password" CFG_PASSWORD

# Identifier to use when creating zfs data sets (default: random).
CFG_ZFSID=$(dd if=/dev/urandom of=/dev/stdout bs=1 count=100 2>/dev/null | tr -dc 'a-z0-9' | cut -c-6)

# Vars
# ----

has_uefi=$([ -d /sys/firmware/efi ] && echo true || echo false)

# Prepare software
# ----------------
apt install --yes gdisk zfsutils-linux zfs-dkms
modprobe zfs
systemctl stop zed


# Remove leftovers from failed script (if any)
# --------------------------------------------

umount -l /mnt/dev 2>/dev/null || true
umount -l /mnt/proc 2>/dev/null || true
umount -l /mnt/sys 2>/dev/null || true
umount -l /mnt 2>/dev/null || true
swapoff ${CFG_DISK}-part2 2>/dev/null || true
zpool destroy bpool 2>/dev/null | true
zpool destroy rpool 2>/dev/null | true

# Partitions
# ----------

sgdisk --zap-all $CFG_DISK
# Bootloader partition (UEFI)
sgdisk     -n1:1M:+512M   -t1:EF00 $CFG_DISK
# Swap partition (non-zfs due to deadlock bug)
sgdisk     -n2:0:+500M    -t2:8200 $CFG_DISK
# Boot pool partition
sgdisk     -n3:0:+2G      -t3:BE00 $CFG_DISK
if [ ! "$has_uefi" == true ]; then
  sgdisk -a1 -n5:24K:+1000K -t5:EF02 $CFG_DISK
fi
# Root pool partition
sgdisk     -n4:0:0        -t4:BF00 $CFG_DISK

sleep 1

# EFI
mkdosfs -F 32 -s 1 -n EFI ${CFG_DISK}-part1

# Swap
mkswap -f ${CFG_DISK}-part2

# Boot pool
zpool create -f \
    -o ashift=12 -o autotrim=on -d \
    -o feature@async_destroy=enabled \
    -o feature@bookmarks=enabled \
    -o feature@embedded_data=enabled \
    -o feature@empty_bpobj=enabled \
    -o feature@enabled_txg=enabled \
    -o feature@extensible_dataset=enabled \
    -o feature@filesystem_limits=enabled \
    -o feature@hole_birth=enabled \
    -o feature@large_blocks=enabled \
    -o feature@lz4_compress=enabled \
    -o feature@spacemap_histogram=enabled \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O devices=off -O normalization=formD -O relatime=on -O xattr=sa \
    -O mountpoint=/boot -R /mnt \
    bpool ${CFG_DISK}-part3
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

# Root pool
zpool create -f \
    -o ashift=12 -o autotrim=on \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on \
    -O xattr=sa -O mountpoint=/ -R /mnt \
    rpool ${CFG_DISK}-part4
zfs create -o canmount=off -o mountpoint=none rpool/ROOT

# /
zfs create -o canmount=noauto -o mountpoint=/ \
    -o com.ubuntu.zsys:bootfs=yes \
    -o com.ubuntu.zsys:last-used=$(date +%s) rpool/ROOT/pop-os_$CFG_ZFSID
zfs mount rpool/ROOT/pop-os_$CFG_ZFSID
zfs create -o canmount=off -o mountpoint=/ rpool/USERDATA
zfs create -o com.ubuntu.zsys:bootfs-datasets=rpool/ROOT/pop-os_$CFG_ZFSID \
    -o canmount=on -o mountpoint=/root rpool/USERDATA/root_$CFG_ZFSID

# /boot
zfs create -o canmount=noauto -o mountpoint=/boot bpool/BOOT/pop-os_$CFG_ZFSID
zfs mount bpool/BOOT/pop-os_$CFG_ZFSID

# /home/user
zfs create -o com.ubuntu.zsys:bootfs-datasets=rpool/ROOT/pop-os_$CFG_ZFSID \
    -o canmount=on -o mountpoint=/home/$CFG_USERNAME rpool/USERDATA/$CFG_USERNAME

# /srv
zfs create -o com.ubuntu.zsys:bootfs=no rpool/ROOT/pop-os_$CFG_ZFSID/srv

# /tmp
zfs create -o com.ubuntu.zsys:bootfs=no rpool/ROOT/pop-os_$CFG_ZFSID/tmp
chmod 1777 /mnt/tmp

# /usr
zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off rpool/ROOT/pop-os_$CFG_ZFSID/usr
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/usr/local

# /var
zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off rpool/ROOT/pop-os_$CFG_ZFSID/var
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/games
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/lib
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/lib/AccountsService
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/lib/apt
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/lib/dpkg
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/lib/NetworkManager
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/log
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/mail
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/snap
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/spool
zfs create rpool/ROOT/pop-os_$CFG_ZFSID/var/www

unsquashfs -f -d /mnt /cdrom/casper/filesystem.squashfs

cp /cdrom/casper/filesystem.manifest-remove /mnt/root/filesystem.manifest-remove
curl https://raw.githubusercontent.com/Dyllan2000alfa/Pop-OS-ZFS-Install-Script/main/chroot.sh -o /mnt/root/chroot.sh
chmod a+x /mnt/root/chroot.sh

mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys
chroot /mnt /usr/bin/env \
  has_uefi=$has_uefi \
  CFG_DISK=$CFG_DISK \
  CFG_HOSTNAME=$CFG_HOSTNAME \
  CFG_USERNAME=$CFG_USERNAME \
  CFG_FULLNAME="$CFG_FULLNAME" \
  CFG_PASSWORD=$CFG_PASSWORD \
  CFG_TIMEZONE=$CFG_TIMEZONE \
  bash --login /root/chroot.sh
rm /mnt/root/chroot.sh
rm /mnt/root/filesystem.manifest-remove

# Clean up
# --------

umount -l /mnt/dev 2>/dev/null || true
umount -l /mnt/proc 2>/dev/null || true
umount -l /mnt/sys 2>/dev/null || true
umount -l /mnt 2>/dev/null || true
swapoff ${CFG_DISK}-part2 2>/dev/null || true
zpool export bpool
zpool export rpool


echo "Install complete. Please reboot and remove the installer medium"