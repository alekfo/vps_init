# lib/utils.sh — общие хелперы для модулей.
# Все функции идемпотентны: повторный вызов не ломает уже сделанное.

STATE_DIR="${VPS_INIT_STATE_DIR:-/var/lib/vps_init}"

# Сколько ждать, если dpkg занят (на свежем VPS при загрузке часто работает unattended-upgrades).
APT_LOCK_TIMEOUT=300

require_root() {
  if (( EUID != 0 )); then
    echo "Скрипт нужно запускать от root: sudo $0 $*" >&2
    exit 1
  fi
}

# Фатальная ошибка: прерывает модуль с кодом 99, и главный скрипт останавливает весь запуск.
fatal() {
  log_fail "$*"
  exit 99
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Заполняет OS_ID (ubuntu/debian), OS_VERSION (24.04/12), OS_CODENAME (noble/bookworm), OS_PRETTY.
detect_os() {
  OS_ID="" OS_VERSION="" OS_CODENAME="" OS_PRETTY=""
  if [[ -r /etc/os-release ]]; then
    OS_ID="$(. /etc/os-release && echo "${ID:-}")"
    OS_VERSION="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    OS_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    OS_PRETTY="$(. /etc/os-release && echo "${PRETTY_NAME:-}")"
  fi
}

# Заполняет ARCH в стиле Debian-пакетов (amd64/arm64) и ARCH_UNAME в стиле uname (x86_64/aarch64).
# В названиях релизов на GitHub встречаются оба варианта — используйте нужный.
detect_arch() {
  ARCH_UNAME="$(uname -m)"
  case "$ARCH_UNAME" in
    x86_64 | amd64) ARCH="amd64" ARCH_UNAME="x86_64" ;;
    aarch64 | arm64) ARCH="arm64" ARCH_UNAME="aarch64" ;;
    *) ARCH="unknown" ;;
  esac
}

# Установлен ли deb-пакет.
pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# apt-get без вопросов: ждёт блокировку dpkg; при обновлении конфиг-файлов пакетов
# оставляет локальные изменения (confold), новые версии кладёт рядом как *.dpkg-dist;
# needrestart (Ubuntu) сам перезапускает службы вместо интерактивного окна.
apt_get() {
  env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# apt_update [force] — обновляет списки пакетов, если это не делалось последний час
# (или всегда, если передан force — например, после добавления нового репозитория).
apt_update() {
  local stamp="$STATE_DIR/apt_update.stamp"
  mkdir -p "$STATE_DIR"
  if [[ "${1:-}" != force && -n "$(find "$stamp" -mmin -60 2>/dev/null)" ]]; then
    log_skip "apt update: списки пакетов свежие"
    return 0
  fi
  run "apt update" apt_get update
  touch "$stamp"
}

# apt_install пакет1 пакет2 ... — ставит только то, чего ещё нет.
apt_install() {
  local pkg missing=()
  for pkg in "$@"; do
    if ! pkg_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done
  if (( ${#missing[@]} == 0 )); then
    log_skip "Уже установлено: $*"
    return 0
  fi
  run "Установка: ${missing[*]}" apt_get install -y --no-install-recommends "${missing[@]}"
}

# Резервная копия файла рядом с ним: file.bak.2026-10-20_211500
backup_file() {
  if [[ -f "$1" ]]; then
    local backup
    backup="$1.bak.$(date +%F_%H%M%S)"
    cp -a "$1" "$backup"
    log_debug "Резервная копия: $1 -> $backup"
  fi
}

# Добавляет строку в файл, если точно такой строки там ещё нет.
ensure_line() {
  local file="$1" line="$2"
  touch "$file"
  if ! grep -qxF -- "$line" "$file"; then
    printf '%s\n' "$line" >>"$file"
    log_debug "Добавлено в $file: $line"
  fi
}

# install_file источник назначение [права] [владелец]
# Копирует файл, только если содержимое отличается; старую версию сохраняет в бэкап.
# Результат — в FILE_CHANGED (1 — файл изменён, 0 — уже актуален), чтобы модуль мог,
# например, перезапустить сервис только при реальном изменении конфига.
install_file() {
  local src="$1" dest="$2" mode="${3:-644}" owner="${4:-root:root}"
  FILE_CHANGED=0
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    log_skip "$dest уже актуален"
    return 0
  fi
  backup_file "$dest"
  mkdir -p "$(dirname "$dest")"
  install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dest"
  FILE_CHANGED=1
  log_ok "Записан $dest"
}

# write_file назначение [права] [владелец] <<'EOF' ... EOF
# То же, что install_file, но содержимое берётся из stdin (удобно для небольших конфигов).
write_file() {
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  install_file "$tmp" "$@"
  rm -f "$tmp"
}
