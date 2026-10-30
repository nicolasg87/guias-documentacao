### Instalação do Artix Linux com OpenRC, BTRFS criptografado (incluindo /boot), apparmor, grub, snapper e scripts para rollback configurado.
### 1. Preparação e Particionamento

```bash
loadkeys br-abnt2
lsblk
cfdisk /dev/SEU_DISPOSITIVO

```

Crie apenas duas partições:

1. 
**Partição EFI:** 1GB, tipo "EFI System".


2. 
**Partição Root:** O restante do disco, tipo "Linux filesystem".



Formate a partição EFI:

```bash
mkfs.fat -F32 -n ESP /dev/PARTICAO_EFI

```

### 2. Criptografia LUKS e Criação do Keyfile Inicial

A senha que você configurar aqui será a **única** que você precisará digitar ao ligar o computador (o GRUB pedirá ela). Escolha uma passphrase forte.

```bash
cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 /dev/PARTICAO_ROOT
cryptsetup open /dev/PARTICAO_ROOT cryptroot
mkfs.btrfs /dev/mapper/cryptroot

```

### 3. Subvolumes BTRFS e Montagem

Vamos montar a raiz temporariamente para criar o seu layout de subvolumes exato.

```bash
mount /dev/mapper/cryptroot /mnt
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@images
btrfs su cr /mnt/@containers
btrfs su cr /mnt/@pkg
btrfs su cr /mnt/@var_log
btrfs su cr /mnt/@swap
btrfs su cr /mnt/@tmp
btrfs su cr /mnt/@snapshots
umount /mnt

```

Agora, vamos montar os subvolumes com as flags de compressão e otimização para SSD, além de preparar os diretórios que não devem ter Copy-on-Write (CoW):

```bash
# Montando o root (@) primeiro
mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@ /dev/mapper/cryptroot /mnt

# Criando as pastas de montagem
mkdir -p /mnt/{boot,efi,home,.snapshots,var/log,var/lib/containers,var/lib/libvirt/images,var/tmp,var/cache/pacman/pkg,swap}

# Montando o restante
mount -o noatime,compress=zstd:3,ssd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd:3,ssd,subvol=@var_log /dev/mapper/cryptroot /mnt/var/log
mount -o noatime,compress=zstd:3,ssd,subvol=@tmp /dev/mapper/cryptroot /mnt/var/tmp
mount -o noatime,compress=zstd:3,ssd,subvol=@pkg /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o noatime,compress=zstd:3,ssd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount -o noatime,subvol=@images /dev/mapper/cryptroot /mnt/var/lib/libvirt/images
mount -o noatime,subvol=@containers /dev/mapper/cryptroot /mnt/var/lib/containers
mount -o noatime,subvol=@swap /dev/mapper/cryptroot /mnt/swap

# Montando a partição EFI (O /boot fica dentro do root criptografado, e o GRUB vai no /efi)
mount /dev/PARTICAO_EFI /mnt/efi

```

# Desativando CoW para diretórios específicos:
```
chattr +C /mnt/var/lib/libvirt/images
chattr +C /mnt/var/lib/containers
chattr +C /mnt/swap
```


Criando o swapfile de 12GB para atuar como fallback junto ao zram. Esse tamanho casa perfeitamente com a quantidade total de RAM do seu Lenovo Ideapad S145:

```bash
btrfs filesystem mkswapfile --size 12g --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile

```

### 4. Criação e Adição do Keyfile

Aqui está o segredo para evitar a senha dupla. Vamos gerar um arquivo de chave dentro do root criptografado e adicioná-lo ao LUKS.

```bash
# Gera o arquivo de chave de forma aleatória
mkdir -m0700 /mnt/etc/keys
( umask 0077 && dd if=/dev/urandom bs=1 count=64 of=/mnt/etc/keys/root.key conv=excl,fsync )

# Adiciona a chave ao LUKS (você precisará digitar a passphrase que criou no passo 2)
cryptsetup luksAddKey /dev/PARTICAO_ROOT /mnt/etc/keys/root.key

```

### 5. Instalação do Sistema Base e Pacotes

Antes de começar, ative os downloads paralelos no `/etc/pacman.conf`:

```bash
nano /etc/pacman.conf # Descomente a linha 'ParallelDownloads = 5'

```

Instale os pacotes base (incluindo o microcódigo correto para o seu processador Ryzen) e gere o `fstab`:

```bash
basestrap /mnt base base-devel openrc elogind-openrc linux linux-lts linux-headers linux-lts-headers linux-firmware btrfs-progs apparmor-openrc nano vim amd-ucode man-db man-pages texinfo cryptsetup-openrc device-mapper-openrc grub efibootmgr bash-completion

fstabgen -U /mnt >> /mnt/etc/fstab

```

### 6. Configurações do Sistema (Chroot)

Entre no sistema recém-instalado:

```bash
artix-chroot /mnt

```

Ajuste do fuso horário para a nossa região e configurações de localização:

