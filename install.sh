#!/bin/bash

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# time settings
timedatectl set-timezone Europe/Moscow
timedatectl set-ntp true

# sorting pacman mirrors by download speed
pacman -Syy
pacman -S --noconfirm pacman-contrib
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
echo "Sorting mirrors by speed, this may take a while..."
rankmirrors -n 6 /etc/pacman.d/mirrorlist.backup > /etc/pacman.d/mirrorlist

# choosing disk
pacman -S --noconfirm dialog
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Choose installation disk" 0 0 0 ${devicelist}) || exit 1
clear

# set hostname
echo -n "Hostname: "
read hostname
: "${hostname:?"Missing hostname"}"

# set root password
echo -n "Root password: "
read passwordRoot
echo
echo -n "Repeat password: "
read password2Root
echo
[[ "$passwordRoot" == "$password2Root" ]] || ( echo "Passwords did not match"; exit 1; )

# creating user
echo -n "Username: "
read username
: "${username:?"Missing username"}"

echo -n "Password for user ${username}: "
read passwordUser
echo
echo -n "Repeat password: "
read password2User
echo
[[ "$passwordUser" == "$password2User" ]] || ( echo "Passwords did not match"; exit 1; )

# creating partitions
(echo g;
echo n; echo 1; echo; echo +300M; echo t; echo 1; echo 1;
echo n; echo 2; echo; echo +1G; 
echo n; echo 3; echo; echo +8G; echo t; echo 3; echo 19;
echo n; echo 4; echo; echo;
echo p; echo w) | fdisk "${device}"

# formatting partitions
mkfs.fat -F32  "${device}p1"
mkfs.ext4 -L boot "${device}p2"
mkswap -L swap "${device}p3"
swapon "${device}p3"
mkfs.btrfs -L arch "${device}p4" -f

# creating BTRFS subvolumes
mount "${device}p4" /mnt
btrfs su cr /mnt/@
btrfs su cr /mnt/@var
btrfs su cr /mnt/@home
btrfs su cr /mnt/@snapshots
umount /mnt

# mounting partitions and subvolumes
mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@ "${device}p4" /mnt
mkdir -p /mnt/{home,boot,var,.snapshots}
mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@var "${device}p4" /mnt/var
mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@home "${device}p4" /mnt/home
mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@snapshots "${device}p4" /mnt/.snapshots
mount "${device}p2" /mnt/boot
mkdir /mnt/boot/efi
mount "${device}p1" /mnt/boot/efi

# installing base packages, generating fstab
pacstrap /mnt base 
arch-chroot /mnt pacman -S --noconfirm base-devel linux linux-headers linux-firmware intel-ucode amd-ucode nano
echo "generating fstab..."
genfstab -pU /mnt >> /mnt/etc/fstab

echo "${hostname}" > /mnt/etc/hostname
echo "root:$passwordRoot" | chpasswd --root /mnt

arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
arch-chroot /mnt systemctl enable systemd-timesyncd.service 
arch-chroot /mnt hwclock --systohc

# locale setup
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
sed -i 's/#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
touch /mnt/etc/locale.conf
echo "LANG=ru_RU.UTF-8" > /mnt/etc/locale.conf

cat >> /mnt/etc/vconsole.conf << EOF
KEYMAP=ru
FONT=cyr-sun16
EOF

# pacman init and configuring
arch-chroot /mnt pacman-key --init
arch-chroot /mnt pacman-key --populate archlinux
sed -i 's/# Color/Color/' /mnt/etc/pacman.conf
sed -i 's/# ParallelDownloads = 5/ParallelDownloads = 10/' /mnt/etc/pacman.conf
cat >> /mnt/etc/pacman.conf << EOF
[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
arch-chroot /mnt pacman -Sy
arch-chroot /mnt pacman -S --noconfirm bash-completion openssh arch-install-scripts networkmanager git wget htop neofetch xdg-user-dirs pacman-contrib ntfs-3g go timeshift
arch-chroot /mnt git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si

# creating init disk
arch-chroot /mnt mkinitcpio -p linux || true

# adding wheel to sudo
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers

arch-chroot /mnt useradd -mg users -G wheel "${username}"
echo "$username:$passwordUser" | chpasswd --root /mnt

# enabling network manager
arch-chroot /mnt systemctl enable NetworkManager.service
# enabling automatic cleaning of packages cashe 
arch-chroot /mnt systemctl enable paccache.timer

# installing Grub
arch-chroot /mnt pacman -S --noconfirm grub efibootmgr grub-btrfs os-prober
arch-chroot /mnt grub-install --removable --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

cp ~/clean-arch-install/chroot-scripts/yay-autosnap.sh /mnt/root/
dos2unix -- /mnt/root/yay-autosnap.sh
chmod +x /mnt/root/yay-autosnap.sh
arch-chroot /mnt /root/yay-autosnap.sh $username
rm /mnt/root/yay-autosnap.sh

# unmounting partitions
echo "unmounting all..."
umount -R /mnt
reboot
