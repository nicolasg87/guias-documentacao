# Guia — Fedora 44 com mangowm-wlonly + Noctalia

## Índice

1. [Instalação do Fedora Everything](#1-instalacao-do-fedora-everything)
2. [Pós-instalação mínima](#2-pos-instalacao-minima)
3. [Empacotando o mangowm-wlonly](#3-empacotando-o-mangowm-wlonly)
4. [Instalando o Noctalia](#4-instalando-o-noctalia)
5. [Display Manager e autologin](#5-display-manager-e-autologin)
6. [Dicas finais](#6-dicas-finais)

---

## 1. Instalação do Fedora Everything

### 1.1 Baixar a ISO

Acesse https://fedoraproject.org/workstation/download/, clique em **Alternate Downloads** e escolha **Fedora Everything**.

### 1.2 Durante a instalação

- **Software Selection** → Base Environment: **Minimal Install**
- Add-Ons: deixe vazio (não marque nada extra)
- Crie seu usuário normalmente

### 1.3 Primeiro boot e instalação de base

```bash
sudo dnf install -y \
  network-manager-applet \
  pipewire-pulseaudio pipewire-alsa wireplumber \
  foot \
  mesa-dri-drivers \
  noto-fonts noto-emoji-fonts \
  polkit-kde seatd

sudo systemctl enable seatd --now
sudo systemctl enable pipewire --user --now
```

---

## 2. Pós-instalação mínima

### 2.1 Dependências do mangowm

```bash
sudo dnf install -y \
  gcc gcc-c++ \
  meson ninja-build \
  wayland-devel wayland-protocols-devel \
  libinput-devel libdrm-devel \
  pixman-devel libxkbcommon-devel \
  pcre2-devel pango-devel \
  cjson-devel libxcb-devel \
  wlroots-devel \
  xorg-x11-server-Xwayland
```

### 2.2 Ferramentas para empacotamento RPM

```bash
sudo dnf install -y rpmdevtools rpm-build copr-cli
rpmdev-setuptree
```

---

## 3. Empacotando o mangowm-wlonly

### 3.1 Criar o spec

Salve em `~/rpmbuild/SPECS/mangowm-wlonly.spec`:

```spec
%global commit 84caa4a8dbdcb5a9a922585f1193c906717fecbc
%global shortcommit %(c=%{commit}; echo ${c:0:7})

Name:          mangowm-wlonly
Version:       0.15.5
Release:       1%{?dist}
Summary:       mangowm without scenefx

License:       GPL-3.0
URL:           https://github.com/mangowm/mango/tree/wl-only
Source0:       %{url}/archive/%{commit}/mango-%{version}-%{shortcommit}.tar.gz

BuildRequires: meson
BuildRequires: ninja-build
BuildRequires: wayland-devel >= 1.23.1
BuildRequires: wayland-protocols-devel >= 1.41
BuildRequires: libinput-devel >= 1.27.1
BuildRequires: libdrm-devel
BuildRequires: pixman-devel
BuildRequires: libxkbcommon-devel
BuildRequires: pcre2-devel
BuildRequires: pango-devel
BuildRequires: cjson-devel
BuildRequires: libxcb-devel
BuildRequires: wlroots-devel >= 0.20
Requires:      xorg-x11-server-Xwayland

Provides:      mangowm
Provides:      wayland-compositor
Conflicts:     mangowm
Conflicts:     mangowm-git

%description
mangowm built from the wl-only branch — no scenefx dependency.

%prep
%autosetup -n mango-%{commit}

%build
%meson
%meson_build

%install
%meson_install

%files
%{_bindir}/mango
%{_bindir}/mmsg
%{_datadir}/wayland-sessions/mango.desktop
%{_datadir}/xdg-desktop-portal/mango-portals.conf
%config(noreplace) %{_sysconfdir}/mango/
%{_mandir}/man1/mmsg.1*

%changelog
* Wed Jul 29 2026 Seu Nome <seu@email.com>
- Initial package
```

### 3.2 Baixar o source e buildar

```bash
cd ~/rpmbuild/SOURCES
wget -O mango-0.15.5-84caa4a.tar.gz \
  "https://github.com/mangowm/mango/archive/84caa4a8dbdcb5a9a922585f1193c906717fecbc/mango-0.15.5-84caa4a.tar.gz"

rpmbuild -ba ~/rpmbuild/SPECS/mangowm-wlonly.spec
```

Os RPMs gerados estarão em `~/rpmbuild/RPMS/x86_64/`.

### 3.3 Instalar localmente

```bash
sudo dnf install ~/rpmbuild/RPMS/x86_64/mangowm-wlonly-*.rpm
```

### 3.4 Subir para o COPR (para atualizações fáceis)

```bash
# Criar o repositório (só uma vez)
copr-cli create mangowm-wlonly \
  --chroot fedora-44-x86_64 \
  --description "mangowm wl-only for Fedora" \
  --instructions "sudo dnf copr enable <seuuser>/mangowm-wlonly && sudo dnf install mangowm-wlonly"

# Enviar o build
copr-cli build mangowm-wlonly ~/rpmbuild/SRPMS/mangowm-wlonly-*.src.rpm
```

Para outros usarem:

```bash
sudo dnf copr enable <seuuser>/mangowm-wlonly
sudo dnf install mangowm-wlonly
```

### 3.5 Atualizar para versões futuras

Quando o mantenedor do AUR atualizar o `stablecommit` para um novo hash:

```bash
# Atualizar %global commit no spec
# Baixar o novo source
cd ~/rpmbuild/SOURCES
rm mango-0.15.5-*.tar.gz
wget -O mango-<versao>-<hash_curto>.tar.gz \
  "https://github.com/mangowm/mango/archive/<hash_completo>/mango-<versao>-<hash_curto>.tar.gz"

# Rebuild e reenvia
rpmbuild -bs ~/rpmbuild/SPECS/mangowm-wlonly.spec
copr-cli build mangowm-wlonly ~/rpmbuild/SRPMS/mangowm-wlonly-*.src.rpm
```

---

## 4. Instalando o Noctalia

O Fedora 44 já tem o Noctalia nos repositórios oficiais:

```bash
sudo dnf install noctalia
```

Pronto. Sem necessidade de empacotar nada.

---

## 5. Display Manager e autologin

### 5.1 Opção A — Sem DM, direto no mangowm

```bash
echo '[[ $(tty) = /dev/tty1 ]] && exec mango' >> ~/.bash_profile
```

### 5.2 Opção B — greetd + tuigreet (leve)

```bash
sudo dnf install greetd greetd-tuigreet
sudo systemctl enable greetd --now
```

Configure `/etc/greetd/config.toml`:

```toml
[terminal]
vt = 1

[default_session]
command = "tuigreet --cmd mango"
user = "greeter"
```

### 5.3 Opção C — GDM (mais pesado, mas completo)

```bash
sudo dnf install gdm
sudo systemctl enable gdm --now
```

---

## 6. Dicas finais

### Utilitários extras comuns

```bash
sudo dnf install brightnessctl grim slurp satty \
  wl-clipboard wlsunset swaybg \
  waybar rofi-wayland pamixer
```

### Configuração do mangowm

Clone uma config base (ou use a padrão em `/etc/mango/config.conf`):

```bash
git clone https://github.com/DreamMaoMao/mango-config.git ~/.config/mango
```

### A sessão aparece no DM

O arquivo `mango.desktop` foi instalado em `/usr/share/wayland-sessions/`. Se você instalou GDM/greetd, o mangowm já aparece como opção de sessão.
