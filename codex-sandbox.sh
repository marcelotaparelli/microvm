#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Codex Sandbox
#
# Uso:
#   ./codex-sandbox.sh portfolio
#
# Portas:
#   ./codex-sandbox.sh portfolio 3000 8000 8080
#
# Lifecycle:
#   ./codex-sandbox.sh status portfolio
#   ./codex-sandbox.sh stop portfolio
#   ./codex-sandbox.sh recreate portfolio 3000 8000 8080
#   ./codex-sandbox.sh purge portfolio
#   ./codex-sandbox.sh doctor
#   ./codex-sandbox.sh cleanup
#
# Overrides:
#   MSB_MEMORY=6G MSB_CPUS=4 ./codex-sandbox.sh portfolio
#
# Política:
#
#   projects/<project>      -> código
#   .npm-global/            -> Codex CLI
#   shared/codex-auth/      -> autenticação compartilhável
#   state/codex/<project>   -> sessão/config/cache isolados
#
# stop:
#   mantém tudo
#
# recreate:
#   recria VM
#   mantém state/sessões/auth
#
# purge:
#   apaga VM + state do projeto
#   mantém código + Codex CLI + auth
#
# doctor:
#   somente leitura; mostra RAM/disco/VMs/caches
#
# cleanup:
#   limpa cache compartilhado do Bun, se existir
#   limpa cache reconstruível do microsandbox somente sem VMs registradas
#   preserva projetos, state, toolchains e autenticação
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

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
  run|status|stop|recreate|purge|doctor|cleanup|help)
    ACTION="$1"
    shift
    ;;

  rm)
    echo "O comando 'rm' foi removido por segurança." >&2
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
PROJECT_NAME="${RAW_PROJECT_NAME#codex-}"

HOST_PORT_3000="${2:-3000}"
HOST_PORT_8000="${3:-8000}"
HOST_PORT_HTTP="${4:-8080}"

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Erro: nome de projeto inválido: $PROJECT_NAME" >&2
  exit 1
fi

validate_port() {
  local port="$1"

  if [[ ! "$port" =~ ^[0-9]+$ ]] ||
     (( port < 1 || port > 65535 )); then

    echo "Erro: porta inválida: $port" >&2
    exit 1
  fi
}

validate_port "$HOST_PORT_3000"
validate_port "$HOST_PORT_8000"
validate_port "$HOST_PORT_HTTP"

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

VM_NAME="codex-$PROJECT_NAME"

BASE_DIR="$HOME/sandboxes/agent"

PROJECT_DIR="$BASE_DIR/projects/$PROJECT_NAME"

PROJECT_STATE="$BASE_DIR/state/codex/$PROJECT_NAME"

CODEX_DIR="$PROJECT_STATE/.codex"
CONFIG_DIR="$PROJECT_STATE/.config"
LOCAL_DIR="$PROJECT_STATE/.local"
CACHE_DIR="$PROJECT_STATE/.cache"

NPM_GLOBAL="$BASE_DIR/.npm-global"

CODEX_SHARED_AUTH="$BASE_DIR/shared/codex-auth"
SHARED_AUTH_FILE="$CODEX_SHARED_AUTH/auth.json"

# ------------------------------------------------------------
# Resources
# ------------------------------------------------------------

CPUS="${MSB_CPUS:-4}"
MEMORY="${MSB_MEMORY:-4G}"

IMAGE="node:22-bookworm-slim"

CUSTOM_PATH="/usr/local/bin:/root/.npm-global/bin:/usr/local/sbin:/usr/bin:/sbin:/bin"

# ------------------------------------------------------------
# Autodeploy
# ------------------------------------------------------------

AUTODEPLOY_SOURCE="$HOME/evag/websites/autodeploy"

if [[ -d "$AUTODEPLOY_SOURCE" ]]; then
  AUTODEPLOY_DIR="$(cd "$AUTODEPLOY_SOURCE" && pwd -P)"
else
  echo "Aviso: autodeploy não encontrado:"
  echo "  $AUTODEPLOY_SOURCE"

  AUTODEPLOY_DIR=""
fi

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
    "$BASE_DIR/state/codex/"*)
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
    echo "  sessões/config/cache do projeto"
    echo
    echo "Preservado:"
    echo "  código: $PROJECT_DIR"
    echo "  Codex:  $NPM_GLOBAL"
    echo "  auth:   $CODEX_SHARED_AUTH"
    echo

    warn_storage

    exit 0
    ;;

  recreate)
    echo
    echo "Recriando VM preservando state e auth..."
    echo
    echo "State:"
    echo "  $PROJECT_STATE"
    echo

    remove_vm
    ;;
esac

# ------------------------------------------------------------
# Directories
# ------------------------------------------------------------

mkdir -p \
  "$PROJECT_DIR" \
  "$CODEX_DIR" \
  "$CONFIG_DIR" \
  "$LOCAL_DIR/share" \
  "$LOCAL_DIR/state" \
  "$CACHE_DIR" \
  "$NPM_GLOBAL" \
  "$CODEX_SHARED_AUTH"

# ------------------------------------------------------------
# Migrate legacy Codex auth if it still exists
# ------------------------------------------------------------

OLD_CODEX_AUTH="$BASE_DIR/.codex/auth.json"

if [[ ! -f "$SHARED_AUTH_FILE" ]] &&
   [[ -f "$OLD_CODEX_AUTH" ]]; then

  echo "Migrando autenticação Codex antiga..."

  cp "$OLD_CODEX_AUTH" "$SHARED_AUTH_FILE"
  chmod 600 "$SHARED_AUTH_FILE"

  echo "Auth salva em:"
  echo "  $SHARED_AUTH_FILE"
  echo
fi

