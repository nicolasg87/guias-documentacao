# niri + Noctalia v5 no Debian trixie — guia de referência pessoal

Contexto: Debian 13 (trixie) como base "instalar e esquecer", com niri e Noctalia v5
mantidos como pacotes `.deb` próprios (não os oficiais), rastreados pelo dpkg,
para poder atualizar e fazer rollback sem gambiarra.

---

## 0. Princípios gerais

- **Base do sistema**: `apt` normal, sem tocar. Nunca `sudo make install` /
  `sudo meson install` direto — tudo vira `.deb` antes de instalar.
- **Backports**: usar só para pacotes "folha" (kernel, Mesa, firmware,
  `wayland-protocols`) — nada que outros pacotes do sistema dependam
  estruturalmente (glibc, systemd, dbus, ambiente de desktop inteiro).
  Preferir `apt install pacote/trixie-backports` (pacote a pacote) em vez de
  `-t trixie-backports` global.
- **Cadência de atualização**: sob demanda (bug que incomoda ou feature que
  vale a pena), não por calendário fixo. niri: a cada poucos meses. Noctalia
  v5 (ainda beta): mensal só de olho no changelog, atualizar quando fizer
  sentido.
- **Versionamento próprio**: sufixo tipo `~localbuild1` nos pacotes, pra nunca
  colidir com repositórios oficiais.
- Antes de trocar de versão em produção: testar numa sessão/usuário separado
  antes de sobrescrever o dia a dia.
- **Instalação local**: sempre `sudo apt install ./arquivo.deb` (ou caminho
  completo), nunca `dpkg -i` sozinho. O `apt` resolve `Depends:` faltantes
  automaticamente nos repositórios; o `dpkg -i` puro erra e exige um
  `apt-get install -f` manual depois. O `./` (ou caminho absoluto) é
  obrigatório — sem ele o `apt` interpreta como nome de pacote de
  repositório, não como arquivo local.

---

## 1. Ambiente de build isolado (distrobox + podman)

Opcional, mas recomendado: compilar dentro de um container mantém o `/home`
limpo e evita resíduo de build-deps no host. O `.deb` final sai de dentro do
container e é instalado normalmente no host via `apt`/`dpkg`.

```bash
sudo apt install podman distrobox
sudo reboot   # aplica permissão de grupo, se necessário

mkdir -p ~/Devel && cd ~/Devel
distrobox create -i debian:trixie -n trixie-dev --home ~/Distrobox/trixie-dev/
distrobox enter trixie-dev
```

Todo o resto da seção 2 (niri) e da seção 4 (Noctalia) roda dentro desse
container. Só a instalação final do `.deb` gerado acontece no host, fora
dele (`exit` primeiro).

---

## 2. niri (compilado com `cargo-deb`)

### 2.1. Dependências (repositório normal da trixie)
```bash
sudo apt install build-essential gcc clang pkg-config git \
  libudev-dev libgbm-dev libxkbcommon-dev libegl1-mesa-dev \
  libwayland-dev libinput-dev libdbus-1-dev libsystemd-dev \
  libseat-dev libpipewire-0.3-dev libpango1.0-dev \
  libdisplay-info-dev libxcb-cursor-dev
```

