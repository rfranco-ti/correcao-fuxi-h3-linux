#!/usr/bin/env bash
# fix-fuxi-h3.sh — correção em um comando para o dongle
# Weltrend Fuxi-H3 (040b:0897) / XiiSound USB Audio sem som no fone.
#
# Uso:
#   ./fix-fuxi-h3.sh [--check] [--dry-run] [--no-restart] [--volume 60] [--yes] [--install-deps] [--uninstall]
#
# O que faz (idempotente):
#   1. detecta o dongle via lsusb e a placa ALSA (nome FuxiH3 ou índice via aplay)
#   2. sobe na hora: amixer PCM,0 / PCM,1 100% unmute + alsactl store
#   3. persiste via udev: /etc/udev/rules.d/90-fuxi-h3.rules
#   4. persiste via WirePlumber (se existir): soft-mixer para o Fuxi-H3
#      (sistema em /etc/... ou usuário em ~/.config/... quando sem sudo)
#   5. reinicia wireplumber/pipewire (ou pulseaudio) no escopo --user
#   6. define o sink Fuxi como padrão, unmute e volume
#
# Universal: Fedora, Ubuntu e Arch (e derivados).
# Testado em Fedora, Ubuntu e Arch. Em outras distros o script segue os
# mesmos passos em modo best-effort.

set -u

VENDOR="040b"
PRODUCT="0897"
CARD_NAME="FuxiH3"
UDEV_RULE_FILE="/etc/udev/rules.d/90-fuxi-h3.rules"
WP_SYS_DIR="/etc/wireplumber/wireplumber.conf.d"
WP_SYS_FILE="$WP_SYS_DIR/51-fuxi-h3-softmixer.conf"
WP_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
WP_USER_FILE="$WP_USER_DIR/51-fuxi-h3-softmixer.conf"
DEVICE_NAME="alsa_card.usb-XiiSound_Technology_Corporation_Fuxi-H3-00"

VOLUME="60%"
DO_CHECK=0
DRY_RUN=0
NO_RESTART=0
ASSUME_YES=0
INSTALL_DEPS=0
DO_UNINSTALL=0

log()  { printf '%s\n' "$*"; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }
err()  { printf 'ERRO: %s\n' "$*" >&2; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

usage() {
  cat <<'EOF'
Uso: ./fix-fuxi-h3.sh [OPÇÕES]
  --check         só diagnostica, não altera nada
  --dry-run       mostra o que faria, sem alterar
  --no-restart    não reinicia wireplumber/pipewire
  --volume PCT    volume final do sink (padrão 60). Ex.: --volume 70 ou --volume=70
  --yes, -y       não pergunta nada
  --install-deps  tenta instalar dependências (dnf/apt/pacman)
  --uninstall     remove a regra udev e as confs WirePlumber criadas
  -h, --help      esta ajuda
Testado em Fedora, Ubuntu e Arch.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check) DO_CHECK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-restart) NO_RESTART=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --install-deps) INSTALL_DEPS=1; shift ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    --volume=*) VOLUME="${1#--volume=}"; VOLUME="${VOLUME%\%}%"; shift ;;
    --volume)
      shift
      if [ $# -eq 0 ]; then err "--volume precisa de valor: --volume 60"; exit 2; fi
      VOLUME="${1%\%}%"; shift ;;
    *) err "opção desconhecida: $1 (use --help)"; exit 2 ;;
  esac
done

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi
fi
priv() {  # executa com sudo quando necessário e disponível
  if [ -n "$SUDO" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] sudo %s\n' "$*"; return 0; fi
    $SUDO "$@"
  else
    if [ "$(id -u)" -eq 0 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] %s\n' "$*"; return 0; fi
      "$@"
    else
      return 99
    fi
  fi
}

detect_distro() {
  ID_DISTRO="desconhecida"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    ID_DISTRO="${ID:-desconhecida}"
  fi
  printf '%s' "$ID_DISTRO"
}