```bash
ln -sf /usr/share/zoneinfo/America/Maceio /etc/localtime
hwclock --systohc
pacman -S chrony chrony-openrc
rc-update add chrony default

nano /etc/locale.gen # Descomente en_US.UTF-8 UTF-8 e pt_BR.UTF-8 UTF-8
locale-gen

echo LANG=pt_BR.UTF-8 > /etc/locale.conf
vim /etc/conf.d/keymaps
# Modifique para: keymap="br-abnt2"

echo artix-leninx > /etc/hostname

cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   artix-leninx.localdomain   artix-leninx
EOF

```

### 7. Configurando o mkinitcpio para o Keyfile

Este é um passo crucial. Precisamos garantir que o arquivo de chave seja incluído na imagem de boot e que o hook de criptografia seja carregado.

```bash
vim /etc/mkinitcpio.conf

```

* Na linha `FILES=()`, adicione o keyfile:
`FILES=(/etc/keys/root.key)`
* Na linha `HOOKS=()`, garanta que `encrypt` esteja presente logo após `block` e antes de `filesystems`. Deverá ficar parecido com isso:
`HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)`



Gere as imagens:

```bash
mkinitcpio -P

```

*Nota de segurança:* Como o initramfs agora contém a chave para descriptografar o seu disco, é recomendado restringir o acesso à pasta `/boot`:

```bash
chmod 700 /boot

```

### 8. Configuração do Bootloader (GRUB)

Primeiro, pegue o UUID da partição física criptografada (não do mapper) e envie para o arquivo do GRUB para facilitar a edição:

```bash
blkid -o value -s UUID /dev/PARTICAO_ROOT >> /etc/default/grub
vim /etc/default/grub

```

Edite as seguintes linhas no `/etc/default/grub`:

1. 
**Descomente** a linha: `GRUB_ENABLE_CRYPTODISK=y` (Isso faz o GRUB pedir a senha para ler o `/boot`).


2. 
**Edite** a linha `GRUB_CMDLINE_LINUX` para incluir as instruções do LUKS, a localização do keyfile e o seu workaround do teclado embutido defeituoso:



```text

GRUB_CMDLINE_LINUX="cryptdevice=UUID=SEU_UUID_AQUI:cryptroot cryptkey=rootfs:/etc/keys/root.key root=/dev/mapper/cryptroot rootflags=subvol=@ zswap.enable=0 rootfstype=btrfs modprobe.blacklist=atkbd i8042.nokbd"
# configuração do teclado

```

*(Lembre-se de deletar o UUID solto no final do arquivo que você enviou pelo `blkid`)*

3.
É preciso editar a linha `GRUB_CMDLINE_LINUX_DEFAULT` para adicionar `apparmor` aos parâmetros do kernel:
```text
GRUB_CMDLINE_LINUX_DEFAULT="lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

```

Instale e gere a configuração do GRUB:

```bash
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="artixlinux" --recheck
grub-mkconfig -o /boot/grub/grub.cfg

```

### 9. Instalação de Pacotes e Pós-Instalação

## Instalação do Network Manager e Redes:
```bash
pacman -S networkmanager networkmanager-openrc wireless_tools iwd openssh openssh-openrc wget dialog mtools dosfstools firewalld firewalld-openrc

```

## Áudio, utilitários e Virtualização:
```bash
pacman -S pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack gst-plugin-pipewire wireplumber libpulse bluez bluez-openrc bluez-utils rsync rclone btop syncthing syncthing-openrc virt-manager qemu-desktop libvirt libvirt-openrc edk2-ovmf dnsmasq dnsmasq-openrc dosfstools smartmontools mtools git xdg-utils xdg-user-dirs pacman-contrib aspell aspell-pt aspell-en power-profile-daemon power-profile-daemon-openrc rclone rsync zip unzip unrar btop cronie

```

## Vídeo, drivers e outros:
```bash
pacman -S mesa vulkan-radeon xf86-video-ati xf86-video-amdgpu xf86-video-vesa ffmpeg imagemagick yt-dlp

```
# Zram
```bash
pacman -S zramen zramen-openrc
vim /etc/conf.d/zramen

# Usar metade da RAM
ZRAM_SIZE="ram / 2"

# Algoritmo de compressão zstd
ZRAM_COMPRESSION="zstd"

# Prioridade 100
ZRAM_PRIORITY="100"

rc-update add zramen default

```

## Instação de ambiente gráfico:
# KDE Plasma:
```bash
pacman -S plasma-meta sddm sddm-openrc konsole kate dolphin dolphin-plugins ffmpegthumbs kimageformats filelight flatpak flatpak-kcm ark gwenview spectacle okular skanpage partitionmanager kasts kcalc merkuro kdepim-addons plasma-workspace xdg-desktop-portal-gtk vlc vlc-plugin-matroska vlc-plugin-x264 vlc-plugin-x265 vlc-plugin-dca vlc-plugin-ffmpeg vlc-plugin-ass vlc-plugin-freetype vlc-plugin-srt kdeconnect sshfs noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ttf-jetbrains-mono qbittorrent

rc-update add sddm default
rc-update add dbus default

```

