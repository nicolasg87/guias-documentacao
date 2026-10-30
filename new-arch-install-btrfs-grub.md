### Instalação do Arch Linux com BTRFS criptografado (incluindo /boot), apparmor, grub, snapper e scripts para rollback configurado.
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

# Desativando CoW para pastas específicas ANTES de montar os subvolumes nelas
chattr +C /mnt/var/lib/libvirt/images
chattr +C /mnt/var/lib/containers
chattr +C /mnt/swap

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
cryptsetup luksAddKey /dev/PARTICAO_ROOT /etc/keys/root.key

# Adiciona a chave ao LUKS (você precisará digitar a passphrase que criou no passo 2)
cryptsetup luksAddKey /dev/PARTICAO_ROOT /mnt/etc/keys/root.key

```

### 5. Instalação do Sistema Base e Pacotes

Antes de começar, ative os downloads paralelos no `/etc/pacman.conf` e gere uma lista atualizada de mirrors:

```bash
nano /etc/pacman.conf # Descomente a linha 'ParallelDownloads = 5'
reflector --country Brazil --protocol https --latest 5 --sort rate --save /etc/pacman.d/mirrorlist

```

Instale os pacotes base (incluindo o microcódigo correto para o seu processador Ryzen) e gere o `fstab`:

```bash
pacstrap -K /mnt base base-devel linux linux-lts linux-headers linux-lts-headers linux-firmware btrfs-progs apparmor nano vim amd-ucode man-db man-pages texinfo cryptsetup grub efibootmgr bash-completion
genfstab -U /mnt >> /mnt/etc/fstab

```

### 6. Configurações do Sistema (Chroot)

Entre no sistema recém-instalado:

```bash
arch-chroot /mnt

```

Ajuste do fuso horário para a nossa região e configurações de localização:

```bash
ln -sf /usr/share/zoneinfo/America/Maceio /etc/localtime
hwclock --systohc

nano /etc/locale.gen # Descomente en_US.UTF-8 UTF-8 e pt_BR.UTF-8 UTF-8
locale-gen

echo LANG=pt_BR.UTF-8 > /etc/locale.conf
echo KEYMAP=br-abnt2 > /etc/vconsole.conf
localectl set-x11-keymap br abnt2
echo archlinux > /etc/hostname

cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   archlinux.localdomain   archlinux
EOF

```

### 7. Configurando o mkinitcpio para o Keyfile

Este é um passo crucial. Precisamos garantir que o arquivo de chave seja incluído na imagem de boot e que o hook de criptografia seja carregado.

```bash
nano /etc/mkinitcpio.conf

```

* Na linha `FILES=()`, adicione o keyfile:
`FILES=(/etc/keys/root.key)`
* Na linha `HOOKS=()`, garanta que `sd-encrypt` esteja presente logo após `block` e antes de `filesystems`. Deverá ficar parecido com isso:
`HOOKS=(base systemd autodetect microcode modconf kms keyboard keymap consolefont block sd-encrypt filesystems fsck)`



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
nano /etc/default/grub

```

Edite as seguintes linhas no `/etc/default/grub`:

1. 
**Descomente** a linha: `GRUB_ENABLE_CRYPTODISK=y` (Isso faz o GRUB pedir a senha para ler o `/boot`).


2. 
**Edite** a linha `GRUB_CMDLINE_LINUX` para incluir as instruções do LUKS, a localização do keyfile e o seu workaround do teclado embutido defeituoso:



```text
GRUB_CMDLINE_LINUX="rd.luks.name=UUID-PARTIÇÃO=cryptroot rd.luks.key=UUID-PARTIÇÃO=/etc/keys/root.key root=/dev/mapper/cryptroot rootflags=subvol=@ zswap.enable=0 rootfstype=btrfs"
# configuração do teclado
modprobe.blacklist=atkbd i8042.nokbd

```

*(Lembre-se de deletar o UUID solto no final do arquivo que você enviou pelo `blkid`)*

