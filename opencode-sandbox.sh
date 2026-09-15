#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# OpenCode Sandbox
#
# Uso:
#   ./opencode-sandbox.sh portfolio
#   ./opencode-sandbox.sh portfolio 3000
#
# Lifecycle:
#   ./opencode-sandbox.sh status portfolio
#   ./opencode-sandbox.sh stop portfolio
#   ./opencode-sandbox.sh recreate portfolio 3000
#   ./opencode-sandbox.sh purge portfolio
#   ./opencode-sandbox.sh doctor
#   ./opencode-sandbox.sh cleanup
#
# Overrides:
#   MSB_MEMORY=6G MSB_CPUS=4 ./opencode-sandbox.sh portfolio 3000
#
# Política:
#
#   projects/<project>        -> código persistente
#   .bun/                     -> Bun/OpenCode compartilhados
#   state/opencode/<project>  -> sessões/config/cache isolados
#
# stop:
#   mantém VM + state + sessões
#
# recreate:
#   recria somente a VM
#   mantém state + sessões
#
# purge:
#   remove VM + state + sessões
#   mantém código + Bun + chave do .env
#
# doctor:
#   somente leitura; mostra RAM/disco/VMs/caches
#
# cleanup:
#   limpa cache de pacotes do Bun
#   limpa cache reconstruível do microsandbox somente sem VMs registradas
#   preserva projetos, state, toolchains e autenticação
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Aceita o nome antigo que já usamos e também o nome oficial.
#
# Preferência:
#   OPENCODE_API_KEY
# fallback:
#   OPENCODE_ZEN_KEY
#
# Dentro da VM SEMPRE será OPENCODE_API_KEY.
OPENCODE_API_KEY_EFFECTIVE="${OPENCODE_API_KEY:-${OPENCODE_ZEN_KEY:-}}"

# ------------------------------------------------------------
# Action
# ------------------------------------------------------------

ACTION="run"

case "${1:-}" in
  run|status|stop|recreate|purge|doctor|cleanup|help)
    ACTION="$1"
    shift
    ;;

  rm)
    echo "O comando 'rm' foi removido por segurança." >&2
    echo >&2
    echo "Use:" >&2
    echo "  stop      -> preservar sessão" >&2
    echo "  recreate  -> recriar VM preservando sessão" >&2
    echo "  purge     -> apagar definitivamente o state" >&2
    echo "  doctor    -> diagnosticar uso de disco/RAM/caches" >&2
    echo "  cleanup   -> limpar caches compartilhados seguros" >&2
    exit 1
    ;;
esac

RAW_PROJECT_NAME="${1:-app}"
PROJECT_NAME="${RAW_PROJECT_NAME#opencode-}"
HOST_PORT="${2:-3000}"

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Erro: nome de projeto inválido: $PROJECT_NAME" >&2
  echo "Use somente letras, números, '.', '_' e '-'." >&2
  exit 1
fi

if [[ ! "$HOST_PORT" =~ ^[0-9]+$ ]] ||
   (( HOST_PORT < 1 || HOST_PORT > 65535 )); then

  echo "Erro: porta inválida: $HOST_PORT" >&2
  exit 1
fi

if [[ "$ACTION" == "run" || "$ACTION" == "recreate" ]]; then
  if [[ -z "$OPENCODE_API_KEY_EFFECTIVE" ]]; then
    echo "Erro: nenhuma chave do OpenCode Zen foi encontrada." >&2
    echo >&2
    echo "Defina uma destas variáveis em:" >&2
    echo "  $ENV_FILE" >&2
    echo >&2
    echo "  OPENCODE_API_KEY=..." >&2
    echo >&2
    echo "ou mantenha a compatibilidade atual:" >&2
    echo >&2
    echo "  OPENCODE_ZEN_KEY=..." >&2
    exit 1
  fi
fi

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

VM_NAME="opencode-$PROJECT_NAME"

BASE_DIR="$HOME/sandboxes/agent"

PROJECT_DIR="$BASE_DIR/projects/$PROJECT_NAME"

PROJECT_STATE="$BASE_DIR/state/opencode/$PROJECT_NAME"

PROJECT_CONFIG="$PROJECT_STATE/.config"
PROJECT_LOCAL="$PROJECT_STATE/.local"
PROJECT_CACHE="$PROJECT_STATE/.cache"

# Bun + OpenCode CLI compartilhados entre VMs.
# Sessões NÃO ficam aqui.
SHARED_BUN="$BASE_DIR/.bun"

# ------------------------------------------------------------
# VM config
# ------------------------------------------------------------

CPUS="${MSB_CPUS:-4}"
MEMORY="${MSB_MEMORY:-4G}"

