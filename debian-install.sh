#!/usr/bin/env bash
#
# debian-install.sh
# Instalação automatizada de Debian com debootstrap, LUKS2 + BTRFS (subvolumes),
# zram e preparação para snapper. Feito para rodar a partir de um LiveCD Debian
# (ex.: live-plasma) com acesso à internet.
#
# ATENÇÃO: este script PARTICIONA E FORMATA DISCOS. Revise cada função antes
# de rodar em produção. Rode como root.

set -euo pipefail

TARGET="/target"
LOGFILE="/root/debian-install-$(date +%Y%m%d-%H%M%S).log"

# ---------------------------------------------------------------------------
# Setup de log e limpeza em caso de erro/interrupção
# ---------------------------------------------------------------------------

exec > >(tee -a "$LOGFILE") 2>&1

cleanup() {
    echo ">> Limpando montagens (se houver)..."
    umount -R "$TARGET" 2>/dev/null || true
    if [ -e /dev/mapper/cryptroot ]; then
        cryptsetup close cryptroot 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Checagens iniciais
# ---------------------------------------------------------------------------

need_root() {
    [ "$(id -u)" -eq 0 ] || { echo "Rode este script como root."; exit 1; }
}

check_efi() {
    if [ ! -d /sys/firmware/efi ]; then
        echo "Sistema não está em modo UEFI. Este script assume boot UEFI."
        exit 1
    fi
}

check_network() {
    if ! getent hosts deb.debian.org > /dev/null; then
        echo "Sem acesso à internet (necessário para debootstrap)."
        exit 1
    fi
}

install_host_deps() {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        whiptail parted gdisk dosfstools cryptsetup btrfs-progs \
        debootstrap arch-install-scripts ca-certificates
}

# ---------------------------------------------------------------------------
# Coleta de respostas do usuário
# ---------------------------------------------------------------------------

select_disk() {
    local options=()
    while read -r name size; do
        options+=("/dev/$name" "$size")
    done < <(lsblk -dno NAME,SIZE -e7,11)
    whiptail --menu "Selecione o disco de destino (TODOS OS DADOS SERÃO APAGADOS):" \
        20 70 8 "${options[@]}" 3>&1 1>&2 2>&3
}

ask_config() {
    DISK=$(select_disk)

    HOSTNAME=$(whiptail --inputbox "Hostname da máquina:" 10 60 "debian-btw" 3>&1 1>&2 2>&3)
    USERNAME=$(whiptail --inputbox "Usuário principal (não-root):" 10 60 "kim" 3>&1 1>&2 2>&3)
    RELEASE=$(whiptail --inputbox "Release do Debian (debootstrap):" 10 60 "trixie" 3>&1 1>&2 2>&3)
    MIRROR=$(whiptail --inputbox "Mirror Debian:" 10 60 "https://deb.debian.org/debian" 3>&1 1>&2 2>&3)
    TIMEZONE=$(whiptail --inputbox "Timezone:" 10 60 "America/Maceio" 3>&1 1>&2 2>&3)
    ESP_SIZE=$(whiptail --inputbox "Tamanho da partição EFI:" 10 60 "1GiB" 3>&1 1>&2 2>&3)
    SWAPFILE_SIZE=$(whiptail --inputbox "Tamanho do swapfile (fallback do zram):" 10 60 "12g" 3>&1 1>&2 2>&3)

    CPU_VENDOR=$(whiptail --menu "Fabricante da CPU (para microcode):" 15 60 3 \
        intel "Intel" \
        amd   "AMD" \
        none  "Nenhum / VM" \
        3>&1 1>&2 2>&3)

    # Detecta locale e layout de teclado já em uso no ambiente live, para
    # sugerir como padrão (o usuário provavelmente já escolheu isso no boot).
    local default_locale default_kblayout default_kbvariant
    default_locale=$(grep -oP '(?<=^LANG=).*' /etc/default/locale 2>/dev/null || echo "en_US.UTF-8")
    default_kblayout=$(awk -F'"' '/^XKBLAYOUT=/{print $2}' /etc/default/keyboard 2>/dev/null || true)
    default_kbvariant=$(awk -F'"' '/^XKBVARIANT=/{print $2}' /etc/default/keyboard 2>/dev/null || true)
    default_kblayout=${default_kblayout:-us}

    LOCALE=$(whiptail --inputbox "Locale do sistema:" 10 60 "$default_locale" 3>&1 1>&2 2>&3)
    KEYBOARD_LAYOUT=$(whiptail --inputbox "Layout de teclado (ex: br, us, us-intl):" 10 60 "$default_kblayout" 3>&1 1>&2 2>&3)
    KEYBOARD_VARIANT=$(whiptail --inputbox "Variante de teclado (deixe em branco se não usar, ex: abnt2, intl):" 10 60 "$default_kbvariant" 3>&1 1>&2 2>&3)

    # Blacklist de atkbd/i8042 -- só necessário em máquinas com teclado PS/2
    # com esse defeito específico, não é algo genérico.
    if whiptail --yesno "Sua máquina tem o problema conhecido de teclado PS/2 que exige desativar atkbd/i8042 via kernel (modprobe.blacklist=atkbd i8042.nokbd)?\n\nSe você não sabe do que se trata, escolha Não." 13 70; then
        ATKBD_BLACKLIST="yes"
    else
        ATKBD_BLACKLIST="no"
    fi

    LUKS_PASS=$(whiptail --passwordbox "Senha de criptografia do disco (LUKS):" 10 60 3>&1 1>&2 2>&3)
    LUKS_PASS2=$(whiptail --passwordbox "Confirme a senha do LUKS:" 10 60 3>&1 1>&2 2>&3)
    [ "$LUKS_PASS" = "$LUKS_PASS2" ] || { echo "Senhas do LUKS não conferem."; exit 1; }

    USER_PASS=$(whiptail --passwordbox "Senha do usuário $USERNAME:" 10 60 3>&1 1>&2 2>&3)
    USER_PASS2=$(whiptail --passwordbox "Confirme a senha do usuário:" 10 60 3>&1 1>&2 2>&3)
    [ "$USER_PASS" = "$USER_PASS2" ] || { echo "Senhas do usuário não conferem."; exit 1; }

    whiptail --yesno "ATENÇÃO: TODOS OS DADOS EM $DISK SERÃO PERDIDOS.\n\nContinuar?" 12 60 \
        || { echo "Cancelado pelo usuário."; exit 1; }
}

# ---------------------------------------------------------------------------
# Particionamento
# ---------------------------------------------------------------------------

prepare_mountpoint() {
    mkdir -p "$TARGET"
}

partition_disk() {
    echo ">> Particionando $DISK..."
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB "$ESP_SIZE"
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary "$ESP_SIZE" 100%
    udevadm settle
    sleep 2

    if [[ "$DISK" =~ nvme|mmcblk ]]; then
        ESP_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        ESP_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi
}

format_esp() {
    mkfs.vfat -F32 -n ESP "$ESP_PART"
}

# ---------------------------------------------------------------------------
# LUKS + BTRFS
# ---------------------------------------------------------------------------

setup_luks() {
    echo ">> Criando volume LUKS2 em $ROOT_PART..."
    echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
        --batch-mode "$ROOT_PART" -
    echo -n "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot --key-file -

    # UUID da partição LUKS (física) -- usado no crypttab e no GRUB_CMDLINE_LINUX
    LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
}

setup_btrfs() {
    echo ">> Criando filesystem BTRFS e subvolumes..."
    mkfs.btrfs -f -L cryptroot /dev/mapper/cryptroot

    # UUID do filesystem BTRFS (usado no fstab) -- DIFERENTE do LUKS_UUID acima
    BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)

    mkdir -p "$TARGET"
    mount /dev/mapper/cryptroot "$TARGET"
    for sv in @ @home @images @containers @cache @var_log @swap @tmp @snapshots; do
        btrfs subvolume create "$TARGET/$sv"
    done
    umount "$TARGET"
}

