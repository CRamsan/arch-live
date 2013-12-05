#!/bin/bash

set -e -u

sed -i 's/#\(en_US\.UTF-8\)/\1/' /etc/locale.gen
locale-gen

ln -sf /usr/share/zoneinfo/America/North_Dakota/Center /etc/localtime

usermod -s /usr/bin/zsh root
cp -aT /etc/skel/ /root/

#useradd -m -p "" -g users -G "adm,audio,floppy,log,network,rfkill,scanner,storage,optical,power,wheel" -s /usr/bin/zsh arch

chmod 750 /etc/sudoers.d
chmod 440 /etc/sudoers.d/g_wheel

sed -i "s/#Server/Server/g" /etc/pacman.d/mirrorlist
sed -i 's/#\(Storage=\)auto/\1volatile/' /etc/systemd/journald.conf

systemctl enable multi-user.target pacman-init.service choose-mirror.service

# Create the user directory for live session
if [ ! -d /home/cesar ]; then
    mkdir /home/cesar 
fi
# Copy files over to home
#su -c "cp -r /etc/skel/.* /home/cesar/" cesar
cp -r /etc/skel/.yubico /home/cesar/
cp -r /etc/skel/.bashrc /home/cesar/
cp -r /etc/skel/.google_authenticator /home/cesar/
cp -r /etc/skel/aur /home/cesar/
chown -R cesar:cesar /home/cesar