# Niri e softwares diversos
```bash
pacman -S niri alacritty fuzzel waybar mako ddcutil mpv xwayland-satellite waybar swaybg swayidle swaylock xdg-desktop-portal-gnome ranger polkit network-manager-applet xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome gammastep noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ttf-jetbrains-mono qalculate-gtk dbus dbus-openrc elogind elogind-openrc ly ly-openrc

rc-update add dbus default
rc-update add ly default

// Exemplo de adição ao ~/.config/niri/config.kdl
// Niri >= 25.08 gerencia o xwayland-satellite automaticamente
spawn-at-startup "dbus-update-activation-environment" "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP"
spawn-at-startup "pipewire"
spawn-at-startup "wireplumber"
spawn-at-startup "pipewire-pulse"
spawn-at-startup "waybar"

```

# Mangowm (compositor Wayland, sem display manager):
```bash
# Dependências
pacman -S cjson pango pcre2 xorg-xwayland wayland-protocols \
          xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
          pipewire-openrc

# AUR helper (yay)
pacman -S --needed base-devel git
git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
cd /tmp/yay-bin && makepkg -si && cd ~

# wlroots 0.20 + mangowm (wl-only, sem scenefx)
yay -S wlroots0.20 mangowm-wlonly-git

# dbus (já deve estar, mas garantimos)
rc-update add dbus default

# Autostart no TTY1 (sem DM) — dbus-run-session cria o bus e executa o mango
echo '[[ "$(tty)" == /dev/tty1 ]] && exec dbus-run-session mango' >> ~/.bash_profile

# --- Pipewire: duas opções ---

# Opção A) iniciar pelo exec-once do mango (mais simples)
# ~/.config/mango/config.conf:
#   exec-once=pipewire
#   exec-once=wireplumber
#   exec-once=pipewire-pulse

# Opção B) user services do OpenRC (mais "Artix way", serviços independentes)
# O pipewire-openrc já fornece os scripts de usuário
#   rc-update --user add pipewire default
#   rc-update --user add wireplumber default
#   rc-update --user add pipewire-pulse default
#   rc-service --user pipewire start
#   rc-service --user wireplumber start
# OBS: o dbus-run-session no .bash_profile é necessário de qualquer forma
#     até o OpenRC PR #782 ser mergeado (seta DBUS_SESSION_BUS_ADDRESS)

# Config: mkdir -p ~/.config/mango && cp /etc/mango/config.conf ~/.config/mango/
# Portal config: mkdir -p ~/.config/xdg-desktop-portal
# ~/.config/xdg-desktop-portal/mango-portals.conf:
#   [preferred]
#   default=gtk
#   org.freedesktop.impl.portal.ScreenCast=wlr
#   org.freedesktop.impl.portal.Screenshot=wlr
```

## Ativar alguns serviços necessários:
```bash
rc-update add NetworkManager default
rc-update add sshd default
rc-update add bluetooth default
rc-update add libvirtd default
rc-update add cupsd default
rc-update add apparmor boot 
rc-update add cronie default
```

Configuração de Usuário:

```bash
useradd -mG wheel kim
passwd kim
usermod -c "Kim" kim

EDITOR=vim visudo # Descomente a linha: %wheel ALL=(ALL) ALL

```

### 10. Finalização

Saia do chroot e reinicie:

```bash
exit
umount -R /mnt
reboot

```

Após o reboot, o GRUB pedirá a senha do LUKS para acessar o `/boot`. Depois disso, o `mkinitcpio` usará o `/etc/keys/root.key` para montar o `/` automaticamente, poupando a segunda senha. Quando logar no sistema, finalize a configuração do Snapper:

```bash
sudo pacman -S grub-btrfs inotify-tools snapper
sudo umount /.snapshots
sudo rm -r /.snapshots
sudo snapper -c root create-config /
sudo btrfs subvolume delete /.snapshots
sudo mkdir /.snapshots
sudo mount -a
sudo pacman -S snap-pac
sudo vim /etc/snapper/configs/root

sudo vim /etc/init.d/grub-btrfsd

# Dentro
#!/sbin/openrc-run
description="grub-btrfsd inotify daemon"
pidfile="/run/grub-btrfsd.pid"
command="/usr/bin/grub-btrfsd"
command_args="--syslog -r /.snapshots"
# ou '--timeshift-auto' para timeshift
command_background=true

depend() {
    need localmount
}

sudo chmod +x /etc/init.d/grub-btrfsd
sudo rc-update add grub-btrfsd default
sudo rc-service grub-btrfsd start


## Puxamos também agora o snapper-rollback script, que facilita os rollbacks
mkdir ~/Devel && cd ~/Devel/
git clone https://github.com/jrabinow/snapper-rollback.git
cd snapper-rollback/
sudo cp snapper-rollback.py /usr/local/sbin/snapper-rollback
sudo cp snapper-rollback.conf /etc/
sudo vim /etc/snapper-rollback.conf 
# a configuração troca o mountpoint para /mnt e declara o dev como /dev/mapper/cryptroot.

```
