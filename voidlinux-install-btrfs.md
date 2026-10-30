# Instalação do Void Linux com runit, BTRFS criptografado (incluindo /boot), AppArmor, GRUB, Snapper e rollback configurado.

> Guia nativo para Void Linux (runit, xbps, xchroot, xgenfstab, rc.conf).  
> Serviços habilitados com symlinks em `/etc/runit/runsvdir/default/` (chroot) ou `/var/service/` (sistema rodando).

---

## 1. Preparação e Particionamento

```bash
loadkeys br-abnt2
lsblk
cfdisk /dev/SEU_DISPOSITIVO
```

Crie apenas duas partições:

1. **Partição EFI:** 2 GB, tipo "EFI System".
2. **Partição Root:** O restante do disco, tipo "Linux filesystem".

Formate a partição EFI:

```bash
mkfs.vfat -n ESP /dev/PARTICAO_EFI
```

---

## 2. Criptografia LUKS e Criação do Volume BTRFS

A senha configurada aqui será a **única** pedida na inicialização (pelo GRUB). Escolha uma passphrase forte.

> **Atenção Void:** use `--pbkdf pbkdf2` obrigatoriamente. O GRUB ainda não suporta Argon2 (padrão do LUKS2 moderno).

```bash
cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 /dev/PARTICAO_ROOT
cryptsetup open /dev/PARTICAO_ROOT cryptroot
mkfs.btrfs /dev/mapper/cryptroot
```

---

## 3. Subvolumes BTRFS e Montagem

```bash
mount /dev/mapper/cryptroot /mnt
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@images
btrfs su cr /mnt/@containers
btrfs su cr /mnt/@var_log
btrfs su cr /mnt/@swap
btrfs su cr /mnt/@snapshots
umount /mnt
```

Monte os subvolumes com flags de compressão e otimização para SSD:

```bash
# Root (@)
mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@ /dev/mapper/cryptroot /mnt

# Diretórios de montagem
mkdir -p /mnt/{boot,etc,efi,home,.snapshots,var/log,var/lib/containers,var/lib/libvirt/images,swap}

# Subvolumes restantes
mount -o noatime,compress=zstd:3,ssd,subvol=@home       /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd:3,ssd,subvol=@var_log    /dev/mapper/cryptroot /mnt/var/log
mount -o noatime,compress=zstd:3,ssd,subvol=@snapshots  /dev/mapper/cryptroot /mnt/.snapshots
mount -o noatime,subvol=@images      /dev/mapper/cryptroot /mnt/var/lib/libvirt/images
mount -o noatime,subvol=@containers  /dev/mapper/cryptroot /mnt/var/lib/containers
mount -o noatime,subvol=@swap        /dev/mapper/cryptroot /mnt/swap

# Partição EFI — /boot fica dentro do root criptografado, GRUB vai no /efi
mount /dev/PARTICAO_EFI /mnt/efi
```

Desative CoW para diretórios que não se beneficiam dele:

```bash
chattr +C /mnt/var/lib/libvirt/images
chattr +C /mnt/var/lib/containers
chattr +C /mnt/swap
```

Crie o swapfile de 12 GB (compatível com a RAM do Lenovo Ideapad S145):

```bash
btrfs filesystem mkswapfile --size 12g --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile
```

---

## 4. Keyfile para evitar senha dupla

```bash
mkdir -m0700 /mnt/etc/keys
( umask 0077 && dd if=/dev/urandom bs=1 count=64 of=/mnt/etc/keys/root.key conv=excl,fsync )

# Adiciona a chave ao LUKS (pedirá a passphrase do passo 2)
cryptsetup luksAddKey /dev/PARTICAO_ROOT /mnt/etc/keys/root.key
```

Ainda fora do chroot, colete o UUID da partição física criptografada e crie o crypttab — ele precisa existir **antes** da geração do initramfs na seção 8:

```bash
blkid -o value -s UUID /dev/PARTICAO_ROOT > /mnt/etc/keys/root.uuid
echo "cryptroot UUID=$(cat /mnt/etc/keys/root.uuid) /etc/keys/root.key luks" > /mnt/etc/crypttab
```

---

## 5. Chaves de Repositório

Copie as chaves de assinatura do live ISO para o destino — sem elas o `xbps-install` não consegue verificar os pacotes:

