# Guia: Empacotando mangowm-wlonly como RPM

## Índice

1. [Introdução](#1-introdução)
2. [Build local com Distrobox](#2-build-local-com-distrobox)
   - [2.1 Por que Distrobox?](#21-por-que-distrobox)
   - [2.9 Build baseado em commit específico (release)](#29-build-baseado-em-commit-específico-release)
   - [2.10 Atualizar o pacote (rolling git)](#210-atualizar-o-pacote-rolling-git)
3. [Manutenção via OBS](#3-manutenção-via-obs)
   - [3.10 OBS com commit fixo (release)](#310-obs-com-commit-fixo-release)
   - [3.11 Atualizar o pacote (rolling)](#311-atualizar-o-pacote-rolling)
4. [Arquivos de referência](#4-arquivos-de-referência)

---

## 1. Introdução

**mangowm-wlonly** é a variante sem scenefx do [Mango WM](https://github.com/mangowm/mango),
na branch `wl-only`. Depende apenas de `wlroots >= 0.20` (sem scenefx).

Este guia cobre duas formas de empacotar:

- **Local com Distrobox**: ideal para testar antes de publicar
- **OBS (Open Build Service)**: para manter um repositório público que qualquer
  usuário openSUSE pode consumir via `zypper`

---

## 2. Build local com Distrobox

### 2.1 Por que Distrobox?

Compilar um RPM fora do sistema hospedeiro é recomendado para:

- Não poluir o sistema com dependências de build
- Reproduzir o ambiente limpo do OBS
- Funcionar em qualquer distro (Fedora, Arch, etc.)

### 2.2 Criar o container

```bash
distrobox create -i registry.opensuse.org/opensuse/tumbleweed:latest -n opensuse-build
distrobox enter opensuse-build
```

### 2.3 Instalar dependências de build

```bash
sudo zypper install \
  rpm-build \
  meson ninja \
  wayland-devel wayland-protocols-devel \
  libinput-devel libdrm-devel \
  libxkbcommon-devel libpixman-1-0-devel \
  libdisplay-info-devel libliftoff-devel \
  hwdata seatd-devel pcre2-devel \
  cJSON-devel pango-devel \
  libxcb-devel xcb-util-wm-devel \
  wlroots-devel \
  xwayland
```

### 2.4 Estrutura de diretórios

```bash
mkdir -p ~/rpmbuild/{SPECS,SOURCES,RPMS/x86_64,SRPMS,BUILD}
```

### 2.5 Baixar o fonte

```bash
cd ~/rpmbuild/SOURCES
git clone https://github.com/mangowm/mango.git mango
cd mango
git checkout wl-only
cd ..
tar czf mangowm-wlonly-git-0.15.5.tar.gz mango
rm -rf mango
```

### 2.6 Criar o spec

Salve como `~/rpmbuild/SPECS/mangowm-wlonly.spec`:

```spec
#
# spec file for package mangowm-wlonly-git
#
Name:           mangowm-wlonly-git
Version:        0.15.5
Release:        0
Summary:        mangowm without scenefx (wl-only branch, git)
License:        GPL-3.0-or-later
Group:          System/GUI/Other
URL:            https://github.com/mangowm/mango/tree/wl-only
Source:         %{name}-%{version}.tar.gz

BuildRequires:  meson >= 0.60.0
BuildRequires:  ninja
BuildRequires:  pkgconfig
BuildRequires:  pkgconfig(wayland-server) >= 1.23.1
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-protocols) >= 1.32
BuildRequires:  pkgconfig(libinput) >= 1.27.1
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(pixman-1)
BuildRequires:  pkgconfig(libdisplay-info)
BuildRequires:  pkgconfig(libliftoff)
BuildRequires:  pkgconfig(hwdata)
BuildRequires:  pkgconfig(libseat)
BuildRequires:  pkgconfig(libpcre2-8)
BuildRequires:  pkgconfig(libcjson)
BuildRequires:  pkgconfig(pangocairo)
BuildRequires:  pkgconfig(wlroots-0.20)
BuildRequires:  pkgconfig(xcb)
BuildRequires:  pkgconfig(xcb-icccm)
BuildRequires:  xwayland

Requires:       xwayland
Conflicts:      mangowm
Conflicts:      mangowm-wlonly
Provides:       mangowm

Suggests:       foot
Suggests:       rofi
Suggests:       waybar
Suggests:       swaybg
Suggests:       swaync
Suggests:       wl-clipboard
Suggests:       wl-clip-persist
Suggests:       cliphist
Suggests:       wlsunset
Suggests:       xdg-desktop-portal-wlr
Suggests:       xdg-desktop-portal-gtk
Suggests:       grim
Suggests:       slurp
Suggests:       xfce-polkit
Suggests:       wlogout

%description
Mango is a modern, lightweight, high-performance tiling Wayland compositor
built on dwl and wlroots. This is the wl-only variant — no scenefx effects.
Rolling git build from the wl-only branch.

%prep
%autosetup -n mango

%build
%meson
%meson_build

%install
%meson_install

%files
%license LICENSE
%doc README.md
%{_bindir}/mango
%{_bindir}/mmsg
%{_datadir}/wayland-sessions/mango.desktop
%{_datadir}/xdg-desktop-portal/mango-portals.conf
%dir %{_sysconfdir}/mango
%config(noreplace) %{_sysconfdir}/mango/config.conf
%{_mandir}/man1/mmsg.1*

%changelog
* Wed Jul 29 2026 kim <kim@example.com>
- Initial package: mangowm-wlonly-git
```

Se o `Name` do spec tiver `-git`, o nome do tarball precisa incluir `-git`
também. Se preferir sem o `-git`, ajuste o nome do tarball e o spec.

> **Nota sobre a versão:** no build **local**, o `Version: 0.15.5` precisa
> bater com o nome do tarball (`Source0`). No **OBS**, o `%{version}` é
> sobrescrito pelo `versionformat` do `_service` — por isso no OBS usa-se
> `Version: 0` como placeholder. Veja seção 3.6.

### 2.7 Build

```bash
cd ~/rpmbuild
rpmbuild -ba SPECS/mangowm-wlonly.spec
```

### 2.8 Verificar e instalar o RPM

```bash
ls RPMS/x86_64/
sudo zypper install RPMS/x86_64/mangowm-wlonly-git-*.x86_64.rpm
```

### 2.9 Build baseado em commit específico (release)

A tag `0.15.5` aponta para a branch `main` (com scenefx), e a branch
`wl-only` não tem tags próprias. Para fixar uma versão específica, use
o hash do commit desejado na branch `wl-only`.

Commit atual de referência:
[`84caa4a8`](https://github.com/mangowm/mango/commit/84caa4a8dbdcb5a9a922585f1193c906717fecbc)

```bash
cd ~/rpmbuild/SOURCES
git clone https://github.com/mangowm/mango.git mango
cd mango
git checkout 84caa4a8dbdcb5a9a922585f1193c906717fecbc
cd ..
tar czf mangowm-wlonly-0.15.5.tar.gz mango
rm -rf mango
```

No spec, ajuste o `Name` (sem `-git`), a `Version` (pode usar a data
ou o próprio `0.15.5`), e o `Source0`:

```spec
Name:           mangowm-wlonly
Version:        0.15.5
Release:        0
Source:         %{name}-0.15.5.tar.gz
```

O resto do spec (dependências, %build, %install, %files) permanece
idêntico. O build roda igual:

```bash
rpmbuild -ba SPECS/mangowm-wlonly.spec
```

### 2.10 Atualizar o pacote (rolling git)

Quando quiser atualizar para a versão mais nova da branch `wl-only`:

```bash
cd ~/rpmbuild
rm -rf SOURCES/mango  # limpa o clone antigo
# repete os passos 2.5 (git clone + checkout + tarball) e 2.7 (rpmbuild)
```

---

## 3. Manutenção via OBS

### 3.1 Vantagens do OBS

- O build roda nos servidores da openSUSE (não na sua máquina)
- Gera RPMs para Tumbleweed, Slowroll, Leap, etc.
- Qualquer um pode instalar via `zypper addrepo + zypper install`
- Você não precisa refazer tarball manualmente (o `_service` clona do git)

### 3.2 Criar conta

1. Acesse https://build.opensuse.org
2. Registre-se (confirme o e-mail)
3. Faça login

### 3.3 Instalar o cliente osc

No seu sistema (não no container):

```bash
sudo zypper install osc
```

### 3.4 Configurar o osc

```bash
osc init
# digite seu usuário e senha do OBS
```

### 3.5 Criar o projeto

```bash
osc checkout home:SEU_USUARIO
cd home:SEU_USUARIO
mkdir mangowm-wlonly-git && cd mangowm-wlonly-git
```

### 3.6 Criar os arquivos

**Arquivo 1: `_service`**

```xml
<services>
  <service name="obs_scm" mode="manual">
    <param name="url">https://github.com/mangowm/mango.git</param>
    <param name="scm">git</param>
    <param name="revision">wl-only</param>
    <param name="versionformat">@PARENT_TAG@.%ct.%h</param>
  </service>
  <service name="set_version" mode="manual"/>
  <service name="tar" mode="buildtime"/>
  <service name="recompress" mode="buildtime">
    <param name="file">*.tar</param>
    <param name="compression">gz</param>
  </service>
</services>
```

**Arquivo 2: O mesmo `.spec` da seção 2.6**, mas com `Version: 0`:

No OBS, o `_service` gera a versão real baseada no git (ex: `0.15.5.1723456789.abc1234`),
então `Version: 0` é só um placeholder — o `set_version` sobrescreve.

No `%prep`, o diretório extraído pelo OBS terá o nome baseado no
repositório git (`mango`). O `%autosetup` com `-n mango` resolve.

**Sobre os `Suggests`:** essas linhas não são dependências obrigatórias.
O `zypper` apenas sugere os pacotes ao usuário no momento da instalação.
A lista foi baseada nas ferramentas recomendadas no site oficial do mango:
https://mangowm.github.io/docs/quick-start#recommended-tools

**Arquivo 3: `mangowm-wlonly-git.changes`**

```
-------------------------------------------------------------------
Wed Jul 29 2026 SEU_NOME <seu@email>
- Initial package: mangowm-wlonly-git
```

### 3.7 Enviar e buildar

```bash
osc add _service mangowm-wlonly-git.spec mangowm-wlonly-git.changes
osc commit -m "Initial package: mangowm-wlonly-git"
```

O OBS detecta os arquivos, clona o git, e dispara o build automaticamente.

### 3.8 Acompanhar o build

```bash
osc results          # mostra status (succeeded / failed / building)
osc buildlog         # log ao vivo
```

### 3.9 Repositório público

Após o build bem-sucedido, o RPM fica disponível em:

```
https://download.opensuse.org/repositories/home:/SEU_USUARIO:/mangowm-wlonly/openSUSE_Tumbleweed/
```

Qualquer usuário pode instalar com:

```bash
sudo zypper addrepo \
  https://download.opensuse.org/repositories/home:SEU_USUARIO:mangowm-wlonly/openSUSE_Tumbleweed/home:SEU_USUARIO:mangowm-wlonly.repo
sudo zypper refresh
sudo zypper install mangowm-wlonly-git
```

### 3.10 OBS com commit fixo (release)

Se preferir um pacote estável em vez de rolling, o `_service` pode
apontar para um commit específico em vez da branch. Isso garante que
o RPM só mude quando você explicitamente atualizar o hash.

**`_service` para commit fixo:**

```xml
<services>
  <service name="obs_scm" mode="manual">
    <param name="url">https://github.com/mangowm/mango.git</param>
    <param name="scm">git</param>
    <param name="revision">84caa4a8dbdcb5a9a922585f1193c906717fecbc</param>
    <param name="versionformat">0.15.5</param>
  </service>
  <service name="set_version" mode="manual"/>
  <service name="tar" mode="buildtime"/>
  <service name="recompress" mode="buildtime">
    <param name="file">*.tar</param>
    <param name="compression">gz</param>
  </service>
</services>
```

Mude também o `Name` no spec para `mangowm-wlonly` (sem `-git`) e
remova o `Conflicts: mangowm-wlonly` (já que não é mais rolling).

Para atualizar para um commit mais novo, troque o hash no `revision`
e o `versionformat`:

```bash
osc service remoterun
```

### 3.11 Atualizar o pacote (rolling)

O OBS **não faz rebuild automático** quando o git recebe novos commits
(por causa do `mode="manual"` no `_service`). Para atualizar:

```bash
osc service remoterun
```

Isso refaz o clone do git e dispara um novo build com a versão mais recente.

Se quiser rebuild automático a cada commit, troque `mode="manual"` para
`mode="disabled"` e adicione um webhook no GitHub apontando para:

```
https://build.opensuse.org/trigger/webhook?project=home:SEU_USUARIO:mangowm-wlonly&package=mangowm-wlonly-git
```

### 3.12 Enviar para o Factory (Tumbleweed oficial)

Depois que o pacote estiver estável, você pode submetê-lo ao openSUSE Factory:

```bash
osc sr openSUSE:Factory mangowm-wlonly-git
```

Isso submete o pacote para revisão. O openQA testa automaticamente.

---

## 4. Arquivos de referência

### 4.1 Spec final (para copiar e colar)

Veja seção [2.6](#26-criar-o-spec) acima.

### 4.2 Service final (para OBS)

Veja seção [3.6](#36-criar-os-arquivos).

### 4.3 Links úteis

| Recurso | URL |
|---------|-----|
| Repositório do mangowm | https://github.com/mangowm/mango |
| Branch wl-only | https://github.com/mangowm/mango/tree/wl-only |
| Commit fixo de referência (wl-only) | https://github.com/mangowm/mango/commit/84caa4a8dbdcb5a9a922585f1193c906717fecbc |
| OBS (openSUSE Build Service) | https://build.opensuse.org |
| Documentação OBS | https://openbuildservice.org/help/ |
| openSUSE Wiki — Empacotamento | https://en.opensuse.org/openSUSE:Build_Service_Tutorial |

### 4.4 Dicas de segurança

- Sempre leia o `%post` do spec (scripts executados na instalação)
- Verifique se o `Source0` ou `_service` aponta para o repositório oficial
- Prefira `%meson_install` a scripts manuais com `cp`/`install`
- No OBS, audite o build log para confirmar que só compila o fonte esperado