### 2.2. Toolchain Rust
Não usar o `rustc` do apt (conservador demais). Instalar via `rustup` e
fixar o canal estável:
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup default stable
cargo install cargo-deb   # uma vez só
```

### 2.3. Baixar o código-fonte
```bash
VERSION="v26.04"   # conferir a tag mais recente antes de fixar
wget "https://github.com/niri-wm/niri/archive/refs/tags/${VERSION}.tar.gz" \
  -O niri_${VERSION#v}.orig.tar.gz
tar -xvf niri_${VERSION#v}.orig.tar.gz && cd niri-${VERSION#v}/
```

### 2.4. Configurar o `Cargo.toml` para o `cargo-deb`
Por padrão o `cargo deb` sobe só o binário. Pra ter uma sessão utilizável
(entrada no display manager, integração com xdg-desktop-portal, unidades
systemd), é preciso declarar os *assets* explicitamente no final do
`Cargo.toml`:

```toml
[package.metadata.deb]
depends = "$auto"
assets = [
    ["target/release/niri", "usr/bin/", "755"],
    ["resources/niri-session", "usr/bin/", "755"],
    ["resources/niri.desktop", "/usr/share/wayland-sessions/", "644"],
    ["resources/niri-portals.conf", "/usr/share/xdg-desktop-portal/", "644"],
    ["resources/niri.service", "/usr/lib/systemd/user/", "644"],
    ["resources/niri-shutdown.target", "/usr/lib/systemd/user/", "644"],
]
```
`depends = "$auto"` faz o `cargo-deb` detectar as shared libs via `ldd`
automaticamente (o equivalente ao `dh_shlibdeps` do mundo Debian nativo).

> **Repetitividade:** editar o `Cargo.toml` na mão a cada versão nova é
> frágil — fácil esquecer ao atualizar. Vale guardar esse trecho como um
> patch reaplicável em vez de editar toda vez do zero:
> ```bash
> git diff Cargo.toml > ~/Devel/patches/niri-cargo-deb.patch
> # nas próximas versões:
> git apply ~/Devel/patches/niri-cargo-deb.patch
> ```

### 2.5. Compilar e empacotar
```bash
cargo deb -- --locked
```

### 2.6. Protocolos Wayland novos
Se a versão do niri exigir um protocolo staging mais novo (ex.: blur via
`ext-background-effect-v1`, presente a partir da 26.04), o mesmo problema
da seção 3.5 vai aparecer **aqui dentro do container** também — o
`trixie-dev` começa com o `wayland-protocols` 1.44 da trixie normal. Repetir
o backport dentro do distrobox antes de compilar:
```bash
sudo apt install -t trixie-backports wayland-protocols
```

### 2.7. Onde fica o `.deb`
O `cargo deb` deixa o pacote dentro da própria árvore do projeto, em
`target/debian/` — diferente do fluxo do `dpkg-buildpackage` (seção 4), que
gera o `.deb` um nível acima. Confirme o caminho exato com:
```bash
ls target/debian/*.deb
```

**Ainda não saia do distrobox.** O xwayland-satellite (seção 3) é
compilado no mesmo container, e os dois `.deb`s são instalados juntos no
host ao final da seção 3.

---

## 3. xwayland-satellite

O niri usa esse utilitário separado para rodar aplicações X11/Xwayland.
Mesmo fluxo do niri, com duas diferenças importantes.

```bash
cd ~/Devel   # ainda dentro do distrobox trixie-dev, mesma sessão da seção 2
VERSION="v0.8"   # conferir a tag mais recente antes de fixar
wget "https://github.com/Supreeeme/xwayland-satellite/archive/refs/tags/${VERSION}.tar.gz" \
  -O xwayland-satellite_${VERSION#v}.orig.tar.gz
tar -xvf xwayland-satellite_${VERSION#v}.orig.tar.gz && cd xwayland-satellite-${VERSION#v}/
```

No `Cargo.toml`, além dos assets, adicionar `xwayland` explicitamente à lista
de dependências — diferente das shared libs, o binário do Xwayland não
aparece no `ldd`, então o `$auto` sozinho não o captura:
```toml
[package.metadata.deb]
depends = "$auto, xwayland"
assets = [
    ["target/release/xwayland-satellite", "usr/bin/", "755"],
    ["resources/xwayland-satellite.service", "/usr/lib/systemd/user/", "644"],
]
```

Compilar habilitando a feature `systemd` (necessária pra unidade de usuário
funcionar corretamente no Debian):
```bash
cargo deb -- -F systemd --locked
```

Atualiza raramente; só mexer se o niri exigir versão mínima nova dele.

### 3.1. Onde ficam os `.deb`s e quando sair do container
```bash
ls ~/Devel/niri-*/target/debian/*.deb
ls ~/Devel/xwayland-satellite-*/target/debian/*.deb
```

**➡️ Este é o momento de sair do distrobox.** niri e xwayland-satellite já
estão compilados; instalar os dois juntos no host:
```bash
exit   # sai do distrobox, volta pro shell normal do host
sudo apt install \
  ~/Devel/niri-*/target/debian/niri_*_amd64.deb \
  ~/Devel/xwayland-satellite-*/target/debian/xwayland-satellite_*_amd64.deb
```

---

## 3.5. wayland-protocols (via trixie-backports) — no host

Necessário porque protocolos novos (ex.: `ext-background-effect-v1`, usado
para blur) só entram em versões que a trixie estável (1.44) ainda não tem.

```bash
sudo apt install -t trixie-backports wayland-protocols
```

Confirmar a versão instalada:
```bash
apt-cache policy wayland-protocols
```

> É seguro: não é lib compartilhada, é pacote `arch:all` só com
> XML/headers usados em tempo de build. Sem risco de ABI/cascata.
>
> Sempre checar `tracker.debian.org/pkg/<nome>` (não só `packages.debian.org`)
> pra ver o histórico real de aceitação em cada suite, incluindo backports.

> **FYI (não recomendado por padrão):** o próprio projeto Noctalia mantém um
> `trixie-backports` próprio, de terceiros, em
> `pkg.noctalia.dev/deb/trixie-backports/`, com `wayland-protocols 1.49`
> (mais novo que o `1.47` do backports oficial usado acima), além de
> `wlroots`, `libwayland-*`, `libxkbcommon` e outros recompilados por eles.
> É uma opção real se algum protocolo novíssimo não estiver nem no
> backports oficial ainda — mas é repositório de terceiros (mais superfície
> de confiança que um `.deb` recompilado por você mesmo a partir da fonte
> oficial do Debian), e adotá-lo foge do princípio de "manter minhas
> próprias coisas" que motivou este guia. Fica registrado como opção
> conhecida, não como recomendação.

---

## 4. Noctalia v5 (empacotado com `debhelper` + Meson)

Diferente do niri: não precisa de toolchain especial, Debian 13 já vem com
compilador novo o bastante (GCC 13+) para o C++23 do projeto.

> **Reentre no `trixie-dev`.** A seção 3 terminou saindo do container pra
> instalar niri + xwayland-satellite no host. Pro Noctalia, volta:
> ```bash
> distrobox enter trixie-dev
> cd ~/Devel/noctalia-5.0.0-beta.4/
> ```
> Todos os passos 4.1 a 4.9 rodam dentro do distrobox — é lá que estão as
> build-deps instaladas. O ponto de saída é o final do 4.9: só depois do
> `dpkg-buildpackage` terminar é que você sai (`exit`) pra instalar o
> `.deb` no host, na seção 4.10.

### 4.1. Dependências de build
```bash
sudo apt install build-essential meson ninja-build pkg-config \
  libwayland-dev libegl-dev libgles-dev \
  libfreetype-dev libfontconfig-dev \
  libcairo2-dev libpango1.0-dev libharfbuzz-dev \
  libxkbcommon-dev libglib2.0-dev \
  libsecret-1-dev libsodium-dev \
  libsdbus-c++-dev libpipewire-0.3-dev libwireplumber-0.5-dev \
  libpolkit-agent-1-dev libpolkit-gobject-1-dev \
  libpam0g-dev libwebp-dev librsvg2-dev \
  libqalculate-dev libxml2-dev libmd4c-dev libjemalloc-dev \
  libtomlplusplus-dev nlohmann-json3-dev libstb-dev \
  libcurl4-gnutls-dev
```
> Nota: `libqalculate-dev` no trixie puxa `libcurl4-gnutls-dev` (não a
> variante `-openssl`). As duas são conflitantes entre si — usar sempre a
> que já está resolvida no sistema (ver seção 4.5).
>
> Nota: `egl`/`glesv2` são checados pelo Meson via pkg-config, e quem
> fornece esses `.pc` no Debian são `libegl-dev`/`libgles-dev` (binários do
> source package `libglvnd`) — não `libegl1-mesa-dev` (é a implementação
> Mesa em si, não os headers vendor-neutros) nem `libglvnd-dev` (meta-pacote,
> funciona mas é redundante).
>
> `libstb-dev` também existe como pacote real no Debian (desde a trixie) e
> se aplica a mesma lógica acima: se estiver instalado, o Meson vai usar a
> versão do sistema em vez de vendorizar. Declarar como Build-Depends real.
>
> `nlohmann-json3-dev` e `libtomlplusplus-dev`, pelo mesmo motivo, também
> valem a pena declarar como Build-Depends reais. O Meson usa
> `dependency('x', fallback: [...])`, que sempre prioriza a versão do
> sistema se ela existir, e só vendoriza quando não encontra nada — ou
> seja, se esses pacotes estiverem instalados no ambiente de build, o
> Noctalia vai linkar contra eles de qualquer forma. Como a convenção de
> empacotamento Debian prefere explicitamente linkar contra libs do
> sistema em vez de vendorizar (evita duplicação de código e facilita
> atualização de segurança sem recompilar o Noctalia), o certo é declarar
> essas três como dependência real, não deixar ao acaso.
>
> **Desde a beta.4**, `libsodium-dev` e `libsecret-1-dev` passaram a ser
> dependências novas (antes não eram exigidas) — já estão incluídas acima.

O `PACKAGING.md` do repositório agora é um guia oficial mantido pelo
projeto, com notas de dependências, layout de instalação e até presença no
Repology — vale ler antes de fechar a lista definitiva, principalmente ao
atualizar de versão:
`github.com/noctalia-dev/noctalia/blob/main/PACKAGING.md`

> **Checagem cruzada (jul/2026):** o README oficial do projeto também lista
> a receita de `apt install` deles para Debian, e ela bate quase 1:1 com a
> lista acima. As únicas diferenças: eles incluem `just` (runner de build
> que a gente não usa, já que o `dh_auto_configure --buildsystem=meson`
> chama `meson`/`ninja` direto) e fixam `libcurl4-openssl-dev` sem
> alternância (a nossa com `libcurl4-gnutls-dev | libcurl4-openssl-dev` é
> mais robusta pro conflito real que apareceu com o `libqalculate-dev` no
> trixie — não precisa mudar).

### 4.2. Baixar o código-fonte
```bash
cd ~/Devel   # ainda dentro do trixie-dev
VERSION="v5.0.0-beta.4"   # conferir a tag mais recente antes de fixar
wget "https://github.com/noctalia-dev/noctalia/archive/refs/tags/${VERSION}.tar.gz" \
  -O noctalia_${VERSION#v}.orig.tar.gz
tar -xvf noctalia_${VERSION#v}.orig.tar.gz
cd noctalia-${VERSION#v}/
```
(o nome da pasta extraída segue o padrão `noctalia-5.0.0-beta.4/`, sem o `v`
inicial da tag — é esse o caminho usado no resto da seção 4.)

### 4.3. Testar build puro antes de empacotar
```bash
meson setup build-release --buildtype=release
ninja -C build-release
```
Se der erro de protocolo faltando (`meson.build:XXX: ERROR: File .../staging/...
does not exist`), é a versão do `wayland-protocols` — ver seção 3.5.

### 4.4. Gerar o esqueleto de empacotamento
```bash
sudo apt install dh-make
dh_make -s -y --createorig
```
(já estamos dentro de `noctalia-5.0.0-beta.4/` desde a seção 4.2 — não
precisa `cd` de novo.)

Limpar os templates de exemplo que não servem:
```bash
cd debian/
rm -f *.ex gbp.conf.ex gitignore.ex salsa-ci.yml.ex README.Debian.ex README.source.ex
```

### 4.5. `debian/control`
```
Source: noctalia
Section: x11
Priority: optional
Maintainer: Kim <seu-email@exemplo.com>
Rules-Requires-Root: no
Build-Depends:
 debhelper-compat (= 13),
 meson,
 ninja-build,
 pkg-config,
 libwayland-dev,
 wayland-protocols (>= 1.45),
 libegl-dev,
 libgles-dev,
 libfreetype-dev,
 libfontconfig-dev,
 libcairo2-dev,
 libpango1.0-dev,
 libharfbuzz-dev,
 libxkbcommon-dev,
 libglib2.0-dev,
 libsecret-1-dev,
 libsodium-dev,
 libsdbus-c++-dev,
 libpipewire-0.3-dev,
 libwireplumber-0.5-dev,
 libpolkit-agent-1-dev,
 libpolkit-gobject-1-dev,
 libpam0g-dev,
 libcurl4-gnutls-dev | libcurl4-openssl-dev,
 libwebp-dev,
 librsvg2-dev,
 libqalculate-dev,
 libxml2-dev,
 libmd4c-dev,
 libjemalloc-dev,
 libtomlplusplus-dev,
 nlohmann-json3-dev,
 libstb-dev
Standards-Version: 4.7.2
Homepage: https://github.com/noctalia-dev/noctalia

Package: noctalia
Architecture: any
Depends:
 ${shlibs:Depends},
 ${misc:Depends},
 pipewire
Description: Native Wayland desktop shell (personal build)
 Build local do Noctalia v5, sem dependência de Qt/GTK,
 mantido fora do repositório oficial para uso próprio.
```

> A dependência de curl usa `|` (alternância) de propósito: `libqalculate-dev`
> já resolve para `libcurl4-gnutls-dev`, e forçar a variante `-openssl`
> gera conflito. Regra geral: se o `mk-build-deps` acusar conflito entre
> duas variantes de uma mesma lib (comum em SSL vs GnuTLS), trocar a
> entrada fixa por alternância com `|`.

### 4.6. `debian/rules`
```makefile
#!/usr/bin/make -f
%:
	dh $@ --buildsystem=meson
```

### 4.7. `debian/changelog`
```bash
sudo apt install devscripts   # só na primeira vez — dá o dch e o mk-build-deps
dch --edit
```
Usar versão própria, ex.: `noctalia (5.0.0~beta.4-1~localbuild1) unstable; urgency=medium`

### 4.8. `debian/copyright`
```
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: noctalia
Source: https://github.com/noctalia-dev/noctalia

Files: *
Copyright: 2025-2026 Noctalia contributors
License: MIT
```

### 4.9. Instalar as build-deps e compilar
```bash
sudo mk-build-deps -i debian/control
```
Se o apt reclamar de conflito entre pacotes (ex.: libcurl variantes) ao
instalar o pacote de dependências gerado:
1. Responder **`n`** no prompt de remoção.
2. Ajustar o `debian/control` para alternância `|` na lib conflitante.
3. Limpar o resíduo e gerar de novo:
   ```bash
   sudo apt purge noctalia-build-deps
   rm -f ../noctalia-build-deps_*.deb ../noctalia-build-deps_*.buildinfo ../noctalia-build-deps_*.changes
   sudo mk-build-deps -i debian/control
   ```

Build final:
```bash
dpkg-buildpackage -us -uc -b
```

### 4.10. Onde fica o `.deb` e quando sair do container
Diferente do `cargo deb` (seção 2.7, que deixa o pacote dentro de
`target/debian/`), o `dpkg-buildpackage` sempre gera os artefatos **um nível
acima da pasta-fonte** — nunca dentro de `debian/`, nem dentro da própria
pasta do projeto. Se você rodou os comandos de dentro de
`~/Devel/noctalia-5.0.0-beta.4/`, o `.deb` aparece em:
```
~/Devel/noctalia_5.0.0~beta.4-1~localbuild1_amd64.deb
```
Confirme com:
```bash
ls ../*.deb
```

**➡️ Este é o momento de sair do distrobox.** A compilação inteira (seções
4.1 a 4.8) acontece dentro do `trixie-dev`; a instalação é sempre no host:
```bash
exit   # sai do distrobox
sudo apt install ~/Devel/noctalia_*.deb
```

> **Nunca copie/instale o `noctalia-build-deps_*.deb` no host.** Ele é um
> pacote dummy (via `equivs`), sem nenhum binário real dentro — só serve
> pra puxar as `-dev`s de uma vez dentro do container, na seção 4.9. Levar
> ele pro host (ou deixar um registro dele pela metade no `dpkg`) faz o
> `apt` tentar "consertar" esse pacote junto na hora de instalar o
> `noctalia` de verdade, e como o host não tem as `-dev`s (nem precisa
> ter), a instalação trava pedindo dependências que não fazem sentido pro
> usuário final.
>
> **Se isso acontecer** (erro citando `noctalia-build-deps` em vez de
> `noctalia` ao instalar), é sinal de que esse pacote dummy ficou
> registrado de alguma forma no `dpkg` do host. Verificar e limpar:
> ```bash
> dpkg -l | grep -i noctalia
> sudo dpkg --purge noctalia-build-deps
> # se reclamar de dependência quebrada:
> sudo dpkg --remove --force-remove-reinstreq noctalia-build-deps
> sudo apt --fix-broken install
> ```
> Depois disso o `sudo apt install ~/Devel/noctalia_*.deb` instala limpo —
> e o `Depends:` real do `noctalia` é só `${shlibs:Depends}` (libs de
> runtime) + `pipewire`, nada de `-dev`.

---

## 5. Rotina de atualização (resumo)

| Componente          | Cadência                          | Como atualizar |
|----------------------|-----------------------------------|-----------------|
| kernel / Mesa        | conforme necessidade de hardware  | `apt -t trixie-backports` |
| wayland-protocols     | quando algum protocolo novo faltar | `apt -t trixie-backports` |
| niri                  | a cada poucos meses (sob demanda) | `cargo deb`, guardar `.deb` anterior |
| xwayland-satellite     | raramente                        | `cargo deb` |
| Noctalia v5 (beta)     | mensal (olhar changelog), atualizar sob demanda | refazer passos da seção 4 |

Sempre guardar o `.deb` da versão anterior de cada componente antes de
atualizar — rollback é só `dpkg -i` do arquivo antigo.

Fluxo de atualização do niri/xwayland-satellite, resumido:
```bash
distrobox enter trixie-dev
cd ~/Devel/niri-<nova-versão>/
git apply ~/Devel/patches/niri-cargo-deb.patch   # reaplica os assets
cargo deb -- --locked
exit
sudo apt install ~/Devel/niri-*/target/debian/niri_*_amd64.deb
```

---

## 6. Apêndice — display manager e polkit (greetd + tuigreet)

Combo mínimo pra logar direto numa sessão niri/Noctalia sem GDM/SDDM:
```bash
sudo apt install mate-polkit tuigreet greetd
```

Editar `/etc/greetd/config.toml`, ajustando a linha `command`:
```
command = "tuigreet --remember --cmd niri-session"
```

E no `~/.config/niri/config.kdl`, adicionar o agente de polkit junto dos
outros `spawn-at-startup`:
```kdl
spawn-at-startup "/usr/libexec/polkit-mate-authentication-agent-1"
```

> **Alternativa oficial:** o próprio projeto mantém um greeter dedicado,
> o **Noctalia Greeter**, num repositório separado
> (`github.com/noctalia-dev/noctalia-greeter`, listado como dependência
> opcional no pacote AUR). Ele deve seguir o mesmo modelo de tema/config do
> Noctalia — vale considerar no lugar do `tuigreet` se quiser uma tela de
> login visualmente integrada.
>
> Confirmado: já existe `.deb` dele no repositório de terceiros do projeto
> (`noctalia-greeter_1.0.0-50-gc0a8f53-1~bpo13+1_amd64.deb`, em
> `pkg.noctalia.dev/deb/trixie-backports/`) — mas é de terceiros, não
> compilamos/validamos ele aqui. Se quiser adotar, o caminho consistente
> com o resto deste guia seria compilar e empacotar do próprio código-fonte
> (mesmo fluxo `debhelper`+Meson da seção 4), não instalar o `.deb` alheio
> direto.

### Pacotes de sessão "avulsos" (opcional)

Se em algum momento quiser componentes standalone além do que o Noctalia
já cobre (bar, launcher, lockscreen), o conjunto usual pra uma sessão niri
pura é:
```bash
sudo apt install fuzzel waybar alacritty pipewire pipewire-alsa \
  pipewire-jack pavucontrol xdg-desktop-portal xdg-desktop-portal-gtk \
  libglx-mesa0 libegl-mesa0 libgbm1 mesa-vulkan-drivers \
  mesa-va-drivers mesa-vdpau-drivers libegl1 swaylock swaybg swayidle
```
Como o Noctalia v5 já entrega bar, launcher e lockscreen nativos, a maior
parte disso é redundante no seu caso — vale só pra testar niri isolado ou
como fallback caso algo no Noctalia quebre numa atualização.

---

## 7. apt: habilitando o backports e `apt modernize-sources`

### 7.1. Habilitando o trixie-backports (formato deb822)

Diferente de versões antigas do Debian, a trixie usa por padrão o formato
**deb822** (`.sources`), não mais o `.list` de uma linha. Pra habilitar o
backports, criar um arquivo dedicado:
```bash
sudo nano /etc/apt/sources.list.d/debian-backports.sources
```
com o conteúdo:
```
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
```
Depois:
```bash
sudo apt update
```

Isso só **registra** o repositório — nada é instalado automaticamente por
causa disso. Continua valendo a regra da seção 0: instalar pacote a pacote
(`apt install pacote/trixie-backports` ou `apt install -t trixie-backports
pacote`), nunca liberar o backports de forma geral no sistema.

### 7.2. `apt modernize-sources`

É comum, depois de instalar ou migrar pra trixie, ver esse aviso ao rodar
`apt update`:
```
Notice: Some sources can be modernized. Run 'apt modernize-sources' to do so.
```
Ele aparece quando existe algum arquivo `.list` no formato antigo (uma
linha por repositório) convivendo com o novo padrão deb822.

O que o comando faz: converte cada `.list`/`sources.list` antigo pro
formato `.sources` novo, tentando resolver o `Signed-By` automaticamente a
partir das chaves já confiáveis no sistema, e guarda o original como
`.list.bak` (nada é destruído).
```bash
sudo apt modernize-sources
```
Ele sempre pergunta antes de aplicar — responder `n` primeiro simula e
mostra o que seria alterado, sem tocar em nada; rodar de novo e responder
`y` aplica de fato.

Não muda em nada a prática deste guia — `apt install pacote/trixie-backports`
funciona igual nos dois formatos, é só uma questão de organização do
arquivo. Vale rodar pelo menos uma vez pra não ficar recebendo o aviso
toda hora e já deixar tudo no padrão que a própria trixie recomenda.

---

## 8. Troubleshooting — Noctalia demorando pra subir (VM)

Se o Noctalia demora alguns segundos pra aparecer junto com o niri (e a
mesma versão sobe quase instantânea em outro lugar), checar nessa ordem:

1. **Renderização por software (causa mais comum em VM).** Se a VM não tem
   aceleração 3D configurada (virtio-gpu+virgl, passthrough), o EGL cai pro
   `llvmpipe` (via CPU), muito mais lento pra inicializar:
   ```bash
   eglinfo | grep "OpenGL renderer"
   ```
   Se aparecer `llvmpipe`/`softpipe`, o problema é a VM, não o pacote.

2. **Cache de shader do Mesa invalidado a cada rebuild.** O cache em
   `~/.cache/mesa_shader_cache` é indexado pelo hash do binário — como cada
   build próprio (`~localbuild1`) tem hash diferente, a *primeira* subida
   depois de cada `dpkg-buildpackage` novo recompila shaders do zero.
   Comparar a primeira subida após um rebuild com as subidas seguintes.

3. **`buildtype` do Meson.** Forçar explicitamente `release` (otimizações +
   `NDEBUG`) em vez de confiar no padrão do plugin meson do debhelper:
   ```makefile
   override_dh_auto_configure:
   	dh_auto_configure -- --buildtype=release
   ```

4. **Ordem de start via systemd.** Se o `noctalia.service` espera outros
   serviços (`pipewire`, `wireplumber`, `polkit`) ficarem prontos, isso é
   espera de dependência, não lentidão do binário:
   ```bash
   journalctl --user -u noctalia --since "5 min ago"
   ```

---

## 9. Links de referência

- PACKAGING.md do Noctalia: github.com/noctalia-dev/noctalia/blob/main/PACKAGING.md
- Debian Package Tracker (histórico real por suite, incl. backports):
  tracker.debian.org/pkg/<nome-do-pacote>
- Debian Developer's Reference — capítulo sobre debhelper/dpkg-buildpackage
- Não quebre o Debian (wiki oficial): wiki.debian.org/pt_BR/DontBreakDebian
- Guia da comunidade Diolinux (base do fluxo distrobox/Cargo.toml/greetd):
  plus.diolinux.com.br/t/guia-tutorial-instalar-niri-no-debian-13/80882