```bash
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
```

---

## 6. Instalação do Sistema Base

> **Void:** o instalador de base é `xbps-install` com `-r /mnt` e o repositório configurado.

Configure os repositórios e instale o sistema base:

```bash
# Sincroniza repositórios apontando para /mnt
XBPS_ARCH=x86_64 xbps-install -S -R https://repo-default.voidlinux.org/current \
    -r /mnt base-system btrfs-progs cryptsetup grub-x86_64-efi efibootmgr \
    apparmor nano vim sudo bash-completion man-db man-pages void-repo-nonfree void-repo-multilib \
    void-repo-multilib-nonfree
```

Gere o fstab. 

```bash
# Opção 1 — via xtools (instale no live environment antes)
xgenfstab -U /mnt > /mnt/etc/fstab

```

---

## 7. Configurações do Sistema (Chroot)

> **Void:** o chroot é feito com `xchroot`, não `artix-chroot`. O `xchroot` faz o bind mount de `/dev`, `/proc`, `/sys` e `/run` automaticamente.

```bash
xchroot /mnt /bin/bash
```

### Fuso horário e localização


```bash
ln -sf /usr/share/zoneinfo/America/Maceio /etc/localtime
```

A única variável que precisa estar em `/etc/rc.conf` é o mapa de teclado (console):

```bash
vim /etc/rc.conf
```

> **Teclado no Void:** o core service `03-console-setup.sh` lê `KEYMAP` exclusivamente do `/etc/rc.conf` para rodar `loadkeys` no boot. (Não existe `vconsole.conf` no Void — isso é do systemd.)

Conteúdo a ser adicionado ou ajustado no `/etc/rc.conf`:

```
KEYMAP=br-abnt2
```

Gere os locales:

```bash
# Descomente en_US.UTF-8 UTF-8 e pt_BR.UTF-8 UTF-8
vim /etc/default/libc-locales
xbps-reconfigure -f glibc-locales
```

### Hostname e hosts

```bash
echo void-leninx > /etc/hostname
echo LANG=pt_BR.UTF-8 > /etc/locale.conf

cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   void-leninx.localdomain   void-leninx
EOF
```

### Senha do root e permissões

```bash
passwd root
chown root:root /
chmod 755 /
hwclock --systohc
```

---

## 8. Configurando o dracut para o Keyfile

> **Void:** usa **dracut** como gerador de initramfs por padrão, não `mkinitcpio`. A configuração é feita em `/etc/dracut.conf.d/`.

```bash
mkdir -p /etc/dracut.conf.d

# Modo host-only detecta apenas os módulos necessários pro hardware atual
# Inclui o keyfile e o crypttab no initramfs; habilita LUKS e BTRFS
cat <<EOF > /etc/dracut.conf.d/10-crypt.conf
hostonly="yes"
add_dracutmodules+=" crypt btrfs "
install_items+=" /etc/keys/root.key /etc/crypttab "
EOF
```

Gere o initramfs:

```bash
dracut --force --hostonly
```

> O `dracut` lê a configuração em `/etc/dracut.conf.d/10-crypt.conf` e inclui o keyfile + crypttab. Esta chamada manual é suficiente aqui; o `xbps-reconfigure -fa` no final da instalação regenera o initramfs com os hooks de kernel apropriados.

Restrinja o acesso ao `/boot` (o initramfs contém o keyfile):

```bash
chmod 700 /boot
```

---

## 9. Configuração do Bootloader (GRUB)

Obtenha o UUID da partição física criptografada:

```bash
blkid -o value -s UUID /dev/PARTICAO_ROOT
```

Edite `/etc/default/grub`:

```bash
vim /etc/default/grub
```

Ajuste as seguintes linhas:

```bash
# 1. Habilita descriptografia pelo GRUB (necessário para /boot criptografado)
GRUB_ENABLE_CRYPTODISK=y

# 2. Parâmetros do kernel: LUKS, keyfile, workaround do teclado defeituoso e AppArmor
GRUB_CMDLINE_LINUX="rd.luks.uuid=SEU_UUID_AQUI root=/dev/mapper/cryptroot rootflags=subvol=@ zswap.enable=0 rootfstype=btrfs modprobe.blacklist=atkbd i8042.nokbd"

# 3. LSM com AppArmor habilitado
GRUB_CMDLINE_LINUX_DEFAULT="apparmor=1 security=apparmor"
```