check_deps() {
  missing=""
  for bin in lsusb aplay amixer alsactl udevadm systemctl; do
    command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
  done
  if ! command -v pactl >/dev/null 2>&1 && ! command -v wpctl >/dev/null 2>&1; then
    missing="$missing pactl|wpctl"
  fi
  if [ -n "$missing" ]; then
    warn "ferramentas ausentes:$missing"
    distro="$(detect_distro)"
    case "$distro" in
      fedora|rhel|centos|rocky|alma) hint="sudo dnf install -y usbutils alsa-utils systemd pipewire wireplumber" ;;
      ubuntu|pop|linuxmint|debian)   hint="sudo apt update && sudo apt install -y usbutils alsa-utils systemd pipewire wireplumber" ;;
      arch|manjaro|endeavouros)      hint="sudo pacman -S --needed usbutils alsa-utils systemd pipewire wireplumber" ;;
      *) hint="instale: usbutils, alsa-utils, systemd, pipewire/wireplumber" ;;
    esac
    log "Dica ($distro): $hint"
    log "Testado em Fedora, Ubuntu e Arch; nesta distro ($distro) sigo com os mesmos passos."
    if [ "$INSTALL_DEPS" -eq 1 ]; then
      log "Tentando instalar dependências..."
      case "$distro" in
        fedora|rhel|centos|rocky|alma) priv dnf install -y usbutils alsa-utils systemd pipewire wireplumber || warn "falha no dnf" ;;
        ubuntu|pop|linuxmint|debian) priv apt update && priv apt install -y usbutils alsa-utils systemd pipewire wireplumber || warn "falha no apt" ;;
        arch|manjaro|endeavouros) priv pacman -S --needed --noconfirm usbutils alsa-utils systemd pipewire wireplumber || warn "falha no pacman" ;;
        *) warn "instalação automática só mapeada para Fedora, Ubuntu e Arch; instale manualmente e rode de novo."; return 1 ;;
      esac
    fi
  fi
}

find_card() {
  # 1) nome estável
  if amixer -c "$CARD_NAME" info >/dev/null 2>&1; then printf '%s' "$CARD_NAME"; return 0; fi
  # 2) índice via aplay -l (linha "card N: ...Fuxi...")
  idx="$(aplay -l 2>/dev/null | grep -i fuxi | head -n1 | sed -n 's/^card \([0-9][0-9]*\):.*/\1/p')"
  if [ -n "$idx" ]; then printf '%s' "$idx"; return 0; fi
  # 3) via /proc/asound/cards
  idx="$(grep -i fuxi /proc/asound/cards 2>/dev/null | head -n1 | sed -n 's/^ *\([0-9][0-9]*\) .*$/\1/p')"
  if [ -n "$idx" ]; then printf '%s' "$idx"; return 0; fi
  return 1
}

dongle_present() { lsusb -d "$VENDOR:$PRODUCT" 2>/dev/null | grep -q .; }

amixer_bin() { command -v amixer 2>/dev/null || printf '/usr/bin/amixer'; }
systemd_run_bin() { command -v systemd-run 2>/dev/null || printf '/usr/bin/systemd-run'; }

udev_rule_content() {
  cat <<EOF
# Fuxi-H3: master escondido PCM,1 volta a 0% a cada plug -> força 100%
ACTION=="add", SUBSYSTEM=="sound", ATTRS{idVendor}=="$VENDOR", ATTRS{idProduct}=="$PRODUCT", RUN+="$(systemd_run_bin) --no-block --quiet --on-active=2 $(amixer_bin) -c $CARD_NAME sset PCM,1 100%"
EOF
}

wp_conf_content() {
  cat <<EOF
# Fuxi-H3: usa soft-mixer do PipeWire para o volume não depender só do hardware
monitor.alsa.rules = [
  {
    matches = [
      {
        alsa.id = "$CARD_NAME"
      }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
      }
    }
  }
  {
    matches = [
      {
        device.name = "$DEVICE_NAME"
      }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
      }
    }
  }
]
EOF
}

write_file_priv() { # $1=destino (lê stdin)
  dest="$1"
  if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] escrever %s\n' "$dest"; return 0; fi
  if [ -w "$(dirname "$dest")" ]; then
    cat > "$dest"
  else
    priv tee "$dest" >/dev/null
  fi
}