mount_subvolumes() {
    echo ">> Montando subvolumes em $TARGET..."
    mount -o noatime,compress=zstd:3,subvol=@ /dev/mapper/cryptroot "$TARGET"
    mkdir -p "$TARGET"/{boot/efi,home,.snapshots,var/log,var/lib/containers,var/lib/libvirt/images,var/cache,var/tmp,swap}

    mount -o noatime,compress=zstd:3,subvol=@home       /dev/mapper/cryptroot "$TARGET/home"
    mount -o noatime,subvol=@images                     /dev/mapper/cryptroot "$TARGET/var/lib/libvirt/images"
    mount -o noatime,subvol=@containers                 /dev/mapper/cryptroot "$TARGET/var/lib/containers"
    mount -o noatime,compress=zstd:3,subvol=@cache       /dev/mapper/cryptroot "$TARGET/var/cache"
    mount -o noatime,compress=zstd:3,subvol=@var_log     /dev/mapper/cryptroot "$TARGET/var/log"
    # nodatacow em vez de chattr +C posterior (chattr só funciona em dir/arquivo vazio)
    mount -o noatime,nodatacow,subvol=@swap              /dev/mapper/cryptroot "$TARGET/swap"
    mount -o noatime,compress=zstd:3,subvol=@tmp         /dev/mapper/cryptroot "$TARGET/var/tmp"
    mount -o noatime,compress=zstd:3,subvol=@snapshots   /dev/mapper/cryptroot "$TARGET/.snapshots"

    mount "$ESP_PART" "$TARGET/boot/efi"
}