> **AppArmor no Void:** as políticas são carregadas automaticamente na inicialização via core service do `runit-void-apparmor` (dependência do pacote `apparmor` instalado na base). Não é necessário habilitar serviço separado. O modo padrão é `complain`; altere em `/etc/default/apparmor` se desejar `enforce`.

Instale e gere a configuração do GRUB:

```bash
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="voidlinux" --recheck
update-grub
```

> **Void:** o comando é `update-grub`, equivalente ao `grub-mkconfig -o /boot/grub/grub.cfg`.

---

## 10. Instalação de Pacotes e Serviços

> **Void:** serviços são habilitados com symlinks em **`/etc/runit/runsvdir/default/`**, não em `/run/runit/`. Dentro do chroot, use este caminho. Após o reboot, os links em `/var/service/` também funcionam (são equivalentes).

### Rede

```bash
xbps-install -S NetworkManager iwd openssh wget wpa_supplicant iproute2 \
    wireless_tools firewalld

ln -s /etc/sv/NetworkManager  /etc/runit/runsvdir/default/
ln -s /etc/sv/sshd             /etc/runit/runsvdir/default/
ln -s /etc/sv/firewalld        /etc/runit/runsvdir/default/
```

### Áudio, utilitários e virtualização

```bash
xbps-install -S pipewire wireplumber alsa-pipewire libspa-bluetooth \
    bluez rsync rclone btop syncthing virt-manager qemu libvirt \
    edk2-ovmf dnsmasq git xdg-utils xdg-user-dirs zip unzip unrar \
    cronie

ln -s /etc/sv/bluetoothd  /etc/runit/runsvdir/default/
ln -s /etc/sv/libvirtd    /etc/runit/runsvdir/default/
ln -s /etc/sv/dnsmasq     /etc/runit/runsvdir/default/
ln -s /etc/sv/cronie      /etc/runit/runsvdir/default/
```

> **PipeWire no Void:** não há serviço de sistema — o PipeWire é iniciado por usuário. A configuração abaixo é necessária para que o WirePlumber (session manager), a compatibilidade com PulseAudio e o ALSA funcionem. Faça esses passos **após o primeiro login** como seu usuário:

```bash
# Configura o session manager (WirePlumber) — sem isso, só áudio dummy
mkdir -p ~/.config/pipewire/pipewire.conf.d
ln -s /usr/share/examples/wireplumber/10-wireplumber.conf \
      ~/.config/pipewire/pipewire.conf.d/

# Interface PulseAudio — necessária para Firefox, Chromium, Spotify, etc.
ln -s /usr/share/examples/pipewire/20-pipewire-pulse.conf \
      ~/.config/pipewire/pipewire.conf.d/

# Integração ALSA — para apps que falam ALSA direto
sudo mkdir -p /etc/alsa/conf.d
sudo ln -s /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d
sudo ln -s /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d
```

> O `pipewire` é iniciado automaticamente pelo **KDE Plasma** via sessão. Para o **Niri**, o `spawn-at-startup "pipewire"` no `config.kdl` já resolve — desde que os symlinks acima estejam em `~/.config/pipewire/pipewire.conf.d/`. Teste com `wpctl status` depois do login.

### Vídeo e drivers AMD

```bash
xbps-install -S mesa mesa-dri vulkan-loader mesa-vulkan-radeon \
    xf86-video-amdgpu ffmpeg ImageMagick yt-dlp
```

> **Void:** `xf86-video-ati` (driver antigo) e `xf86-video-amdgpu` coexistem; para GPUs Radeon GCN+ prefira `xf86-video-amdgpu`.

### Zram

```bash
xbps-install -S zramen

# Configure antes de habilitar
vim /etc/sv/zramen/conf
# Ajuste:
# ZRAM_SIZE="ram / 2"
# ZRAM_COMPRESSION="zstd"
# ZRAM_PRIORITY="100"

ln -s /etc/sv/zramen /etc/runit/runsvdir/default/
```

### NTP / sincronização de horário

```bash
xbps-install -S chrony
ln -s /etc/sv/chronyd /etc/runit/runsvdir/default/
```

---



