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
#   mantém tudo
#
# recreate:
#   remove e recria somente a VM
#   mantém state/sessões
#
# purge:
#   remove VM + state/sessões
#   mantém código + Bun + chave no .env
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

# ------------------------------------------------------------
# Action
# ------------------------------------------------------------

ACTION="run"

case "${1:-}" in
  run|status|stop|recreate|purge)
    ACTION="$1"
    shift
    ;;

  rm)
    echo "O comando 'rm' foi removido por segurança." >&2
    echo "Use:" >&2
    echo "  stop      -> preservar sessão" >&2
    echo "  recreate  -> recriar VM preservando sessão" >&2
    echo "  purge     -> apagar definitivamente o state" >&2
    exit 1
    ;;
esac

PROJECT_NAME="${1:-app}"
HOST_PORT="${2:-3000}"

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Erro: nome de projeto inválido: $PROJECT_NAME" >&2
  exit 1
fi

if [[ ! "$HOST_PORT" =~ ^[0-9]+$ ]] ||
   (( HOST_PORT < 1 || HOST_PORT > 65535 )); then
  echo "Erro: porta inválida: $HOST_PORT" >&2
  exit 1
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

SHARED_BUN="$BASE_DIR/.bun"

# ------------------------------------------------------------
# VM config
# ------------------------------------------------------------

CPUS="${MSB_CPUS:-4}"
MEMORY="${MSB_MEMORY:-4G}"

CONTAINER_PORT="3000"

IMAGE="oven/bun:1-debian"

CUSTOM_PATH="/root/.bun/install/global/node_modules/.bin:/root/.bun/install/global/node_modules/opencode-linux-x64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

vm_exists() {
  msb list 2>/dev/null | grep -Fq "$VM_NAME"
}

remove_vm() {
  if vm_exists; then
    echo "Removendo VM: $VM_NAME"
    msb rm -f "$VM_NAME" >/dev/null 2>&1 || true
  fi
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
      echo "$PROJECT_STATE" >&2
      exit 1
      ;;
  esac
}

# ------------------------------------------------------------
# Administrative actions
# ------------------------------------------------------------

case "$ACTION" in

  status)
    if vm_exists; then
      msb list | grep -F "$VM_NAME" || true
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
    echo

    remove_vm
    remove_state

    echo
    echo "Removido:"
    echo "  VM"
    echo "  sessões"
    echo "  config/cache daquele agente"
    echo
    echo "Preservado:"
    echo "  código: $PROJECT_DIR"
    echo "  Bun:    $SHARED_BUN"
    echo "  .env:   $ENV_FILE"
    echo

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
# OpenCode authentication
# ------------------------------------------------------------

if [[ -z "${OPENCODE_ZEN_KEY:-}" ]]; then
  echo "Aviso: OPENCODE_ZEN_KEY não definida em:"
  echo "  $ENV_FILE"
  echo
fi

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
  exec msb exec "$VM_NAME" -- /bin/bash
fi

# ------------------------------------------------------------
# New VM
# ------------------------------------------------------------

echo
echo "Criando sandbox: $VM_NAME"
echo
echo "Projeto: $PROJECT_DIR"
echo "State:   $PROJECT_STATE"
echo "CPU:     $CPUS"
echo "Memória: $MEMORY"
echo "Porta:   localhost:$HOST_PORT -> VM:$CONTAINER_PORT"
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
  -e BUN_INSTALL=/root/.bun \
  -e XDG_CONFIG_HOME=/root/.config \
  -e XDG_DATA_HOME=/root/.local/share \
  -e XDG_STATE_HOME=/root/.local/state \
  -e XDG_CACHE_HOME=/root/.cache \
  -e PATH="$CUSTOM_PATH" \
  -e OPENCODE_ZEN_KEY="${OPENCODE_ZEN_KEY:-}" \
  "$IMAGE" \
  -- /bin/bash -c '
    set -Eeuo pipefail

    mkdir -p \
      /root/.config \
      /root/.local/share \
      /root/.local/state \
      /root/.cache

    if [[ -n "${OPENCODE_ZEN_KEY:-}" ]]; then
      if ! opencode auth login \
        --provider opencode-zen \
        --api-key "$OPENCODE_ZEN_KEY" \
        >/dev/null 2>&1; then

        echo "Aviso: login automático do OpenCode falhou." >&2
      fi
    fi

    cd /workspace

    exec /bin/bash
  '
