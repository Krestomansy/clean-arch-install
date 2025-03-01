#!/bin/bash

username=$1

echo "$username ALL=(ALL:ALL) NOPASSWD: ALL" | tee /etc/sudoers.d/$username

su $username << EOF
cd ~
git clone https://aur.archlinux.org/yay.git
cd yay
echo "y" | makepkg -si
EOF

su $username << EOF
yay -S --noconfirm timeshift-autosnap
EOF

rm /etc/sudoers.d/$username