# ---------------------------------------------------------------------------
# debootstrap
# ---------------------------------------------------------------------------

run_debootstrap() {
    echo ">> Rodando debootstrap ($RELEASE)..."
    debootstrap "$RELEASE" "$TARGET" "$MIRROR"
    cp /etc/resolv.conf "$TARGET/etc/resolv.conf" || true
    [ -f /etc/network/interfaces ] && cp /etc/network/interfaces "$TARGET/etc/network/interfaces" || true
}

write_fstab() {
    echo ">> Gerando /etc/fstab..."
    local esp_uuid
    esp_uuid=$(blkid -s UUID -o value "$ESP_PART")

    cat > "$TARGET/etc/fstab" <<EOF
# <fs>                     <mountpoint>              <type>  <options>                                  <dump> <pass>
UUID=$BTRFS_UUID  /                          btrfs   noatime,compress=zstd:3,subvol=@             0 0
UUID=$BTRFS_UUID  /home                      btrfs   noatime,compress=zstd:3,subvol=@home         0 0
UUID=$BTRFS_UUID  /var/lib/libvirt/images    btrfs   noatime,subvol=@images                        0 0
UUID=$BTRFS_UUID  /var/lib/containers        btrfs   noatime,subvol=@containers                    0 0
UUID=$BTRFS_UUID  /var/cache                 btrfs   noatime,compress=zstd:3,subvol=@cache         0 0
UUID=$BTRFS_UUID  /var/log                   btrfs   noatime,compress=zstd:3,subvol=@var_log       0 0
UUID=$BTRFS_UUID  /swap                      btrfs   noatime,nodatacow,subvol=@swap                0 0
UUID=$BTRFS_UUID  /var/tmp                   btrfs   noatime,compress=zstd:3,subvol=@tmp           0 0
UUID=$BTRFS_UUID  /.snapshots                btrfs   noatime,compress=zstd:3,subvol=@snapshots     0 0
UUID=$esp_uuid     /boot/efi                  vfat    umask=0077                                    0 1
/swap/swapfile     none                       swap    defaults,pri=10                               0 0
EOF
}

# ---------------------------------------------------------------------------
# Script que roda DENTRO do chroot
# ---------------------------------------------------------------------------

generate_chroot_script() {
    local microcode_pkg=""
    case "$CPU_VENDOR" in
        intel) microcode_pkg="intel-microcode" ;;
        amd)   microcode_pkg="amd64-microcode" ;;
        *)     microcode_pkg="" ;;
    esac

    local extra_cmdline=""
    if [ "$ATKBD_BLACKLIST" = "yes" ]; then
        extra_cmdline=" modprobe.blacklist=atkbd i8042.nokbd"
    fi

    cat > "$TARGET/root/chroot-setup.sh" <<CHROOTEOF
#!/usr/bin/env bash
set -euo pipefail

echo "$HOSTNAME" > /etc/hostname
cat >> /etc/hosts <<HOSTS
127.0.1.1   $HOSTNAME
HOSTS

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates lsb-release locales \
    keyboard-configuration console-setup

# --- Locale (sem debconf/dpkg-reconfigure) ---
sed -i "s/^# *${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
grep -qx "${LOCALE} UTF-8" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/default/locale