> **D-Bus e elogind no Void:** O `dbus` fornece o **system bus** — um serviço de sistema usado para IPC (comunicação entre processos). O `elogind` é uma reimplementação standalone do `systemd-logind`: gerencia `XDG_RUNTIME_DIR`, sessões de usuário, seats e power management. O elogind **depende** do system bus do dbus para funcionar. Ambos são serviços runit. Wayland compositors (Niri, MangoWC) precisam de ambos; o KDE Plasma também se beneficia do elogind (principalmente para ter `XDG_RUNTIME_DIR` automático e `loginctl`). O **session bus** do D-Bus (por usuário) é iniciado pelo display manager ou via `dbus-run-session` — este não é um serviço runit.

## 11. Ambiente Gráfico

### KDE Plasma

```bash
xbps-install -S plasma-desktop plasma-workspace sddm konsole kate dolphin \
    dolphin-plugins ffmpegthumbs ark gwenview spectacle okular \
    partitionmanager kcalc kdeconnect fuse-sshfs flatpak \
    noto-fonts-ttf noto-fonts-cjk noto-fonts-emoji \
    qbittorrent vlc

ln -s /etc/sv/sddm    /etc/runit/runsvdir/default/
ln -s /etc/sv/dbus    /etc/runit/runsvdir/default/
ln -s /etc/sv/elogind /etc/runit/runsvdir/default/
```

### Niri (Wayland compositor)

```bash
xbps-install -S niri alacritty fuzzel Waybar mako ddcutil mpv \
    xwayland-satellite swaybg swayidle swaylock ranger polkit \
    network-manager-applet xdg-desktop-portal xdg-desktop-portal-gtk \
    xdg-desktop-portal-gnome \
    gammastep noto-fonts-ttf noto-fonts-cjk noto-fonts-emoji \
    qalculate-gtk dbus elogind tuigreet greetd

ln -s /etc/sv/dbus    /etc/runit/runsvdir/default/
ln -s /etc/sv/elogind /etc/runit/runsvdir/default/
```

> **Portais:** `xdg-desktop-portal-gnome` + `xdg-desktop-portal-gtk` provêm suporte a seletor de arquivos, captura de tela e compartilhamento de tela no Niri.

Configuração do Niri (`~/.config/niri/config.kdl`):

```kdl
input {
    keyboard {
        xkb {
            layout "br"
        }
    }
}

spawn-at-startup "pipewire"
spawn-at-startup "xwayland-satellite"
spawn-at-startup "waybar"
```

### Pacotes extras

```bash
xbps-install -S podman crun android-tools opus-tools keepassxc
sudo vim /etc/containers/containers.conf
"[engine]
runtime = "crun""
```

> **Distrobox no Void:** o pacote `distrobox` pode não estar nos repositórios oficiais. Consulte o guia de criação de template xbps-src para buildá-lo localmente.

> **Fontes:** não há pacote avulso para JetBrains Mono. Duas opções: `nerd-fonts-ttf` (inclui versão Nerd Fonts com ícones, ~1.2 GB) ou instalar manualmente do site oficial.

---

## 12. Usuário e sudo

```bash
useradd -mG wheel,audio,video,plugdev,_seatd,kvm,libvirt kim
passwd kim
usermod -c "Kim" kim

# Habilite o grupo wheel no sudoers
EDITOR=vim visudo
# Descomente: %wheel ALL=(ALL:ALL) ALL
```

---

## 13. Finalização

Saia do chroot e reinicie:

```bash
# Remove o resolv.conf herdado do live — o NetworkManager criará um gerenciado no boot
rm -f /etc/resolv.conf

xbps-reconfigure -fa
exit
umount -R /mnt
reboot
```

Após o reboot, o GRUB pedirá a senha LUKS para acessar o `/boot`. O dracut usará `/etc/keys/root.key` para montar o root automaticamente, evitando a segunda digitação de senha.

---

## 14. Pós-instalação: Snapper e rollback com BTRFS

```bash
sudo xbps-install -S snapper grub-btrfs inotify-tools snapper-rollback
sudo ln -s /etc/sv/grub-btrfs /var/service/

# Remove o subvolume @snapshots que o snapper vai recriar
sudo umount /.snapshots
sudo rm -rf /.snapshots
sudo snapper -c root create-config /
sudo btrfs subvolume delete /.snapshots
sudo mkdir /.snapshots
sudo mount -a

# Ajuste as permissões do snapper
sudo vim /etc/snapper/configs/root
# Defina ALLOW_USERS="kim" e os limites de snapshots desejados
```


