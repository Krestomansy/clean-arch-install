# clean-arch-install
My script for clean Arch Linux installation for VM

# Installation
pacman -Sy
pacman -S git dos2unix
git clone https://github.com/Krestomansy/clean-arch-install
cd clean-arch-install
chmod +x install.sh
dos2unix -- install.sh
exec bash
./install.sh