# --- Teclado (sem debconf/dpkg-reconfigure) ---
# /etc/default/keyboard é a fonte de verdade lida pelo console-setup no boot;
# não precisa rodar dpkg-reconfigure interativo.
cat > /etc/default/keyboard <<KEYBOARD
XKBMODEL="pc105"
XKBLAYOUT="${KEYBOARD_LAYOUT}"
XKBVARIANT="${KEYBOARD_VARIANT}"
XKBOPTIONS=""
BACKSPACE="guess"
KEYBOARD

cat > /etc/apt/sources.list <<SOURCES
deb $MIRROR $RELEASE main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $RELEASE-security main contrib non-free non-free-firmware
deb $MIRROR $RELEASE-updates main contrib non-free non-free-firmware
deb $MIRROR $RELEASE-backports main contrib non-free non-free-firmware
SOURCES

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \\
    bash-completion btrfs-progs linux-image-amd64 firmware-linux \\
    firmware-linux-nonfree $microcode_pkg firmware-amd-graphics \\
    libinput-bin alsa-ucm-conf grub-efi-amd64 efibootmgr gawk sudo \\
    cryptsetup cryptsetup-initramfs network-manager acpid avahi-daemon \\
    thermald bluetooth bluez brightnessctl zram-tools

# NOTA: firmware-atheros e firmware-sof são específicos de hardware
# (wifi Atheros / audio Intel SOF) -- ajuste conforme o seu equipamento.

systemctl enable NetworkManager
systemctl enable bluetooth

# --- Chave de desbloqueio automático via GRUB (evita digitar a senha 2x) ---
mkdir -m0700 /etc/keys
( umask 0077 && dd if=/dev/urandom bs=1 count=64 of=/etc/keys/root.key conv=excl,fsync )
echo -n "$LUKS_PASS" | cryptsetup luksAddKey "$ROOT_PART" /etc/keys/root.key --key-file -

cat > /etc/crypttab <<CRYPTTAB
cryptroot UUID=$LUKS_UUID /etc/keys/root.key luks,discard
CRYPTTAB

sed -i 's|^#KEYFILE_PATTERN=.*|KEYFILE_PATTERN="/etc/keys/*.key"|' /etc/cryptsetup-initramfs/conf-hook
echo 'CRYPTSETUP=y' >> /etc/cryptsetup-initramfs/conf-hook
echo 'UMASK=0077' >> /etc/initramfs-tools/initramfs.conf

# --- GRUB ---
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"|' /etc/default/grub
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$LUKS_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ zswap.enabled=0${extra_cmdline}\"|" /etc/default/grub
echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian \\
    --recheck --modules="part_gpt cryptodisk luks2 gcry_rijndael pbkdf2 gcry_sha256"
update-initramfs -u
update-grub

# --- Usuário ---
useradd -m -G sudo,video,audio,input,render,netdev -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
passwd -l root   # root fica sem senha de login direto; acesso via sudo do usuário

# --- Swapfile de fallback (zram cobre a maior parte, isso é backstop) ---
btrfs filesystem mkswapfile --size $SWAPFILE_SIZE --uuid clear /swap/swapfile
swapon /swap/swapfile

cat > /etc/default/zramswap <<ZRAM
ALGO=zstd
PERCENT=50
ZRAM
CHROOTEOF

    chmod +x "$TARGET/root/chroot-setup.sh"
}

run_chroot() {
    echo ">> Executando setup dentro do chroot..."
    arch-chroot "$TARGET" /root/chroot-setup.sh
    rm -f "$TARGET/root/chroot-setup.sh"
}

# ---------------------------------------------------------------------------
# Finalização
# ---------------------------------------------------------------------------

finish() {
    echo ">> Desmontando e fechando LUKS..."
    umount -R "$TARGET"
    cryptsetup close cryptroot
    trap - EXIT
    echo
    echo "=================================================================="
    echo " Instalação concluída."
    echo " Log completo em: $LOGFILE"
    echo
    echo " Após reboot, com o sistema já rodando, configure o snapper"
    echo " manualmente (isso não dá pra fazer com segurança dentro do chroot"
    echo " antes do primeiro boot)."
    echo "=================================================================="
}

main() {
    need_root
    check_efi
    check_network
    install_host_deps
    ask_config
    prepare_mountpoint
    partition_disk
    format_esp
    setup_luks
    setup_btrfs
    mount_subvolumes
    run_debootstrap
    write_fstab
    generate_chroot_script
    run_chroot
    finish
}

main "$@"