CONTAINER_PORT="3000"

IMAGE="oven/bun:1-debian"

CUSTOM_PATH="/root/.bun/install/global/node_modules/.bin:/root/.bun/install/global/node_modules/opencode-linux-x64/bin:/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

vm_exists() {
  msb list 2>/dev/null | awk -v name="$VM_NAME" '
    NR > 1 && $1 == name { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

show_vm() {
  msb list 2>/dev/null | awk -v name="$VM_NAME" '
    NR == 1 || $1 == name
  '
}

remove_vm() {
  if ! vm_exists; then
    echo "VM não encontrada: $VM_NAME"
    return 0
  fi

  echo "Removendo VM: $VM_NAME"

  # Parar antes de remover torna o comportamento previsível entre
  # VMs running e stopped. Falha ao parar uma VM já parada é aceitável.
  msb stop "$VM_NAME" >/dev/null 2>&1 || true

  # Não esconda falhas de remoção. O antigo `|| true` fazia o script
  # anunciar sucesso mesmo quando a VM permanecia em `msb list`.
  if ! msb rm "$VM_NAME"; then
    echo "ERRO: msb não conseguiu remover a VM: $VM_NAME" >&2
    return 1
  fi

  if vm_exists; then
    echo "ERRO: a VM ainda existe após a remoção: $VM_NAME" >&2
    return 1
  fi

  echo "VM removida: $VM_NAME"
}

remove_state() {
  case "$PROJECT_STATE" in
    "$BASE_DIR/state/opencode/"*)
      if [[ -d "$PROJECT_STATE" ]]; then
        echo "Removendo state:"
        echo "  $PROJECT_STATE"

        rm -rf -- "$PROJECT_STATE"
      fi
      ;;

    *)
      echo "ERRO: caminho inseguro:" >&2
      echo "  $PROJECT_STATE" >&2
      exit 1
      ;;
  esac
}

# ------------------------------------------------------------
# Storage hygiene
# ------------------------------------------------------------

MICROSANDBOX_DIR="$HOME/.microsandbox"
MICROSANDBOX_CACHE="$MICROSANDBOX_DIR/cache"
BUN_CACHE="$BASE_DIR/.bun/install/cache"

# Alert thresholds. Override per invocation if desired:
#   BUN_CACHE_WARN_GB=8 MSB_CACHE_WARN_GB=8 ./... doctor
BUN_CACHE_WARN_GB="${BUN_CACHE_WARN_GB:-5}"
MSB_CACHE_WARN_GB="${MSB_CACHE_WARN_GB:-5}"

dir_kb() {
  local path="$1"

  if [[ -e "$path" ]]; then
    du -sk "$path" 2>/dev/null | awk '{print $1}'
  else
    echo 0
  fi
}

human_kb() {
  local kb="${1:-0}"

  awk -v kb="$kb" '
    BEGIN {
      if (kb >= 1024 * 1024) {
        printf "%.1f GiB", kb / (1024 * 1024)
      } else if (kb >= 1024) {
        printf "%.1f MiB", kb / 1024
      } else {
        printf "%d KiB", kb
      }
    }
  '
}

