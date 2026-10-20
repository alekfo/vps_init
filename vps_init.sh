#!/usr/bin/env bash
# vps_init.sh — первичная настройка Linux-машины (Ubuntu/Debian, amd64/arm64).
#
# Запуск:   sudo ./vps_init.sh [-c vps_init.conf] [опции]
# Справка:  ./vps_init.sh --help
#
# Порядок применения настроек: значения по умолчанию ниже -> файл конфига -> флаги командной строки.
# Модули из modules/ выполняются по порядку имён; каждый — в отдельном подпроцессе,
# поэтому ошибка в одном модуле не роняет остальные (кроме фатальной, код 99).

set -Eeuo pipefail

VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/utils.sh
source "$SCRIPT_DIR/lib/utils.sh"

# ---------------------------------------------------------------------------
# Значения по умолчанию. Подробное описание каждого — в vps_init.conf.example.
# ---------------------------------------------------------------------------
PROFILE="server"                 # server | desktop

USERNAME=""
COPY_ROOT_KEYS=true
SSH_PUBLIC_KEYS=()

APT_UPGRADE=true
TIMEZONE="Europe/Moscow"
NEW_HOSTNAME=""
ENABLE_AUTO_UPGRADES=false
ENABLE_SWAP=false
SWAP_SIZE="2G"

SSH_DISABLE_ROOT_LOGIN=true
SSH_DISABLE_PASSWORD_AUTH=true

UFW_ALLOW_HTTP=true
UFW_EXTRA_PORTS=()
ENABLE_FAIL2BAN=true

GIT_USER_NAME=""
GIT_USER_EMAIL=""

DOCKER_LOG_MAX_SIZE="10m"
DOCKER_LOG_MAX_FILE=3
DOCKER_PRUNE_SCHEDULE="weekly"

MODULES_SKIP=()
MODULES_ONLY=()

# Модули, которые профиль desktop пропускает (на рабочей машине SSH и firewall не трогаем).
PROFILE_DESKTOP_SKIP=(ssh firewall)

CONFIG_FILE=""
LOCK_FILE="${VPS_INIT_LOCK_FILE:-/run/vps_init.lock}"

usage() {
  cat <<EOF
vps_init $VERSION — первичная настройка Linux-машины (Ubuntu/Debian)

Использование: sudo ./vps_init.sh [опции]

  -c, --config FILE    файл конфигурации (по умолчанию ./vps_init.conf, если он есть)
  -u, --user NAME      имя пользователя (переопределяет USERNAME)
  -p, --profile NAME   server | desktop (переопределяет PROFILE)
      --only LIST      выполнить только эти модули, через запятую: --only system,tools
      --skip LIST      пропустить модули, через запятую: --skip docker
  -l, --list           показать список модулей и выйти
  -V, --version        показать версию и выйти
  -h, --help           эта справка

Модули можно указывать полным именем (60_tools) или коротким (tools).
Лог каждого запуска: $LOG_DIR/vps_init-<дата>.log (последний — latest.log)
EOF
}

# Описание модуля берётся из строки MODULE_DESC="..." в его файле.
module_desc() {
  sed -n 's/^MODULE_DESC="\(.*\)"$/\1/p' "$1"
}

