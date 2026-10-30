# Instalação do Arch Linux com BTRFS criptografado (LUKS2), systemd-boot + UKI, AppArmor e Snapper

## O que muda em relação à versão com GRUB

- **GRUB sai, systemd-boot entra.** Como o kernel + initramfs + cmdline agora viram uma única **Unified Kernel Image (UKI)**, guardada já pronta na ESP (que nunca é criptografada), o bootloader não precisa mais descriptografar nada. Ele só carrega um `.efi` normal.
- **Acabou a senha dupla e o keyfile.** No fluxo antigo, o GRUB pedia a senha pra ler o `/boot` criptografado, e depois o initramfs precisava de novo — daí o keyfile pra evitar digitar duas vezes. Agora só existe **uma** etapa de descriptografia: o initramfs embutido na UKI (que já está acessível, sem precisar decifrar nada antes) pede a passphrase do LUKS para montar a raiz. Não precisamos mais gerar `/etc/keys/root.key`.
- **KDF do LUKS volta ao padrão (argon2id).** O `--pbkdf pbkdf2` só existia porque o GRUB não sabia lidar com argon2id. Sem GRUB no caminho, usamos o padrão do `cryptsetup`, que é mais resistente a ataque de força bruta.
- **Manutenção fica automática.** Hooks do pacman reconstroem a UKI sozinhos a cada atualização de kernel/microcódigo/systemd. O único item de configuração manual é habilitar o `systemd-boot-update.service` uma vez.

---

## 1. Preparação e Particionamento

```bash
loadkeys br-abnt2
lsblk
cfdisk /dev/SEU_DISPOSITIVO
```

Crie apenas duas partições:

1. **Partição EFI:** 1GB, tipo "EFI System".
2. **Partição Root:** o restante do disco, tipo "Linux filesystem".

Formate a partição EFI:

```bash
mkfs.fat -F32 -n ESP /dev/PARTICAO_EFI
```

## 2. Criptografia LUKS2 e Btrfs

Sem GRUB no meio do caminho, usamos o KDF padrão (argon2id) — mais seguro que pbkdf2:

```bash
cryptsetup luksFormat --type luks2 /dev/PARTICAO_ROOT
cryptsetup open /dev/PARTICAO_ROOT cryptroot
mkfs.btrfs /dev/mapper/cryptroot
```

Essa será a **única** senha pedida no boot, digitada uma única vez.

## 3. Subvolumes Btrfs e Montagem

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

Monte tudo com as flags de compressão/SSD:

```bash
# Root (@) primeiro
mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@ /dev/mapper/cryptroot /mnt

mkdir -p /mnt/{efi,home,.snapshots,var/log,var/lib/containers,var/lib/libvirt/images,var/tmp,var/cache/pacman/pkg,swap}

mount -o noatime,compress=zstd:3,ssd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd:3,ssd,subvol=@var_log /dev/mapper/cryptroot /mnt/var/log
mount -o noatime,compress=zstd:3,ssd,subvol=@tmp /dev/mapper/cryptroot /mnt/var/tmp
mount -o noatime,compress=zstd:3,ssd,subvol=@pkg /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o noatime,compress=zstd:3,ssd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount -o noatime,subvol=@images /dev/mapper/cryptroot /mnt/var/lib/libvirt/images
mount -o noatime,subvol=@containers /dev/mapper/cryptroot /mnt/var/lib/containers
mount -o noatime,subvol=@swap /dev/mapper/cryptroot /mnt/swap

# ESP: aqui vive a UKI, não o GRUB
mount /dev/PARTICAO_EFI /mnt/efi
```

> Note que **não existe mais um `/boot` separado nem montado à parte** — ele é só um diretório dentro de `@`, criptografado junto com o resto do sistema. Só a UKI final (já compilada) vai para a ESP.

**Só agora, com os subvolumes já montados, desative o Copy-on-Write.** O atributo NoCOW (`chattr +C`) é setado por inode e só pode ser aplicado a arquivos/diretórios vazios; se você rodar `chattr +C` num diretório *antes* de montar um subvolume por cima dele, o comando não tem efeito nenhum — o mount esconde aquele diretório e expõe a raiz do subvolume, que é uma inode diferente e continua com CoW ativado. A ordem certa é: montar → aplicar `chattr +C` na raiz do subvolume já montado (ainda vazia) → só então criar os arquivos ali dentro.

```bash
chattr +C /mnt/var/lib/libvirt/images
chattr +C /mnt/var/lib/containers
chattr +C /mnt/swap
```

Swapfile de 12GB, como fallback do zram (a prioridade dele é menor que a do zram por padrão; vamos deixar explícito com `-p 5`):