# ------------------------------------------------------------
# Existing VM
# ------------------------------------------------------------

if vm_exists; then
  echo "Iniciando sandbox existente: $VM_NAME"

  if ! msb start "$VM_NAME" >/dev/null 2>&1; then
    echo "VM não iniciou."
    echo "Recriando definição, preservando state..."

    remove_vm
  fi
fi

if vm_exists; then
  warn_storage
  exec msb exec "$VM_NAME" -- /bin/bash
fi

# ------------------------------------------------------------
# Mounts
# ------------------------------------------------------------

MOUNTS=(
  -v "$PROJECT_DIR:/workspace"
  -v "$NPM_GLOBAL:/root/.npm-global"

  -v "$CONFIG_DIR:/root/.config"
  -v "$LOCAL_DIR:/root/.local"
  -v "$CACHE_DIR:/root/.cache"
  -v "$CODEX_DIR:/root/.codex"

  -v "$CODEX_SHARED_AUTH:/shared/codex-auth"
)

if [[ -n "$AUTODEPLOY_DIR" ]]; then
  MOUNTS+=(
    -v "$AUTODEPLOY_DIR:/autodeploy"
  )
fi

# ------------------------------------------------------------
# New VM
# ------------------------------------------------------------

warn_storage

echo
echo "Criando sandbox: $VM_NAME"
echo
echo "Projeto:    $PROJECT_DIR"
echo "State:      $PROJECT_STATE"
echo "Auth Codex: $CODEX_SHARED_AUTH"
echo "CPU:        $CPUS"
echo "Memória:    $MEMORY"
echo
echo "Portas:"
echo "  localhost:$HOST_PORT_3000 -> VM:3000"
echo "  localhost:$HOST_PORT_8000 -> VM:8000"
echo "  localhost:$HOST_PORT_HTTP -> VM:80"
echo

if [[ -n "$AUTODEPLOY_DIR" ]]; then
  echo "Autodeploy:"
  echo "  $AUTODEPLOY_DIR -> /autodeploy"
  echo
fi

msb run \
  -n "$VM_NAME" \
  -c "$CPUS" \
  -m "$MEMORY" \
  -p "$HOST_PORT_3000:3000" \
  -p "$HOST_PORT_8000:8000" \
  -p "$HOST_PORT_HTTP:80" \
  "${MOUNTS[@]}" \
  -w /workspace \
  -e TERM=xterm-256color \
  -e PATH="$CUSTOM_PATH" \
  -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
  -e NPM_CONFIG_PREFIX=/root/.npm-global \
  -e XDG_CONFIG_HOME=/root/.config \
  -e XDG_DATA_HOME=/root/.local/share \
  -e XDG_STATE_HOME=/root/.local/state \
  -e XDG_CACHE_HOME=/root/.cache \
  "$IMAGE" \
  -- /bin/bash -c '
    set -Eeuo pipefail

    mkdir -p \
      /root/.config \
      /root/.local/share \
      /root/.local/state \
      /root/.cache \
      /root/.codex \
      /shared/codex-auth

    # --------------------------------------------------------
    # System dependencies
    # --------------------------------------------------------

    if ! command -v bwrap >/dev/null 2>&1; then
      apt-get update -qq

      apt-get install -y -qq \
        ca-certificates \
        bubblewrap \
        >/dev/null
    fi

    # --------------------------------------------------------
    # Codex CLI
    # --------------------------------------------------------

    if [[ ! -x /root/.npm-global/bin/codex ]]; then
      npm install -g @openai/codex
    fi

    # --------------------------------------------------------
    # Codex wrapper
    #
    # State remains project-local.
    # shared auth is only used as credential synchronization.
    # --------------------------------------------------------

    cat >/usr/local/bin/codex <<'"'"'WRAPPER'"'"'
#!/usr/bin/env bash

set -Eeuo pipefail

REAL_CODEX="/root/.npm-global/bin/codex"

PROJECT_AUTH="/root/.codex/auth.json"

SHARED_AUTH_DIR="/shared/codex-auth"
SHARED_AUTH="$SHARED_AUTH_DIR/auth.json"

mkdir -p \
  /root/.codex \
  "$SHARED_AUTH_DIR"

# ------------------------------------------------------------
# Import auth only when necessary.
#
# If shared auth is newer than project auth, use it.
# Otherwise preserve the projects fresher credentials.
# ------------------------------------------------------------

if [[ -f "$SHARED_AUTH" ]]; then

  if [[ ! -f "$PROJECT_AUTH" ]] ||
     [[ "$SHARED_AUTH" -nt "$PROJECT_AUTH" ]]; then

    cp "$SHARED_AUTH" "$PROJECT_AUTH"
    chmod 600 "$PROJECT_AUTH" || true

  fi
fi

# ------------------------------------------------------------
# Run real Codex
# ------------------------------------------------------------

set +e

"$REAL_CODEX" "$@"

STATUS=$?

set -e

# ------------------------------------------------------------
# Export refreshed auth.
#
# Only update shared auth when project auth is newer.
# Atomic rename prevents partial auth files.
# ------------------------------------------------------------

if [[ -f "$PROJECT_AUTH" ]]; then

  if [[ ! -f "$SHARED_AUTH" ]] ||
     [[ "$PROJECT_AUTH" -nt "$SHARED_AUTH" ]]; then

    TMP_AUTH="$SHARED_AUTH.tmp.$$"

    cp "$PROJECT_AUTH" "$TMP_AUTH"

    chmod 600 "$TMP_AUTH" || true

    mv "$TMP_AUTH" "$SHARED_AUTH"

  fi
fi

exit "$STATUS"
WRAPPER

    chmod 755 /usr/local/bin/codex

    cd /workspace

    exec /bin/bash
  '