has_any_vm() {
  msb list 2>/dev/null | awk '
    NR > 1 && NF > 0 && $1 != "No" { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

warn_dir_size() {
  local label="$1"
  local path="$2"
  local limit_gb="$3"
  local kb
  local limit_kb

  kb="$(dir_kb "$path")"
  limit_kb=$(( limit_gb * 1024 * 1024 ))

  if (( kb >= limit_kb )); then
    echo
    echo "AVISO DE DISCO:"
    echo "  $label: $(human_kb "$kb")"
    echo "  caminho: $path"
    echo "  limite:  ${limit_gb} GiB"
    echo
    echo "Use:"
    echo "  $0 doctor"
    echo "  $0 cleanup"
    echo
  fi
}

warn_storage() {
  warn_dir_size "cache compartilhado do Bun" "$BUN_CACHE" "$BUN_CACHE_WARN_GB"
  warn_dir_size "cache do microsandbox" "$MICROSANDBOX_CACHE" "$MSB_CACHE_WARN_GB"
}

doctor_report() {
  echo
  echo "=== SANDBOX DOCTOR ==="
  echo

  echo "--- Disco ---"
  df -h / 2>/dev/null || true

  echo
  echo "--- RAM ---"
  free -h 2>/dev/null || true

  echo
  echo "--- Microsandbox VMs ---"
  msb list 2>/dev/null || true

  echo
  echo "--- Uso do ambiente ---"
  printf "%-32s %s\n" "sandboxes:" "$(human_kb "$(dir_kb "$HOME/sandboxes")")"
  printf "%-32s %s\n" "projects:" "$(human_kb "$(dir_kb "$BASE_DIR/projects")")"
  printf "%-32s %s\n" "state:" "$(human_kb "$(dir_kb "$BASE_DIR/state")")"
  printf "%-32s %s\n" "Bun compartilhado:" "$(human_kb "$(dir_kb "$BASE_DIR/.bun")")"
  printf "%-32s %s\n" "cache Bun:" "$(human_kb "$(dir_kb "$BUN_CACHE")")"
  printf "%-32s %s\n" "Codex global:" "$(human_kb "$(dir_kb "$BASE_DIR/.npm-global")")"
  printf "%-32s %s\n" "microsandbox:" "$(human_kb "$(dir_kb "$MICROSANDBOX_DIR")")"
  printf "%-32s %s\n" "cache microsandbox:" "$(human_kb "$(dir_kb "$MICROSANDBOX_CACHE")")"

  warn_storage
}

clear_dir_contents() {
  local path="$1"

  [[ -d "$path" ]] || return 0

  # find evita problemas de glob com diretórios vazios e arquivos ocultos.
  find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

cleanup_shared_caches() {
  local before_bun
  local before_msb
  local after_bun
  local after_msb
  local freed_kb

  before_bun="$(dir_kb "$BUN_CACHE")"
  before_msb="$(dir_kb "$MICROSANDBOX_CACHE")"

  echo
  echo "CLEANUP DE CACHES COMPARTILHADOS"
  echo
  echo "Preservado:"
  echo "  projetos"
  echo "  state/sessões dos projetos"
  echo "  Bun/OpenCode instalados globalmente"
  echo "  Codex instalado globalmente"
  echo "  autenticação"
  echo

  if [[ -d "$BUN_CACHE" ]]; then
    echo "Limpando cache de pacotes do Bun:"
    echo "  $BUN_CACHE"
    clear_dir_contents "$BUN_CACHE"
  else
    echo "Cache do Bun não existe."
  fi

  echo

  # Layers podem estar referenciadas por VMs paradas. Só removemos cache
  # do microsandbox quando não existe nenhuma VM registrada.
  if has_any_vm; then
    echo "Cache do microsandbox NÃO foi apagado."
    echo "Motivo: existem VMs registradas em 'msb list'."
    echo "Remova/purge VMs que não usa e execute cleanup novamente."
  elif [[ -d "$MICROSANDBOX_CACHE" ]]; then
    echo "Nenhuma VM registrada."
    echo "Limpando cache reconstruível do microsandbox:"
    echo "  $MICROSANDBOX_CACHE"
    clear_dir_contents "$MICROSANDBOX_CACHE"
  else
    echo "Cache do microsandbox não existe."
  fi

  after_bun="$(dir_kb "$BUN_CACHE")"
  after_msb="$(dir_kb "$MICROSANDBOX_CACHE")"

  freed_kb=$(( before_bun + before_msb - after_bun - after_msb ))
  if (( freed_kb < 0 )); then
    freed_kb=0
  fi

  echo
  echo "Espaço liberado nesta limpeza: $(human_kb "$freed_kb")"
  echo
  df -h / 2>/dev/null || true
  echo
}

# ------------------------------------------------------------
# Administrative actions
# ------------------------------------------------------------

case "$ACTION" in

  help)
    echo "Uso:"
    echo "  $0 <projeto> [portas...]"
    echo "  $0 run <projeto> [portas...]"
    echo "  $0 status <projeto>"
    echo "  $0 stop <projeto>"
    echo "  $0 recreate <projeto> [portas...]"
    echo "  $0 purge <projeto>"
    echo "  $0 doctor"
    echo "  $0 cleanup"
    echo
    echo "Política:"
    echo "  stop      preserva VM/state/sessões"
    echo "  recreate  recria a VM e preserva state/sessões"
    echo "  purge     remove VM + state do projeto; preserva código/toolchain/auth"
    echo "  doctor    somente leitura; mostra RAM, disco, VMs e caches"
    echo "  cleanup   remove caches reconstruíveis; não remove projetos/auth/toolchain"
    exit 0
    ;;

  doctor)
    doctor_report
    exit 0
    ;;

  cleanup)
    cleanup_shared_caches
    exit 0
    ;;

  status)
    if vm_exists; then
      show_vm
    else
      echo "VM não encontrada: $VM_NAME"
    fi

    exit 0
    ;;

  stop)
    if vm_exists; then
      echo "Parando VM: $VM_NAME"
      msb stop "$VM_NAME"

      echo
      echo "State preservado:"
      echo "  $PROJECT_STATE"
    else
      echo "VM não encontrada: $VM_NAME"
    fi

    exit 0
    ;;

  purge)
    echo
    echo "PURGE: $PROJECT_NAME"
    echo "VM:    $VM_NAME"
    echo

    remove_vm
    remove_state

    if vm_exists; then
      echo "ERRO: purge abortado; a VM ainda existe: $VM_NAME" >&2
      exit 1
    fi

    echo
    echo "Removido:"
    echo "  VM: $VM_NAME"
    echo "  sessões"
    echo "  config/cache daquele agente"
    echo
    echo "Preservado:"
    echo "  código: $PROJECT_DIR"
    echo "  Bun:    $SHARED_BUN"
    echo "  chave:  $ENV_FILE"
    echo

    warn_storage

    exit 0
    ;;

  recreate)
    echo
    echo "Recriando VM preservando state..."
    echo
    echo "State:"
    echo "  $PROJECT_STATE"
    echo

    remove_vm
    ;;