```bash
btrfs filesystem mkswapfile --size 12g --uuid clear /mnt/swap/swapfile
swapon -p 5 /mnt/swap/swapfile
```

## 4. Conectividade (Wi-Fi)

Se você estiver usando cabo de rede, pule esta seção. A ISO do Arch já inclui o `iwd` com o utilitário `iwctl` para conexão sem fio:

```bash
iwctl station list                          # Liste as interfaces
iwctl station wlan0 scan                    # Escaneie redes
sleep 3
iwctl station wlan0 get-networks            # Veja as redes disponíveis
iwctl station wlan0 connect "NOME_DA_REDE"  # Conecte (pedirá a senha)
```

Substitua `wlan0` pelo nome da sua interface (veja com `iwctl station list`). Teste com `ping archlinux.org` antes de prosseguir.

## 5. Instalação do Sistema Base

```bash
nano /etc/pacman.conf # Descomente 'ParallelDownloads = 5'
```

```bash
pacstrap -K /mnt base base-devel linux linux-lts linux-headers linux-lts-headers \
  linux-firmware btrfs-progs apparmor nano vim amd-ucode man-db man-pages texinfo \
  cryptsetup systemd-ukify efibootmgr bash-completion reflector

genfstab -U /mnt >> /mnt/etc/fstab
```

`systemd-ukify` é o pacote que fornece o `ukify`, usado pelo `mkinitcpio` para montar a UKI. `reflector` será usado dentro do chroot para gerar os espelhos já no sistema instalado.

## 6. Chroot e Configurações Básicas

```bash
arch-chroot /mnt
```

Dentro do chroot, gere os espelhos atualizados (reflector é mais útil aqui do que no livecd, pois o mirrorlist vai persistir no sistema instalado):

```bash
reflector --country Brazil --protocol https --latest 5 --sort rate --save /etc/pacman.d/mirrorlist
```

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

## 7. mkinitcpio: gerando a UKI

Primeiro, pegue o UUID da partição **física** (não do mapper) para usar no cmdline:

```bash
blkid -s UUID -o value /dev/PARTICAO_ROOT
```

### 7.1 Hooks

Edite `/etc/mkinitcpio.conf` e garanta que `sd-encrypt` esteja presente (variante systemd, sem keyfile — a senha é pedida interativamente):

```text
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
```