restart_audio() {
  [ "$NO_RESTART" -eq 1 ] && { log "Pulando reinício (--no-restart)."; return 0; }
  if systemctl --user list-unit-files 2>/dev/null | grep -q '^wireplumber'; then
    log "Reiniciando wireplumber (user)..."
    run systemctl --user restart wireplumber || warn "falha ao reiniciar wireplumber"
  fi
  if systemctl --user list-unit-files 2>/dev/null | grep -q '^pipewire\.service'; then
    log "Reiniciando pipewire (user)..."
    run systemctl --user restart pipewire pipewire-pulse 2>/dev/null || true
  elif command -v pulseaudio >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
    log "Reiniciando pulseaudio..."
    run pulseaudio -k 2>/dev/null || true
  fi
  [ "$DRY_RUN" -eq 0 ] && sleep 2
}

set_default_sink() {
  sink="$(pactl list short sinks 2>/dev/null | grep -i -e fuxi -e xiiSound | head -n1 | awk '{print $2}')"
  [ -z "$sink" ] && sink="$(pactl list short sinks 2>/dev/null | head -n1 | awk '{print $2}')"
  [ -z "$sink" ] && { warn "nenhum sink encontrado via pactl"; return 0; }
  if echo "$sink" | grep -qi fuxi; then
    log "Sink Fuxi: $sink"
  else
    warn "Fuxi não apareceu como sink; usando $sink"
  fi
  run pactl set-default-sink "$sink" 2>/dev/null || true
  run pactl set-sink-mute "$sink" 0 2>/dev/null || true
  run pactl set-sink-volume "$sink" "$VOLUME" 2>/dev/null || true
}

do_check() {
  log "=== check Fuxi-H3 ==="
  if dongle_present; then log "USB: dongle $VENDOR:$PRODUCT presente"; lsusb -d "$VENDOR:$PRODUCT"
  else warn "USB: dongle $VENDOR:$PRODUCT NÃO encontrado (desplugado ou em outro barramento)"; fi
  card="$(find_card || true)"
  if [ -n "$card" ]; then
    log "ALSA: placa '$card' encontrada"
    amixer -c "$card" sget 'PCM',0 2>&1 | grep -E 'Front|Playback|off|on' | head -n 4 || true
    amixer -c "$card" sget 'PCM',1 2>&1 | tail -n 4 || true
  else warn "ALSA: placa $CARD_NAME não encontrada"; fi
  [ -f "$UDEV_RULE_FILE" ] && log "udev: $UDEV_RULE_FILE OK" || warn "udev: $UDEV_RULE_FILE ausente"
  if [ -f "$WP_SYS_FILE" ]; then log "wireplumber(sys): $WP_SYS_FILE OK"
  elif [ -f "$WP_USER_FILE" ]; then log "wireplumber(user): $WP_USER_FILE OK"
  else warn "wireplumber: conf do Fuxi-H3 ausente"; fi
  pactl list short sinks 2>/dev/null | grep -i -e fuxi -e xiiSound | head -n 3 || warn "pactl: nenhum sink Fuxi"
}

do_uninstall() {
  log "Removendo correção Fuxi-H3..."
  for f in "$UDEV_RULE_FILE"; do
    if [ -f "$f" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] remover %s\n' "$f"
      elif [ -w "$(dirname "$f")" ]; then run rm -f "$f" && log "removido: $f"
      elif priv rm -f "$f"; then log "removido: $f"
      else warn "sem permissão para remover $f (rode com sudo)"; fi
    else log "ausente (ok): $f"; fi
  done
  for f in "$WP_SYS_FILE" "$WP_USER_FILE"; do
    if [ -f "$f" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] remover %s\n' "$f"
      elif [ -w "$f" ] || [ -w "$(dirname "$f")" ]; then run rm -f "$f" && log "removido: $f"
      elif priv rm -f "$f" 2>/dev/null; then log "removido: $f"
      else warn "mantido (sem permissão): $f"; fi
    fi
  done
  run udevadm control --reload-rules 2>/dev/null || priv udevadm control --reload-rules 2>/dev/null || true
  restart_audio
  log "Desinstalação concluída."
}

