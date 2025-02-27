#!/bin/bash

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# логгирование
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

# настройка времени
timedatectl set-timezone Europe/Moscow
timedatectl set-ntp true

# отсортировать зеркала pacman по скорости скачивания
pacman -Syy
pacman -S pacman-contrib
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
echo "Sorting mirrors by speed, this may take a while..."
rankmirrors -n 6 /etc/pacman.d/mirrorlist.backup > /etc/pacman.d/mirrorlist

# TODO: добавить запрос на авторазбивку и предупреждение о стирании всех существующих файлов 
#  на выбранном диске

# выбор диска
pacman -S dialog
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Choose installation disk" 0 0 0 ${devicelist}) || exit 1
clear

# разбивка на разделы
(echo g;
echo n; echo 1; echo; echo +300M; echo t; echo 1; echo 1;
echo n; echo 2; echo; echo +1G; 
echo n; echo 3; echo; echo +8G; echo t; echo 3; echo 19;
echo n; echo 4; echo; echo;
echo p; echo w) | fdisk "${device}"

# форматирование разделов
mkfs.fat -F32  "${device}1"
mkfs.ext4 -L boot "${device}2"
mkswap -L swap "${device}3"
swapon "${device}3"
mkfs.btrfs -L arch "${device}4" -f

# создание подтомов BTRFS
mount "${device}4" /mnt
btrfs su cr /mnt/@
btrfs su cr /mnt/@var
btrfs su cr /mnt/@home
btrfs su cr /mnt/@snapshots
umount /mnt

# монтирование разделов
mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@ "${device}4" /mnt
mkdir -p /mnt/{home,boot,var,.snapshots}
mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@var "${device}4" /mnt/var
mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@home "${device}4" /mnt/home
mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@snapshots "${device}4" /mnt/.snapshots
mount "${device}2" /mnt/boot
mkdir /mnt/boot/efi
mount "${device}1" /mnt/boot/efi

# установка основных пакетов, генерация fstab
pacstrap /mnt base 
arch-chroot /mnt pacman -S base-devel linux linux-headers linux-firmware intel-ucode amd-ucode nano
echo "y"
echo "generating genfstab..."
genfstab -pU /mnt >> /mnt/etc/fstab

# установить имя хоста
echo -n "Hostname: "
read hostname
: "${hostname:?"Missing hostname"}"
echo "${hostname}" > /mnt/etc/hostname

# установить пароль рута
echo -n "Root password: "
read -s passwordRoot
echo
echo -n "Repeat password: "
read -s password2Root
echo
[[ "$passwordRoot" == "$password2Root" ]] || ( echo "Passwords did not match"; exit 1; )
echo "root:$password" | chpasswd --root /mnt

# настройка локалей
echo "LANG=en_US.UTF-8 UTF-8" > /mnt/etc/locale.conf
echo "LANG=ru_RU.UTF-8 UTF-8" > /mnt/etc/locale.conf
arch-chroot /mnt locale-gen

cat >> /mnt/etc/locale.conf << EOF
LANG="ru_RU.UTF-8"
EOF

cat >> /mnt/etc/vconsole.conf << EOF
KEYMAP=ru
FONT=cyr-sun16
EOF

# инициализация и настройка pacman
arch-chroot /mnt pacman-key --init
arch-chroot /mnt pacman-key --populate archlinux
cat >> mnt/etc/pacman.conf << EOF
[multilib]
Include = /etc/pacman.d.mirrorlist
Color
ParallelDownloads = 10
EOF
pacman -Sy
pacman -S bash-completion openssh arch-install-scripts networkmanager git wget htop neofetch xdg-user-dirs pacman-contrib ntfs-3g

# создание начального загрузочного диска
arch-chroot /mnt mkinitcpio -p linux

# разрешение sudo для всех пользователей
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' mnt/etc/sudoers

# создание пользователя
echo -n "Username: "
read username
: "${username:?"Missing username"}"

echo -n "Password for user ${username}: "
read -s passwordUser
echo
echo -n "Repeat password: "
read -s password2User
echo
[[ "$passwordUser" == "$password2User" ]] || ( echo "Passwords did not match"; exit 1; )

arch-chroot /mnt useradd -mg users -G wheel "${username}"
echo "$username:$passwordUser" | chpasswd --root /mnt

# включение в загрузку сетевого менеджера
arch-chroot /mnt systemctl enable NetworkManager.service
# включение автоматической очистки кэша пакетов
arch-chroot /mnt systemctl enable paccache.timer

# установка Grub
pacstrap /mnt grub efibootmgr grub-btrfs os-prober
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# установка графических драйверов
pacstrap /mnt xf86-video-vesa

# размонтирование всех разделов
umount -R /mnt