3.
É preciso editar a linha `GRUB_CMDLINE_LINUX_DEFAULT` para adicionar `apparmor` aos parâmetros do kernel:
```text
GRUB_CMDLINE_LINUX_DEFAULT="lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

```

Instale e gere a configuração do GRUB:

```bash
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="archlinux" --recheck
grub-mkconfig -o /boot/grub/grub.cfg

```

### 9. Instalação de Pacotes e Pós-Instalação

Instale seus pacotes de rede, áudio e o meta-pacote do Plasma, mantendo os downloads paralelos no `pacman.conf` e o repositório `multilib` ativados conforme seu rascunho original:

```bash
# Redes e utilitários
pacman -S networkmanager wireless_tools iwd openssh wget dialog mtools dosfstools smartmontools ntfs-3g git bluez bluez-utils pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack gst-plugin-pipewire wireplumber libpulse xdg-utils xdg-user-dirs aspell aspell-pt aspell-en pacman-contrib zram-generator tuned tuned-ppd rsync rclone ffmpeg mesa vulkan-radeon xf86-video-ati xf86-video-amdgpu xf86-video-vesa podman distrobox android-tools opus-tools unrar zip unzip firewalld imagemagick yt-dlp btop syncthing
 
# KDE Plasma e softwares diversos 
pacman -S plasma-meta konsole kate dolphin dolphin-plugins ffmpegthumbs kimageformats filelight flatpak flatpak-kcm ark gwenview spectacle okular skanpage partitionmanager kasts kcalc merkuro kdepim-addons plasma-workspace xdg-desktop-portal-gtk firefox firefox-i18n-pt-br fastfetch vlc vlc-plugin-matroska vlc-plugin-x264 vlc-plugin-x265 vlc-plugin-dca vlc-plugin-ffmpeg vlc-plugin-ass vlc-plugin-freetype vlc-plugin-srt virt-manager qemu-desktop dnsmasq edk2-ovmf bash-completion cups kdeconnect sshfs keepassxc libreoffice-fresh-pt-br mkvtoolnix-cli noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ttf-jetbrains-mono qbittorrent

# Niri e softwares diversos
pacman -S niri alacritty fuzzel mako xwayland-satellite waybar swaybg swayidle swaylock xdg-desktop-portal-gnome ranger polkit network-manager-applet

```

Habilite os serviços e crie o arquivo de tema do SDDM:

```bash
systemctl enable sddm
cat <<EOF > /etc/sddm.conf
[Theme]
Current=breeze
EOF

systemctl enable virtqemud.socket virtnetworkd.socket virtstoraged.socket virtproxyd.socket
systemctl enable cups.socket
[cite_start]systemctl enable paccache.timer # Limpa o cache do pacman semanalmente, mantendo 3 versões[cite: 18, 19].
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable tuned
systemctl enable tuned-ppd

```

Configuração de Usuário:

```bash
useradd -mG wheel kim
passwd kim
usermod -c "Kim" kim

EDITOR=nano visudo # Descomente a linha: %wheel ALL=(ALL) ALL

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
sudo systemctl enable --now grub-btrfsd
sudo umount /.snapshots
sudo rm -r /.snapshots
sudo snapper -c root create-config /
sudo btrfs subvolume delete /.snapshots
sudo mkdir /.snapshots
sudo mount -a
sudo pacman -S snap-pac
sudo vim /etc/snapper/configs/root

## Puxamos também agora o snapper-rollback script, que facilita os rollbacks
mkdir ~/Devel && cd ~/Devel/
git clone https://github.com/jrabinow/snapper-rollback.git
cd snapper-rollback/
sudo cp snapper-rollback.py /usr/local/sbin/snapper-rollback
sudo cp snapper-rollback.conf /etc/
sudo vim /etc/snapper-rollback.conf 
# a configuração troca o mountpoint para /mnt e declara o dev como /dev/mapper/cryptroot.

```