main() {
  distro="$(detect_distro)"
  log "Fuxi-H3 fix — distro: $distro (testado em Fedora, Ubuntu e Arch)"
  check_deps || true
  if [ "$DO_UNINSTALL" -eq 1 ]; then do_uninstall; exit 0; fi
  if [ "$DO_CHECK" -eq 1 ]; then do_check; exit 0; fi

  if ! dongle_present; then
    warn "dongle $VENDOR:$PRODUCT não detectado agora; vou instalar a correção persistente mesmo assim."
    if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
      printf 'Continuar? [S/n] '; read -r ans
      case "$ans" in [nN]*) exit 1 ;; esac
    fi
  fi
  card="$(find_card || true)"
  [ -z "$card" ] && card="$CARD_NAME"
  log "Usando placa ALSA: $card"

  log "[1/5] Ajuste imediato ALSA..."
  run amixer -c "$card" sset 'PCM',0 100% unmute >/dev/null 2>&1 || warn "PCM,0 indisponível"
  run amixer -c "$card" sset 'PCM',1 100% unmute >/dev/null 2>&1 || warn "PCM,1 indisponível (normal se o dongle só expõe um controle)"
  run alsactl store 2>/dev/null || priv alsactl store 2>/dev/null || warn "alsactl store falhou (sem sudo?)"

  log "[2/5] Regra udev ($UDEV_RULE_FILE)..."
  want_rule="$(udev_rule_content)"
  if [ -f "$UDEV_RULE_FILE" ] && [ "$(cat "$UDEV_RULE_FILE" 2>/dev/null)" = "$want_rule" ]; then
    log "udev: já instalada e atualizada."
  elif [ -f "$UDEV_RULE_FILE" ] && grep -q "$VENDOR.*$PRODUCT" "$UDEV_RULE_FILE" 2>/dev/null; then
    if printf '%s\n' "$want_rule" | write_file_priv "$UDEV_RULE_FILE"; then
      log "udev: atualizada para o novo formato."
    else
      warn "regra existente mantida (formato antigo, funcional); rode com sudo para atualizar: sudo $0"
    fi
  else
    if printf '%s\n' "$want_rule" | write_file_priv "$UDEV_RULE_FILE"; then
      log "udev: instalada."
    else
      err "sem permissão em $UDEV_RULE_FILE. Rode com sudo: sudo $0"
      exit 1
    fi
  fi
  run udevadm control --reload-rules 2>/dev/null || priv udevadm control --reload-rules 2>/dev/null || warn "udevadm reload falhou"
  if dongle_present; then
    run udevadm trigger --action=add --subsystem-match=sound 2>/dev/null \
      || priv udevadm trigger --action=add --subsystem-match=sound 2>/dev/null \
      || warn "udevadm trigger falhou (replugue o dongle uma vez)"
  fi

  log "[3/5] WirePlumber soft-mixer..."
  if command -v wireplumber >/dev/null 2>&1 || [ -d /etc/wireplumber ] || [ -d "$HOME/.config/wireplumber" ]; then
    dest="$WP_SYS_FILE"
    mkdir_cmd=""
    if [ -w "$WP_SYS_DIR" ]; then dest="$WP_SYS_FILE"
    elif priv test -w "$WP_SYS_DIR" 2>/dev/null || priv mkdir -p "$WP_SYS_DIR" 2>/dev/null; then dest="$WP_SYS_FILE"
    else
      dest="$WP_USER_FILE"
      mkdir_cmd="mkdir -p $WP_USER_DIR"
    fi
    if [ -n "$mkdir_cmd" ]; then run mkdir -p "$WP_USER_DIR" || true; fi
    want_wp="$(wp_conf_content)"
    if [ -f "$dest" ] && [ "$(cat "$dest" 2>/dev/null)" = "$want_wp" ]; then
      log "wireplumber: $dest já atualizado."
    elif printf '%s\n' "$want_wp" | write_file_priv "$dest"; then
      log "wireplumber: $dest OK"
    else warn "não foi possível escrever $dest"; fi
  else
    warn "WirePlumber não detectado; pulando soft-mixer (correção ALSA+udev continua valendo)."
  fi

  log "[4/5] Reiniciando áudio (user)..."
  restart_audio

  log "[5/5] Sink padrão + volume $VOLUME..."
  set_default_sink

  log "=== verificação ==="
  do_check
  log "Pronto. Se ainda estiver mudo: desplugue do hub USB e ligue direto na porta traseira, confira o botão mute do dongle e reencaixe o P2 até o clique."
}

main "$@"
