#!/bin/bash

set -eux

# Locale/TZ

echo "locales locales/default_environment_locale select en_US.UTF-8" | debconf-set-selections
echo "locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8" | debconf-set-selections
rm -f "/etc/locale.gen"
dpkg-reconfigure --frontend noninteractive locales
ln -fs /usr/share/zoneinfo/$CFG_TIMEZONE /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# Configure Hostname
echo $CFG_HOSTNAME > /etc/hostname
echo "127.0.1.1       $CFG_HOSTNAME" >> /etc/hosts
apt update

# EFI
mkdir /boot/efi
echo UUID=$(blkid -s UUID -o value ${CFG_DISK}-part1) /boot/efi vfat umask=0022,fmask=0022,dmask=0022 0 1 >> /etc/fstab
mount /boot/efi
mkdir /boot/efi/grub /boot/grub
echo /boot/efi/grub /boot/grub none defaults,bind 0 0 >> /etc/fstab
mount /boot/grub
if [ "$has_uefi" == true ]; then
  apt install --yes grub-efi-amd64 grub-efi-amd64-signed shim-signed zfs-initramfs zsys
else
  # Note: grub-pc will ask where to write
  apt install --yes grub-pc zfs-initramfs zsys zfs-dkms
fi

# Swap
echo UUID=$(blkid -s UUID -o value ${CFG_DISK}-part2) none swap discard 0 0 >> /etc/fstab
swapon -a

# GRUB
grub-probe /boot
update-initramfs -c -k all
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 init_on_alloc=0"/g' /etc/default/grub
update-grub
if [ "$has_uefi" == true ]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy
else
  grub-install $CFG_DISK
fi

## FS mount ordering
mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool
zed -F &
zed_pid=$!
sleep 5
kill $zed_pid
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*

# Add user
adduser --disabled-password --gecos "$CFG_FULLNAME" $CFG_USERNAME
cp -a /etc/skel/. /home/$CFG_USERNAME
chown -R $CFG_USERNAME:$CFG_USERNAME /home/$CFG_USERNAME
usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sudo $CFG_USERNAME
echo -e "$CFG_USERNAME\n$CFG_USERNAME" | passwd $CFG_PASSWORD

# Remove installer packages
< /root/filesystem.manifest-remove xargs dpkg --purge -y

# Disable logrotote compression since zfs does that already
for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "\$file" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "\$file"
    fi
done
