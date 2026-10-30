# Instalação do NixOS 26.05 com Flakes, Disko-install e LUKS

## Pré-requisitos
- LiveCD do NixOS 26.05
- Conexão com internet
- Disco: Kingston SA400S37960G

---

## 1. Bootar o LiveCD

Inicie a máquina com o ISO do NixOS 26.05.

---

## 2. Configurar o LiveCD

```bash
loadkeys br-abnt2
sudo -i
ls -la /dev/disk/by-id/
# Confirme que o Kingston SSD aparece
```

Se a máquina não tiver Ethernet plugado e a rede não subir sozinha, configure o Wi-Fi antes de continuar:

```bash
nmtui
# ou, via linha de comando:
# nmcli device wifi connect "NOME_DA_REDE" password "SENHA"
```

Habilite também os recursos experimentais de flakes para esta sessão, já que a ISO padrão do NixOS não vem com isso ligado por padrão:

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"
```

---

## 3. Clonar o repositório

Prefira HTTPS ao invés de SSH — o LiveCD não tem suas chaves SSH configuradas por padrão:

```bash
nix-shell -p git
git clone https://github.com/eloahkim/my-nixos-config.git /mnt/etc/nixos
cd /mnt/etc/nixos
```

Se você realmente precisar usar SSH (por exemplo, repositório privado), configure a chave antes:

```bash
mkdir -p ~/.ssh
# copie sua chave privada para ~/.ssh/id_ed25519, ajuste as permissões (chmod 600)
# e então use a URL git@github.com:...
```

---

## 4. Atualizar o flake.lock

```bash
nix flake update
```

Se quiser atualizar só o input do nixpkgs (mais conservador, evita puxar mudanças em todos os outros inputs de uma vez):

```bash
nix flake lock --update-input nixpkgs
```

---

## 5. Gerar hardware-configuration (sem filesystems)

```bash
nixos-generate-config --root /mnt --no-filesystems
```

A flag `--no-filesystems` evita que o `nixos-generate-config` sobrescreva as configurações de disco que o disko vai gerenciar.

---

## 6. Rodar disko-install (particiona + formata + instala tudo)

```bash
nix run github:nix-community/disko/latest#disko-install -- \
  --write-efi-boot-entries \
  --flake .#lilith \
  --disk main /dev/disk/by-id/ata-KINGSTON_SA400S37960G_50026B7785D222F5
```

O `--disk main` substitui o `device` do disco chamado `main` no `disko-config.nix`.

A flag `--write-efi-boot-entries` é importante aqui: por padrão o disko-install **não** grava entradas de boot na NVRAM (ele foi pensado também para instalar em discos portáteis que trocam de máquina). Como este é um disco interno que vai ficar nesta máquina, sem essa flag o sistema pode não aparecer no menu de boot da UEFI.

**O disko-install vai:**
- Pedir a senha do LUKS interativamente
- Particionar, criptografar, formatar e montar
- Instalar o NixOS com seu flake

> ⚠️ **Atenção:** ao contrário do que se poderia esperar, o disko-install **não** pede a senha do root no final. Internamente ele roda `nixos-install --no-root-password`, então o usuário root fica sem senha definida. Garanta uma das opções abaixo:
> - Defina `users.users.<seu-usuario>.initialPassword` (ou `users.users.root.initialPassword`) no `configuration.nix`, **ou**
> - Defina a senha manualmente depois, pelo `nixos-enter` (passo 7).

---

## 7. Definir senha do usuário kim

```bash
nixos-enter --root /mnt -c 'passwd kim'
```

Se você manteve o `initialPassword = "temporaria"` no `configuration.nix`, o usuário kim já consegue logar — mas troque a senha assim que entrar:

```bash
passwd
```

> ⚠️ **Atenção:** há um problema conhecido (ver [issue #638](https://github.com/nix-community/disko/issues/638) do disko) em que `nixos-enter --root /mnt -c 'passwd kim'` pode falhar com erros como `chmod: changing permission of '/mnt/dev': Operation not permitted`. Não há uma causa raiz confirmada nem fix oficial até o momento. Se isso acontecer, tente entrar em modo shell interativo em vez de passar `-c`:
>
> ```bash
> nixos-enter --root /mnt
> passwd kim
> exit
> ```

---

## 8. Reboot

```bash
reboot
```

---

## Troubleshooting

### Boot trava pedindo senha LUKS em loop

Adicione ao `host/configuration.nix`:

```nix
boot.initrd.luks.devices.cryptroot.device = "/dev/disk/by-id/ata-KINGSTON_SA400S37960G_50026B7785D222F5-part2";
```

Além disso, como o NixOS 26.05 passou a usar systemd como Stage 1 (initrd) por padrão, garanta que o filesystem raiz aponte para o device mapper, e não para o `by-id` diretamente — caso contrário o systemd pode dar timeout esperando a senha:

```nix
fileSystems."/" = {
  device = "/dev/mapper/cryptroot"; # nome deve bater com boot.initrd.luks.devices.cryptroot
  fsType = "ext4"; # ajuste conforme seu filesystem
};
```

Em setups mais complexos (por exemplo LVM sobre LUKS), pode ser necessário adicionar isso em vez do device mapper direto:

```nix
fileSystems."/".options = [ "x-systemd.device-timeout=infinity" ];
```

### Fallback para initrd scriptado

Se o systemd Stage 1 causar problemas:

```nix
boot.initrd.systemd.enable = false;
```

Use apenas temporariamente — será removido na NixOS 26.11.

### "device not found" no disko

```bash
ls -la /dev/disk/by-id/
```

Ajuste o `disko-config.nix` se o `by-id` for diferente.

### Rebuildar depois da instalação

```bash
sudo nixos-rebuild switch --flake /etc/nixos#lilith
```

---

## Notas de revisão

Este guia foi revisado e corrigido em relação a uma versão anterior. Resumo das mudanças:

- Adicionado `export NIX_CONFIG="experimental-features = nix-command flakes"`, necessário porque a ISO padrão do NixOS não vem com flakes habilitado.
- Adicionada instrução para configurar rede (`nmtui`) no LiveCD.
- Trocado clone via SSH por HTTPS (o LiveCD não tem chaves SSH configuradas por padrão), com nota para quem precisa de SSH mesmo assim.
- Adicionada alternativa `nix flake lock --update-input nixpkgs` para atualizações mais conservadoras.
- Adicionada flag `--write-efi-boot-entries` ao comando do disko-install, necessária para discos internos (não portáteis).
- Corrigida a afirmação de que o disko-install pede senha de root — na verdade ele roda com `--no-root-password`, então é preciso definir a senha manualmente.
- Adicionado aviso sobre falha conhecida do `nixos-enter -c` (issue #638 do disko) e contorno via shell interativo.
- Adicionada orientação da release note oficial do NixOS 26.05 sobre `fileSystems."/".device` apontar para `/dev/mapper/<nome>` em setups com LUKS + systemd stage 1.
