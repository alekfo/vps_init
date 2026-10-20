# lib/log.sh — логирование.
#
# В консоль выводится краткий цветной статус каждого шага ([ OK ] / [SKIP] / [FAIL]),
# в лог-файл — всё подробно, с временем, модулем и полным выводом команд.
# Каждый статус также записывается в файл сводки, из которого в конце строится отчёт.
#
# ВАЖНО: всё, что передаётся в run(), попадает в лог. Никогда не передавайте туда пароли.

LOG_DIR="${VPS_INIT_LOG_DIR:-/var/log/vps_init}"
LOG_FILE=""
SUMMARY_FILE=""
CURRENT_MODULE="main"
START_TS="$(date +%s)"

# Цвета только для интерактивного терминала (и если не задан NO_COLOR).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
  IS_TTY=1
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
  IS_TTY=0
fi

# Создаёт каталог логов, лог-файл текущего запуска и файл сводки.
log_init() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  LOG_FILE="$LOG_DIR/vps_init-$(date +%F_%H-%M-%S).log"
  : >"$LOG_FILE"
  chmod 600 "$LOG_FILE"
  ln -sfn "$LOG_FILE" "$LOG_DIR/latest.log"
  SUMMARY_FILE="$(mktemp)"
}

# Запись строки в лог-файл: "дата [УРОВЕНЬ] [модуль] сообщение".
_log_file() {
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s [%-5s] [%s] %s\n' "$(date '+%F %T')" "$1" "$CURRENT_MODULE" "$2" >>"$LOG_FILE"
  fi
}

# Запись статуса в файл сводки: "СТАТУС|модуль|сообщение".
_record() {
  if [[ -n "$SUMMARY_FILE" ]]; then
    printf '%s|%s|%s\n' "$1" "$CURRENT_MODULE" "$2" >>"$SUMMARY_FILE"
  fi
}

log_section() {
  printf '\n%s\n' "${C_BOLD}${C_CYAN}==> $*${C_RESET}"
  _log_file STEP "==> $*"
}

log_info()  { printf '  %s %s\n' "${C_BLUE}[INFO]${C_RESET}" "$*"; _log_file INFO "$*"; }
log_ok()    { printf '  %s %s\n' "${C_GREEN}[ OK ]${C_RESET}" "$*"; _log_file OK "$*"; _record OK "$*"; }
log_skip()  { printf '  %s %s\n' "${C_DIM}[SKIP]${C_RESET}" "${C_DIM}$*${C_RESET}"; _log_file SKIP "$*"; _record SKIP "$*"; }
log_warn()  { printf '  %s %s\n' "${C_YELLOW}[WARN]${C_RESET}" "$*" >&2; _log_file WARN "$*"; _record WARN "$*"; }
log_fail()  { printf '  %s %s\n' "${C_RED}[FAIL]${C_RESET}" "$*" >&2; _log_file FAIL "$*"; _record FAIL "$*"; }
log_debug() { _log_file DEBUG "$*"; }

# Заметка для блока «Что дальше» в итоговой сводке (например, как подключиться).
log_note()  { _log_file NOTE "$*"; _record NOTE "$*"; }

# run "Описание шага" команда [аргументы...]
# Выполняет команду, весь её вывод уходит в лог-файл, в консоль — только статус.
# Возвращает код завершения команды (в модуле с set -e ошибка прервёт модуль).
# Для конвейеров и перенаправлений: run "Описание" bash -c '...'
run() {
  local desc="$1"
  shift
  _log_file CMD "$desc: $*"
  if (( IS_TTY )); then
    printf '  %s %s' "${C_DIM}[ .. ]${C_RESET}" "$desc"
  fi

  local rc=0
  "$@" >>"${LOG_FILE:-/dev/null}" 2>&1 </dev/null || rc=$?

  if (( IS_TTY )); then
    printf '\r\e[K'
  fi
  if (( rc == 0 )); then
    log_ok "$desc"
  else
    log_fail "$desc (код $rc, подробности в $LOG_FILE)"
  fi
  return "$rc"
}

# Итоговый отчёт: счётчики, список предупреждений и ошибок, заметки «Что дальше».
# Печатается в консоль и дублируется в лог-файл.
print_summary() {
  if [[ -z "$SUMMARY_FILE" || ! -f "$SUMMARY_FILE" ]]; then
    return 0
  fi

  local ok skip warn fail elapsed status module msg
  ok="$(grep -c '^OK|' "$SUMMARY_FILE" || true)"
  skip="$(grep -c '^SKIP|' "$SUMMARY_FILE" || true)"
  warn="$(grep -c '^WARN|' "$SUMMARY_FILE" || true)"
  fail="$(grep -c '^FAIL|' "$SUMMARY_FILE" || true)"
  elapsed=$(( $(date +%s) - START_TS ))

  CURRENT_MODULE="summary"
  log_section "Итоги"
  _say "Выполнено: $ok   Пропущено: $skip   Предупреждений: $warn   Ошибок: $fail   Время: $((elapsed / 60))м $((elapsed % 60))с"

  if (( warn + fail > 0 )); then
    _say ""
    _say "Требуют внимания:"
    while IFS='|' read -r status module msg; do
      case "$status" in
        WARN) _say "  ${C_YELLOW}[WARN]${C_RESET} $module: $msg" ;;
        FAIL) _say "  ${C_RED}[FAIL]${C_RESET} $module: $msg" ;;
      esac
    done <"$SUMMARY_FILE"
  fi

  if grep -q '^NOTE|' "$SUMMARY_FILE"; then
    _say ""
    _say "Что дальше:"
    while IFS='|' read -r status module msg; do
      if [[ "$status" == NOTE ]]; then
        _say "  - $msg"
      fi
    done <"$SUMMARY_FILE"
  fi

  _say ""
  _say "Полный лог: $LOG_FILE"
}

# Строка отчёта: в консоль как есть, в лог — без цветовых кодов.
_say() {
  printf '  %s\n' "$*"
  if [[ -n "$LOG_FILE" ]]; then
    printf '  %s\n' "$*" | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"
  fi
}
