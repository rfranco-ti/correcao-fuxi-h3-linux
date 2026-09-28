# Correção Fuxi-H3 no Linux

Sem som no fone USB **Weltrend Fuxi-H3 (`040b:0897`)**, mesmo com o PipeWire
mostrando áudio tocando? Este script resolve em **um comando**.

Causa: um controle ALSA escondido (`PCM,1`, mono) fica em 0% e zera o som.

## Uso rápido

```bash
sudo ./fix-fuxi-h3.sh
```

Só diagnosticar, sem alterar nada:

```bash
./fix-fuxi-h3.sh --check
```

## O que ele faz

1. Detecta o dongle e a placa ALSA
2. Sobe o volume na hora (`PCM,0` + `PCM,1` em 100%)
3. Cria regra udev para o volume não zerar a cada plug
4. Ativa soft-mixer no WirePlumber
5. Reinicia o áudio e define o Fuxi como saída padrão

## Opções

| Opção | Para quê |
|---|---|
| `--check` | Diagnóstico, sem alterar |
| `--dry-run` | Mostra o que faria |
| `--volume 70` | Volume final (padrão: 60) |
| `--yes` | Não pergunta nada |
| `--install-deps` | Instala dependências |
| `--uninstall` | Remove a correção |
| `--no-restart` | Não reinicia o áudio |

## Compatibilidade

Testado em **Fedora, Ubuntu e Arch** (e derivados).

Precisa de: `usbutils`, `alsa-utils`, `systemd`, `pipewire`/`wireplumber`.

## Ainda mudo?

1. Ligue o dongle direto na USB traseira, fora de hub
2. Confira o botão de mute do próprio dongle
3. Reencaixe o P2 até o clique
4. Rode `./fix-fuxi-h3.sh --check` e veja o que está diferente