esac

# ------------------------------------------------------------
# Persistent directories
# ------------------------------------------------------------

mkdir -p \
  "$PROJECT_DIR" \
  "$PROJECT_CONFIG" \
  "$PROJECT_LOCAL/share" \
  "$PROJECT_LOCAL/state" \
  "$PROJECT_CACHE" \
  "$SHARED_BUN"

# ------------------------------------------------------------
# Existing VM
# ------------------------------------------------------------

if vm_exists; then
  echo "Iniciando sandbox existente: $VM_NAME"

  if ! msb start "$VM_NAME" >/dev/null 2>&1; then
    echo "VM não iniciou."
    echo "Recriando definição da VM, preservando state..."

    remove_vm
  fi
fi

if vm_exists; then
  warn_storage
  exec msb exec "$VM_NAME" -- /bin/bash
fi

# ------------------------------------------------------------
# New VM
# ------------------------------------------------------------

warn_storage

echo
echo "Criando sandbox: $VM_NAME"
echo
echo "Projeto: $PROJECT_DIR"
echo "State:   $PROJECT_STATE"
echo "CPU:     $CPUS"
echo "Memória: $MEMORY"
echo "Porta:   localhost:$HOST_PORT -> VM:$CONTAINER_PORT"
echo "Auth:    OPENCODE_API_KEY carregada"
echo

msb run \
  -n "$VM_NAME" \
  -c "$CPUS" \
  -m "$MEMORY" \
  -p "$HOST_PORT:$CONTAINER_PORT" \
  -v "$PROJECT_DIR:/workspace" \
  -v "$SHARED_BUN:/root/.bun" \
  -v "$PROJECT_CONFIG:/root/.config" \
  -v "$PROJECT_LOCAL:/root/.local" \
  -v "$PROJECT_CACHE:/root/.cache" \
  -w /workspace \
  -e TERM=xterm-256color \
  -e LANG=C.UTF-8 \
  -e LC_ALL=C.UTF-8 \
  -e PAGER=cat \
  -e GIT_PAGER=cat \
  -e BUN_INSTALL=/root/.bun \
  -e XDG_CONFIG_HOME=/root/.config \
  -e XDG_DATA_HOME=/root/.local/share \
  -e XDG_STATE_HOME=/root/.local/state \
  -e XDG_CACHE_HOME=/root/.cache \
  -e PATH="$CUSTOM_PATH" \
  -e OPENCODE_API_KEY="$OPENCODE_API_KEY_EFFECTIVE" \
  "$IMAGE" \
  -- /bin/bash -c '
    set -Eeuo pipefail

    mkdir -p \
      /root/.config \
      /root/.local/share \
      /root/.local/state \
      /root/.cache

    # --------------------------------------------------------
    # Base development tools
    # --------------------------------------------------------

    if ! command -v git >/dev/null 2>&1 ||
       ! command -v less >/dev/null 2>&1; then

    apt-get update -qq

    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq \
      ca-certificates \
      git \
      less \
      >/dev/null
    fi

    # --------------------------------------------------------
    # OpenCode installation
    #
    # /root/.bun é persistente, então normalmente isso só
    # acontece na primeira execução.
    # --------------------------------------------------------

    if ! command -v opencode >/dev/null 2>&1; then
      echo "OpenCode não encontrado. Instalando com Bun..."

      bun install -g opencode-ai
    fi

    # --------------------------------------------------------
    # Authentication
    #
    # Não executamos opencode auth login.
    #
    # O provider interno "opencode" lê OPENCODE_API_KEY
    # diretamente do ambiente.
    # --------------------------------------------------------

    if [[ -z "${OPENCODE_API_KEY:-}" ]]; then
      echo "ERRO: OPENCODE_API_KEY não chegou à VM." >&2
      exit 1
    fi

    cd /workspace

    exec /bin/bash
  '