Repare que trocamos `keymap consolefont` por `sd-vconsole`: são hooks equivalentes, mas `keymap`/`consolefont` pertencem à variante busybox do initramfs. Como estamos usando o hook `systemd`, o correto — e o que a própria [ArchWiki recomenda](https://wiki.archlinux.org/title/Dm-crypt/System_configuration) para configurações com `sd-encrypt` — é `sd-vconsole`, que cobre layout de teclado e fonte do console de uma vez só.

Não precisamos mais da linha `FILES=(/etc/keys/root.key)`.

### 7.2 Cmdline do kernel

Crie `/etc/kernel/cmdline` com tudo que antes ia espalhado entre `GRUB_CMDLINE_LINUX` e `GRUB_CMDLINE_LINUX_DEFAULT`:

```bash
cat <<'EOF' > /etc/kernel/cmdline
rd.luks.name=UUID_DA_PARTICAO=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rootfstype=btrfs rw zswap.enable=0 lsm=landlock,lockdown,yama,integrity,apparmor,bpf modprobe.blacklist=atkbd i8042.nokbd
EOF
```

Substitua `UUID_DA_PARTICAO` pelo UUID que você pegou com `blkid`.

> `modprobe.blacklist=atkbd` desativa o driver de teclado AT (desnecessário em máquinas modernas), e `i8042.nokbd` é um parâmetro *separado* que instrui o driver i8042 a não detectar teclado — juntos evitam falsos toques durante a digitação da senha LUKS.

### 7.3 Preset: gerar UKI em vez de initramfs solto

Edite `/etc/mkinitcpio.d/linux.preset` (e o `linux-lts.preset`, se for usar o kernel LTS também) trocando `default_image`/`fallback_image` por `default_uki`/`fallback_uki`:

```text
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"

PRESETS=('default' 'fallback')

#default_image="/boot/initramfs-linux.img"
default_uki="/efi/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

#fallback_image="/boot/initramfs-linux-fallback.img"
fallback_uki="/efi/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
```

Para o kernel LTS, ajuste `ALL_kver="/boot/vmlinuz-linux-lts"` e mude os nomes das UKIs (ex.: `arch-linux-lts.efi` e `arch-linux-lts-fallback.efi`).

Crie o diretório de destino e gere as imagens:

```bash
mkdir -p /efi/EFI/Linux
mkinitcpio -P
```

> **Nota de segurança:** diferente do keyfile do guia antigo, agora o initramfs embutido na UKI não contém nenhum segredo — ele só sabe *pedir* a senha, não *guardar* uma. Ficar na ESP sem criptografia é o modelo de segurança padrão de qualquer setup com UKI. Se quiser um passo a mais de proteção contra adulteração (evil maid), isso é resolvido depois com Secure Boot + `sbctl`, não é obrigatório para o setup funcionar.

## 8. Instalando o systemd-boot

```bash
bootctl --esp-path=/efi install
systemctl enable systemd-boot-update.service
```

Isso copia o binário do systemd-boot para a ESP e garante que ele se atualize sozinho quando o pacote `systemd` for atualizado. O systemd-boot detecta automaticamente as UKIs dentro de `/efi/EFI/Linux/` — não é necessário escrever nenhum arquivo de entrada manualmente.

Opcionalmente, ajuste o timeout do menu de boot e a entrada padrão em `/efi/loader/loader.conf`:

```text
default arch-linux-lts.efi
timeout 3
console-mode max
```

## 9. Pacotes de Rede, Áudio, Plasma e Niri

```bash
# Redes e utilitários
pacman -S networkmanager wireless_tools iwd openssh wget dialog mtools dosfstools smartmontools ntfs-3g git bluez bluez-utils pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack gst-plugin-pipewire wireplumber libpulse xdg-utils xdg-user-dirs aspell aspell-pt aspell-en pacman-contrib zram-generator tuned tuned-ppd rsync rclone ffmpeg mesa vulkan-radeon xf86-video-ati xf86-video-amdgpu xf86-video-vesa podman distrobox android-tools opus-tools unrar zip unzip firewalld imagemagick yt-dlp btop syncthing

# KDE Plasma e softwares diversos
pacman -S plasma-meta konsole kate dolphin dolphin-plugins ffmpegthumbs kimageformats filelight flatpak flatpak-kcm ark gwenview spectacle okular skanpage partitionmanager kasts kcalc merkuro kdepim-addons plasma-workspace xdg-desktop-portal-gtk firefox firefox-i18n-pt-br fastfetch vlc vlc-plugin-matroska vlc-plugin-x264 vlc-plugin-x265 vlc-plugin-dca vlc-plugin-ffmpeg vlc-plugin-ass vlc-plugin-freetype vlc-plugin-srt virt-manager qemu-desktop dnsmasq edk2-ovmf bash-completion cups kdeconnect sshfs keepassxc libreoffice-fresh-pt-br mkvtoolnix-cli noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ttf-jetbrains-mono qbittorrent

# Niri e softwares diversos
pacman -S niri alacritty fuzzel mako xwayland-satellite waybar swaybg swayidle swaylock xdg-desktop-portal-gnome ranger polkit network-manager-applet
```

## 10. Serviços e Usuário

### 10.1 Habilitar serviços

```bash
systemctl enable sddm
cat <<EOF > /etc/sddm.conf
[Theme]
Current=breeze
EOF

systemctl enable virtqemud.socket virtnetworkd.socket virtstoraged.socket virtproxyd.socket
systemctl enable cups.socket
systemctl enable paccache.timer
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable apparmor
systemctl enable tuned
systemctl enable tuned-ppd
```

### 10.2 ZRAM (6GB com prioridade maior que o swapfile)

O `zram-generator` já foi instalado no passo anterior. Crie o arquivo de configuração:

```bash
cat <<EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = 6144
compression-algorithm = zstd
swap-priority = 100
EOF
```

O zram terá prioridade 100, enquanto o swapfile (criado na seção 3 com `-p 5`) fica com prioridade 5. O kernel usará o zram primeiro. Se precisar armazenar mais que 6GB em swap, o swapfile entra como fallback.

Verifique se a entrada do swapfile no `/etc/fstab` está com a opção `pri=5` — se não estiver (o `genfstab` pode não ter incluído), edite manualmente e adicione:

```text
# /swap/swapfile
/dev/mapper/cryptroot /swap/swapfile btrfs noatime,subvol=@swap 0 0
```

O ideal é adicionar `pri=5` às opções de montagem do swapfile no fstab:

```text
/dev/mapper/cryptroot /swap/swapfile btrfs noatime,subvol=@swap,pri=5 0 0
```

### 10.3 Criar usuário

```bash
useradd -mG wheel kim
passwd kim
usermod -c "Kim" kim

EDITOR=nano visudo # Descomente: %wheel ALL=(ALL) ALL
```

## 11. Finalização

```bash
exit
swapoff /mnt/swap/swapfile
umount -R /mnt
reboot
```

Depois do reboot, o firmware UEFI carrega o systemd-boot, que carrega a UKI diretamente da ESP — **uma única tela pedindo a senha do LUKS**, sem menu de GRUB, sem senha dupla.

## 12. Pós-instalação: Snapper

```bash
sudo pacman -S snapper snap-pac
sudo umount /.snapshots
sudo rm -r /.snapshots
sudo snapper -c root create-config /
sudo btrfs subvolume delete /.snapshots
sudo mkdir /.snapshots
sudo mount -a
sudo vim /etc/snapper/configs/root

# snapper-rollback continua funcionando normalmente,
# independente do bootloader escolhido
mkdir ~/Devel && cd ~/Devel/
git clone https://github.com/jrabinow/snapper-rollback.git
cd snapper-rollback/
sudo cp snapper-rollback.py /usr/local/sbin/snapper-rollback
sudo cp snapper-rollback.conf /etc/
sudo vim /etc/snapper-rollback.conf
# mountpoint = /mnt, dev = /dev/mapper/cryptroot
```

Note que `grub-btrfs` **não entra mais aqui** — veja a seção seguinte sobre boot em snapshots.

---

## Boot em snapshots sem o grub-btrfs

Essa é a principal perda "de fábrica" ao trocar GRUB por systemd-boot puro: **o systemd-boot não tem um equivalente nativo ao `grub-btrfs`.** O motivo é estrutural, não uma limitação arbitrária — o `grub-btrfs` funciona reescrevendo dinamicamente o `grub.cfg`, adicionando uma entrada de menu por snapshot com um `rootflags=subvol=...` diferente apontando pra dentro de `.snapshots/`. Isso é fácil pro GRUB porque ele monta a raiz e lê arquivos de configuração em tempo de boot. Já a UKI é um binário fechado e assinável — o cmdline (incluindo o `subvol=`) fica embutido dentro dela, então não dá pra "adicionar uma entrada por snapshot" sem gerar uma UKI nova para cada snapshot.

Você tem três caminhos práticos daqui:

### Opção A — Continuar só com rollback offline (o que você já tem)
O `snapper-rollback` que você já usa **não depende do bootloader**: ele troca o subvolume padrão e você reinicia para o sistema restaurado. Não dá o "preview" de bootar direto num snapshot antigo pra investigar antes de decidir, mas cobre o caso de uso mais comum (desfazer uma atualização ruim) sem exigir nenhuma peça a mais.

### Opção B — Trocar systemd-boot por Limine + `limine-snapper-sync`
Se bootar direto num snapshot pelo menu é algo que você usa com frequência, a alternativa madura hoje em dia é o **Limine**, não o systemd-boot. O Limine também constrói e carrega UKIs (então você mantém tudo que já montou nas seções 6–7), mas tem uma ferramenta de integração nativa com Snapper:

- **`limine-snapper-sync`** (AUR): monitora o Snapper e escreve automaticamente uma entrada de boot no Limine para cada snapshot novo, com opções de restauração (rsync, replace ou nativa do snapper). É o que CachyOS e outras distros baseadas em Arch usam hoje como substituto direto do `grub-btrfs`.
- Funciona perfeitamente com LUKS2 e com root em Btrfs; a troca de GRUB→Limine, nesse ponto do seu guia, seria basicamente: instalar `limine` + `limine-mkinitcpio-hook` no lugar de `bootctl install`, e depois `limine-snapper-sync` + `inotify-tools` no lugar da seção do systemd-boot.
- Vale o aviso do próprio ArchWiki: como os snapshots do Snapper são somente-leitura por padrão, alguns serviços (ex.: gerenciador de sessão gráfica) podem falhar ao bootar direto num snapshot — é mais um modo de "investigar e depois restaurar" do que um ambiente de uso diário.

### Opção C — rEFInd + `refind-btrfs`
Existe também o `refind-btrfs`, equivalente ao `grub-btrfs` mas para o rEFInd. Ele funciona melhor com kernel+initramfs tradicionais (não UKI monolítica), então empataria menos bem com o setup que acabamos de montar — mencionando aqui só para completude, mas eu recomendaria a Opção B se snapshot boot for prioridade.

**Minha sugestão:** siga com systemd-boot + UKI como está neste guia (mais simples, menos peças móveis, manutenção zero) e mantenha o `snapper-rollback` como sua rede de segurança. Se um dia sentir falta de navegar por snapshots direto no menu de boot, a migração para Limine é incremental — você não precisa refazer a instalação, só trocar a camada de bootloader.