```
sudo vim /etc/snapper-rollback.conf
# Ajuste: mountpoint=/mnt e dev=/dev/mapper/cryptroot
```

---

## 15. Bônus: MangoWM (wl-only) via xbps-src

MangoWM é um compositor Wayland baseado em dwl. A versão dos repositórios (`mangowc`) usa `scenefx` e **não** suporta screen sharing. A branch `wl-only` usa `wlroots` vanilla, permitindo captura individual de janelas.

### 15.1 Setup do xbps-src

```bash
sudo xbps-install -S git
git clone https://github.com/void-linux/void-packages.git
cd void-packages
./xbps-src binary-bootstrap
```

> O `binary-bootstrap` baixa um conjunto mínimo de pacotes para compilar. Só precisa rodar uma vez.

### 15.2 Template — versão pinned (recomendada)

```bash
mkdir -p srcpkgs/mangowm-wlonly
```

```bash
cat > srcpkgs/mangowm-wlonly/template << 'EOF'
# Template file for 'mangowm-wlonly'
pkgname=mangowm-wlonly
version=0.15.5
revision=1
conf_files="/etc/mango/config.conf"
build_style=meson
hostmakedepends="pkg-config wayland-devel"
makedepends="cJSON-devel wlroots0.20-devel pcre2-devel pango-devel"
depends="xorg-server-xwayland"
short_desc="MangoWM without scenefx (wl-only branch)"
maintainer="SEU_NOME <seu@email>"
license="GPL-3.0-or-later"
homepage="https://github.com/mangowm/mango"
distfiles="https://github.com/mangowm/mango/archive/81c510ab714b85c2d90216b8cd6b29d2b385c33c.tar.gz"
checksum=skip
EOF
```

> Para obter o checksum real, rode `sha256sum $(./xbps-src fetch mangowm-wlonly 2>&1 | grep -o '/tmp/.*mango.*tar.gz')` e substitua `skip` pelo hash.

### 15.3 Build e instalação

```bash
cd ~/void-packages
./xbps-src pkg mangowm-wlonly
sudo xbps-install -R ~/void-packages/hostdir/binpkgs mangowm-wlonly
```

### 15.4 Versão rolling (manual, como um `-git`)

Se quiser a branch `wl-only` sempre atualizada (fora do xbps):

```bash
sudo xbps-install -S git meson wayland-devel cJSON-devel wlroots0.20-devel \
    pcre2-devel pango-devel xorg-server-xwayland

git clone -b wl-only https://github.com/mangowm/mango.git
cd mango
meson setup build
ninja -C build
sudo ninja -C build install
```

> Para atualizar: `git pull && ninja -C build && sudo ninja -C build install`.

### 15.5 Serviços necessários

```bash
sudo ln -s /etc/sv/dbus    /var/service/
sudo ln -s /etc/sv/elogind /var/service/
```

### 15.6 Greetd + tuigreet + portal

```bash
sudo xbps-install -S greetd tuigreet xdg-desktop-portal-wlr
```

```bash
sudo tee /etc/greetd/config.toml << 'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --cmd mango"
user = "_greeter"
EOF
```

```bash
sudo ln -s /etc/sv/greetd /var/service/
```

> **Portal:** `xdg-desktop-portal-wlr` fornece compartilhamento de tela via PipeWire neste compositor wlroots — essencial para captura individual de janelas. Os portais são ativados sob demanda via D-Bus, sem serviço runit separado.

> Verifique os logs com `sudo sv status greetd` ou `sudo tail -f /var/log/greetd/current` se não subir.

### 15.7 Configuração inicial

```bash
mkdir -p ~/.config/mango
cp /etc/mango/config.conf ~/.config/mango/
vim ~/.config/mango/config.conf
```

Atalhos padrão:

| Tecla | Ação |
|---|---|
| `Alt + Return` | Terminal (foot, se instalado) |
| `Alt + Space` | Launcher (rofi/fuzzel/wmenu) |
| `Alt + Q` | Fechar janela |
| `Alt + setas` | Foco direcional |
| `Alt + 1-9` | Tags (workspaces) |
| `Super + M` | Sair do Mango |

---

(Documento finalizado)