list_modules() {
  local file
  echo "Модули (выполняются по порядку):"
  for file in "$SCRIPT_DIR"/modules/*.sh; do
    printf '  %-14s %s\n' "$(basename "$file" .sh)" "$(module_desc "$file")"
  done
}

# Совпадает ли модуль (например, 60_tools) с именем из списка (60_tools или tools).
module_in_list() {
  local name="$1" item
  shift
  for item in "$@"; do
    if [[ "$item" == "$name" || "$item" == "${name#*_}" ]]; then
      return 0
    fi
  done
  return 1
}

# Флаги разбираются до загрузки конфига, а применяются после — чтобы флаги имели приоритет.
CLI_USERNAME="" CLI_PROFILE="" CLI_ONLY="" CLI_SKIP=""

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -c | --config)  CONFIG_FILE="${2:?не указан файл для $1}"; shift 2 ;;
      -u | --user)    CLI_USERNAME="${2:?не указано имя для $1}"; shift 2 ;;
      -p | --profile) CLI_PROFILE="${2:?не указан профиль для $1}"; shift 2 ;;
      --only)         CLI_ONLY="${2:?не указан список для $1}"; shift 2 ;;
      --skip)         CLI_SKIP="${2:?не указан список для $1}"; shift 2 ;;
      -l | --list)    list_modules; exit 0 ;;
      -V | --version) echo "vps_init $VERSION"; exit 0 ;;
      -h | --help)    usage; exit 0 ;;
      *) echo "Неизвестный параметр: $1 (см. --help)" >&2; exit 2 ;;
    esac
  done
}

load_config() {
  if [[ -z "$CONFIG_FILE" && -f "$SCRIPT_DIR/vps_init.conf" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/vps_init.conf"
  fi
  if [[ -n "$CONFIG_FILE" ]]; then
    if [[ ! -r "$CONFIG_FILE" ]]; then
      echo "Не удаётся прочитать конфиг: $CONFIG_FILE" >&2
      exit 2
    fi
    # shellcheck source=vps_init.conf.example
    source "$CONFIG_FILE"
  fi

  if [[ -n "$CLI_USERNAME" ]]; then USERNAME="$CLI_USERNAME"; fi
  if [[ -n "$CLI_PROFILE" ]]; then PROFILE="$CLI_PROFILE"; fi
  if [[ -n "$CLI_ONLY" ]]; then IFS=',' read -r -a MODULES_ONLY <<<"$CLI_ONLY"; fi
  if [[ -n "$CLI_SKIP" ]]; then IFS=',' read -r -a MODULES_SKIP <<<"$CLI_SKIP"; fi
}

validate_config() {
  local errors=()
  case "$PROFILE" in
    server | desktop) ;;
    *) errors+=("PROFILE должен быть server или desktop, а не '$PROFILE'") ;;
  esac
  if [[ -n "$USERNAME" && ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    errors+=("USERNAME '$USERNAME' недопустим: строчные латинские буквы, цифры, _ и -, начинается с буквы")
  fi
  local label='[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'
  if [[ -n "$NEW_HOSTNAME" && ! "$NEW_HOSTNAME" =~ ^$label(\.$label)*$ ]]; then
    errors+=("NEW_HOSTNAME '$NEW_HOSTNAME' недопустим: латинские буквы, цифры, - и точки (например, web1 или web1.example.com)")
  fi
  if [[ ! "$SWAP_SIZE" =~ ^[1-9][0-9]*[MmGg]$ ]]; then
    errors+=("SWAP_SIZE '$SWAP_SIZE' недопустим: число с M или G, например 2G или 512M")
  fi
  local flag
  for flag in APT_UPGRADE ENABLE_SWAP ENABLE_AUTO_UPGRADES COPY_ROOT_KEYS \
    SSH_DISABLE_ROOT_LOGIN SSH_DISABLE_PASSWORD_AUTH UFW_ALLOW_HTTP ENABLE_FAIL2BAN; do
    if [[ "${!flag}" != true && "${!flag}" != false ]]; then
      errors+=("$flag должен быть true или false, а не '${!flag}'")
    fi
  done
  if (( ${#errors[@]} > 0 )); then
    printf 'Ошибка конфигурации: %s\n' "${errors[@]}" >&2
    exit 2
  fi
}

# Причина, по которой модуль не будет выполняться (пустая строка — выполняется).
module_skip_reason() {
  local name="$1"
  if (( ${#MODULES_ONLY[@]} > 0 )) && ! module_in_list "$name" "${MODULES_ONLY[@]}"; then
    echo "не входит в --only"
  elif (( ${#MODULES_SKIP[@]} > 0 )) && module_in_list "$name" "${MODULES_SKIP[@]}"; then
    echo "отключён (--skip / MODULES_SKIP)"
  elif [[ "$PROFILE" == desktop ]] && module_in_list "$name" "${PROFILE_DESKTOP_SKIP[@]}"; then
    echo "не нужен для профиля desktop"
  fi
}

# Запуск одного модуля в подпроцессе. Возвращает 99, если модуль сообщил о фатальной ошибке.
run_module() {
  local file="$1" name reason rc=0
  name="$(basename "$file" .sh)"
  CURRENT_MODULE="$name"

  reason="$(module_skip_reason "$name")"
  if [[ -n "$reason" ]]; then
    log_skip "Модуль $name: $reason"
    return 0
  fi

  log_section "$name — $(module_desc "$file")"
  set +e
  (
    set -Eeuo pipefail
    trap 'log_debug "Ошибка: строка $LINENO, команда: $BASH_COMMAND"' ERR
    # shellcheck source=/dev/null
    source "$file"
    module_run
  )
  rc=$?
  set -e

  if (( rc == 99 )); then
    return 99
  elif (( rc != 0 )); then
    log_fail "Модуль $name прерван (код $rc), остальные модули продолжают работу"
  fi
  return 0
}

on_exit() {
  local rc=$?
  print_summary
  rm -f "$SUMMARY_FILE"
  exit "$rc"
}

main() {
  parse_args "$@"
  load_config
  validate_config
  require_root "$@"

  # Защита от двух одновременных запусков.
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "vps_init уже запущен (блокировка $LOCK_FILE)" >&2
    exit 1
  fi

  log_init
  trap on_exit EXIT
  trap 'exit 130' INT TERM

  detect_os
  detect_arch
  log_info "vps_init $VERSION | профиль: $PROFILE | конфиг: ${CONFIG_FILE:-нет (значения по умолчанию)}"
  log_info "Система: ${OS_PRETTY:-неизвестно}, архитектура: $ARCH_UNAME"
  log_info "Лог: $LOG_FILE"

  local file
  for file in "$SCRIPT_DIR"/modules/*.sh; do
    if ! run_module "$file"; then
      log_fail "Фатальная ошибка в модуле $(basename "$file" .sh), выполнение остановлено"
      exit 1
    fi
  done
}

main "$@"
