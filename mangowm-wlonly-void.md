# mangowm-wlonly — Empacotamento para Void Linux

Branch **wl-only** do [mangowm](https://github.com/mangowm/mango) (sem scenefx).

---

## 1. Template (versão estável com commit pinned)

Arquivo: `srcpkgs/mangowm-wlonly/template`

```
# Template file for 'mangowm-wlonly'
pkgname=mangowm-wlonly
version=0.15.5
revision=1
_commit=84caa4a8dbdcb5a9a922585f1193c906717fecbc
wrksrc=mango-${_commit}
build_style=meson
hostmakedepends="pkg-config wayland-devel"
makedepends="cJSON-devel wlroots0.20-devel pcre2-devel pango-devel"
depends="$(vopt_if xwayland xorg-server-xwayland)"
short_desc="Lightweight Wayland compositor based on dwl (wl-only branch, no scenefx)"
maintainer="Seu Nome <seu@email>"
license="GPL-3.0-only"
homepage="https://github.com/mangowm/mango/tree/wl-only"
distfiles="https://github.com/mangowm/mango/archive/${_commit}.tar.gz"
checksum=<sha256 apos fetch>

build_options="xwayland"
desc_option_xwayland="Enable Xwayland support"
```

### Sobre as dependências

| Dep do meson.build | Pacote Void | Por quê |
|---|---|---|
| `wlroots-0.20 >= 0.20.0` | `wlroots0.20-devel` | Essencial, wl-only usa wlroots puro |
| `libcjson` | `cJSON-devel` | Parser de config |
| `libpcre2-8` | `pcre2-devel` | Regex |
| `pangocairo` | `pango-devel` | Renderização de texto |
| `xwayland` (opcional) | `xorg-server-xwayland` | Apenas runtime |

O `wlroots0.20-devel` puxa as dependências transitivas (libdrm, libinput, libxkbcommon, pixman, wayland, etc.) automaticamente.

---

## 2. Build e instalação

```bash
# Pré-requisito: void-packages clonado e bootstrap feito
# git clone https://github.com/void-linux/void-packages.git
# cd void-packages
# ./xbps-src binary-bootstrap

# 1. Criar diretório do pacote
mkdir -p srcpkgs/mangowm-wlonly

# 2. Escrever o template (conteúdo acima) em srcpkgs/mangowm-wlonly/template

# 3. Fetch para baixar o source
./xbps-src fetch mangowm-wlonly

# 4. Descobrir o checksum
sha256sum hostdir/sources/mango-84caa4a8dbdcb5a9a922585f1193c906717fecbc.tar.gz

# 5. Inserir o checksum no template (campo checksum)

# 6. Build
./xbps-src pkg mangowm-wlonly

# 7. Instalar
sudo xbps-install -R hostdir/binpkgs mangowm-wlonly
```

Para build sem Xwayland:

```bash
./xbps-src pkg mangowm-wlonly -D xwayland disabled
```

---

## 3. Como atualizar o pacote

### 3.1 Descobrir o commit mais recente no wl-only

```bash
curl -s https://api.github.com/repos/mangowm/mango/commits/wl-only | jq -r '.sha'
```

Ou, sem jq:

```bash
curl -s https://api.github.com/repos/mangowm/mango/commits/wl-only | grep -m1 '"sha"' | cut -d'"' -f4
```

### 3.2 Descobrir a versão no meson.build

```bash
COMMIT=$(curl -s https://api.github.com/repos/mangowm/mango/commits/wl-only | grep -m1 '"sha"' | cut -d'"' -f4)
curl -s "https://raw.githubusercontent.com/mangowm/mango/$COMMIT/meson.build" | grep "version :" | cut -d"'" -f2
```

### 3.3 Atualizar o template

Editar no template:

- `version` → nova versão (ex: `0.16.0`), `revision` volta pra `1`
- `_commit` → novo hash
- `wrksrc` → `mango-${_commit}` (já usa a variável, não precisa mudar)
- `checksum` → novo sha256

Output esperado:

```bash
# Exemplo: trocar de 0.15.5 para 0.16.0
# No template:
#   version=0.16.0
#   revision=1
#   _commit=abc123def456...
```

### 3.4 Rebuild e reinstalação

```bash
# limpar cache do source antigo
rm -f hostdir/sources/mango-*.tar.gz

./xbps-src fetch mangowm-wlonly
# pegar o sha256 e colocar no template
sha256sum hostdir/sources/mango-*.tar.gz

./xbps-src pkg mangowm-wlonly
sudo xbps-install -f -R hostdir/binpkgs mangowm-wlonly
```

### Regras de versionamento

- **`version`**: sobe conforme a versão declarada no `meson.build`
- **`revision`**: incrementa (`1` → `2` → `3`...) quando o template muda mas a versão não (ex: correção de dependência, patch). Quando `version` sobe, `revision` volta pra `1`.

---

## 4. Script auxiliar (update.sh)

Colocar junto ao template para automatizar:

```bash
#!/bin/bash
# update.sh — atualiza mangowm-wlonly para o último commit do wl-only
# Uso: ./update.sh [caminho-para-void-packages]

VOID_DIR="${1:-.}"
TEMPLATE="$VOID_DIR/srcpkgs/mangowc-wlonly/template"

if [ ! -f "$TEMPLATE" ]; then
	echo "Template não encontrado em $TEMPLATE"
	exit 1
fi

echo "Buscando último commit do wl-only..."
COMMIT=$(curl -s https://api.github.com/repos/mangowm/mango/commits/wl-only | grep -m1 '"sha"' | cut -d'"' -f4)
VERSION=$(curl -s "https://raw.githubusercontent.com/mangowm/mango/$COMMIT/meson.build" | grep "version :" | cut -d"'" -f2)

echo "Commit: $COMMIT"
echo "Versão: $VERSION"

# baixar e calcular checksum
ARCHIVE_URL="https://github.com/mangowm/mango/archive/$COMMIT.tar.gz"
TMPFILE=$(mktemp)
curl -sL "$ARCHIVE_URL" -o "$TMPFILE"
SHA256=$(sha256sum "$TMPFILE" | cut -d' ' -f1)
rm -f "$TMPFILE"

# atualizar template
sed -i "s/^version=.*/version=$VERSION/" "$TEMPLATE"
sed -i "s/^revision=.*/revision=1/" "$TEMPLATE"
sed -i "s/^_commit=.*/_commit=$COMMIT/" "$TEMPLATE"
sed -i "s/^checksum=.*/checksum=$SHA256/" "$TEMPLATE"

echo "Template atualizado: version=$VERSION, commit=$COMMIT, sha256=$SHA256"
```

---

## 5. Bônus: mangowm-wlonly-git

### Quando usar

Quando você quiser **sempre o último commit** sem se preocupar em atualizar manualmente.

### Diferenças para o version pinned

| Aspecto | `mangowm-wlonly` (pinned) | `mangowm-wlonly-git` (git) |
|---|---|---|
| Versão | Fixa (ex: 0.15.5) | Rolling (ex: 0.15.5.1, 0.15.5.2...) |
| Fonte | Tarball de um commit específico | Clone do repositório git |
| Atualização | Manual (trocar commit) | `./xbps-src pkg` sempre pega o HEAD |
| Estabilidade | Previsível, testado | Pode pegar algo quebrado |
| Uso | Recomendado para uso diário | Recomendado para testar novidades |

### Template git

Arquivo: `srcpkgs/mangowm-wlonly-git/template`

```
# Template file for 'mangowm-wlonly-git'
pkgname=mangowm-wlonly-git
version=0.15.5
revision=1
_commit=84caa4a8dbdcb5a9a922585f1193c906717fecbc
wrksrc=mango-${version}
build_style=meson
create_wrksrc=yes
hostmakedepends="pkg-config wayland-devel git"
makedepends="cJSON-devel wlroots0.20-devel pcre2-devel pango-devel"
depends="$(vopt_if xwayland xorg-server-xwayland)"
short_desc="Lightweight Wayland compositor based on dwl (wl-only branch, git version)"
maintainer="Seu Nome <seu@email>"
license="GPL-3.0-only"
homepage="https://github.com/mangowm/mango/tree/wl-only"
distfiles="https://github.com/mangowm/mango.git>wl-only>mango-${version}"
checksum=SKIP

build_options="xwayland"
desc_option_xwayland="Enable Xwayland support"

if [ "$build_option_xwayland" ]; then
	makedepends+=" libxcb-devel"
fi
```

### Como manter o -git

- A fonte já é o branch `wl-only` — toda build usa o HEAD
- Para rebuildar: `./xbps-src pkg mangowm-wlonly-git`
- A versão segue o padrão Void para git packages: `0.15.5.1`, `0.15.5.2`... O `_commit` no template é o hash conhecido, mas o `distfiles` clona o branch
- Para saber se há algo novo: `git fetch` no source ou conferir o repositório upstream

### Como ter os dois pacotes

Nada impede de manter ambos:

- `mangowm-wlonly` — versão pinned, uso diário
- `mangowm-wlonly-git` — quando quiser testar o que há de novo

Só cuidar com conflitos de arquivo: os dois instalam o binário `mango`. Use `conflicts="mangowm-wlonly-git"` no template do pinned e vice-versa.

---

## 6. Referências

- [void-packages Manual](https://github.com/void-linux/void-packages/blob/master/Manual.md)
- [void-packages README (quick start)](https://github.com/void-linux/void-packages)
- [Template do mangowc (main branch, referência)](https://github.com/void-linux/void-packages/blob/master/srcpkgs/mangowc/template)
- [AUR mangowm-wlonly](https://aur.archlinux.org/packages/mangowm-wlonly) (inspiração)
