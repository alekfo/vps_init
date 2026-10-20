# modules/00_preflight.sh — проверки перед запуском.
# Ничего не меняет в системе. Если ОС или архитектура не поддерживаются — останавливает весь запуск.

MODULE_DESC="Проверки: ОС, архитектура, сеть, диск, память"

module_run() {
  check_os
  check_arch
  check_network
  check_disk
  check_memory
}

check_os() {
  case "$OS_ID" in
    ubuntu)
      log_ok "ОС: $OS_PRETTY"
      if [[ "${OS_VERSION%%.*}" -lt 22 ]]; then
        log_warn "Ubuntu $OS_VERSION старше 22.04 — скрипт на ней не проверялся"
      fi
      ;;
    debian)
      log_ok "ОС: $OS_PRETTY"
      if [[ "${OS_VERSION%%.*}" -lt 12 ]]; then
        log_warn "Debian $OS_VERSION старше 12 — скрипт на ней не проверялся"
      fi
      ;;
    *)
      fatal "Неподдерживаемая ОС: ${OS_PRETTY:-неизвестно}. Поддерживаются Ubuntu и Debian"
      ;;
  esac
}

check_arch() {
  case "$ARCH" in
    amd64 | arm64) log_ok "Архитектура: $ARCH_UNAME" ;;
    *) fatal "Неподдерживаемая архитектура: $(uname -m). Поддерживаются x86_64 и aarch64" ;;
  esac
}

# Проверка без curl (на минимальных образах его может не быть): DNS через getent,
# TCP-соединение через встроенный в bash /dev/tcp.
check_network() {
  local host="github.com"
  if ! getent hosts "$host" >/dev/null; then
    fatal "Не работает DNS: не удаётся разрешить $host"
  fi
  if ! timeout 5 bash -c "exec 3<>/dev/tcp/$host/443" 2>/dev/null; then
    fatal "Нет доступа в интернет: не удаётся подключиться к $host:443"
  fi
  log_ok "Сеть: DNS и доступ в интернет работают"
}

check_disk() {
  local free_mb
  free_mb="$(df -Pm / | awk 'NR == 2 { print $4 }')"
  if (( free_mb < 2048 )); then
    log_warn "Свободно на / только ${free_mb} МБ — Docker-образам может не хватить места"
  else
    log_ok "Свободно на диске: $((free_mb / 1024)) ГБ"
  fi
}

# Читаем /proc/meminfo, а не free: вывод free зависит от локали ("Mem:" / "Пам:").
check_memory() {
  local mem_mb swap_mb
  mem_mb="$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)"
  swap_mb="$(awk '/^SwapTotal:/ { print int($2 / 1024) }' /proc/meminfo)"
  log_ok "Память: ${mem_mb} МБ RAM, ${swap_mb} МБ swap"
  if (( mem_mb < 2048 && swap_mb == 0 )) && [[ "$ENABLE_SWAP" != true ]]; then
    log_warn "Мало RAM и нет swap — рекомендуется ENABLE_SWAP=true в конфиге"
  fi
}
