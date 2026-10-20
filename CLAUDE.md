# CLAUDE.md — vps_init

Проект: учебный материал (`vps_init.md`) + bash-скрипт (`vps_init.sh`) для первичной настройки
Linux-машины (VPS на cloud.ru / timeweb / DigitalOcean, а также локальные машины).
Пользователь — Алексей; общение и вся документация, комментарии, сообщения скрипта — **на русском**.

## Правила работы (от пользователя)

- Работаем **пошагово**: один шаг (обычно один модуль + его раздел в `vps_init.md`) → короткий отчёт → ждём «дальше».
- **После каждого шага обновлять этот файл**: раздел «Прогресс» и, если появились, новые решения/соглашения.
- Пользователь пока **не тестирует** на реальном сервере — проверяем сами: `bash -n` и прогон копии
  в scratchpad (см. «Как проверять»). shellcheck в системе не установлен.
- Пользователь не всегда знаком с терминами (zsh, tmux, hardening) — при вопросах объяснять простыми словами.

## Принятые решения

| Блок | Решение |
|---|---|
| ОС / арх. | Ubuntu 22.04+ и Debian 12+ (только apt); amd64 + arm64 (`ARCH`=amd64/arm64, `ARCH_UNAME`=x86_64/aarch64) |
| Профили | `server` (всё) и `desktop` (пропускает модули `ssh`, `firewall`) |
| Доступ | Обычно на свежий VPS заходит `root` по SSH-ключу, добавленному в панели хостинга |
| Пользователь | Один (свой), группы `sudo` + `docker`; **sudo с паролем**; пароль вводится интерактивно, не логируется |
| SSH-ключи | Копировать из `/root/.ssh/authorized_keys` (`COPY_ROOT_KEYS`) + `SSH_PUBLIC_KEYS` в конфиге |
| SSH | `PermitRootLogin no`, `PasswordAuthentication no`; **порт остаётся 22**; применять только если у пользователя есть ключ; `sshd -t` перед reload |
| Firewall | UFW: 22, 80, 443 + `UFW_EXTRA_PORTS`; fail2ban для sshd |
| Система | timezone (Europe/Moscow), hostname, NTP; опционально (выкл. по умолчанию): unattended-upgrades, swap |
| apt upgrade | `APT_UPGRADE=true` по умолчанию; `upgrade --with-new-pkgs` (не full-upgrade — ничего не удаляет); без авто-reboot, только WARN + NOTE |
| Автообновления | `ENABLE_AUTO_UPGRADES=false` = **не трогать** (не выключать заводские на Ubuntu); `true` = поставить + `20auto-upgrades` |
| Hostname | + строка `127.0.1.1` в `/etc/hosts` + cloud-init `preserve_hostname: true`, `manage_etc_hosts: false` |
| Swap | `/swapfile`, только если swap нет; fallocate → fallback dd; `vm.swappiness=10` в `/etc/sysctl.d/99-vps-init-swap.conf` |
| VPN | не нужен (возможно, позже отдельным модулем) |
| Shell | **bash** (не zsh): улучшенный `.bashrc`, bash-completion, алиасы, **простой PS1** с git-веткой, fzf (Ctrl+R) |
| Инструменты | **vim** (редактор по умолчанию + `.vimrc`), **tmux** (+ `.tmux.conf` с мышью), bat, eza, btop, htop, ncdu, duf, jq, yq, git + `.gitconfig` |
| Не ставим | zoxide, tldr, ripgrep, fd, сетевые утилиты (mtr/nmap/httpie), git-delta, lazygit, gh |
| Docker | только Docker (приложения в compose): Docker Engine + compose plugin из офиц. репо, ротация логов в `daemon.json`, lazydocker, `docker prune` по systemd timer |
| Не делаем | reverse proxy (только пример в материале), мониторинг, бэкапы — позже |
| Управление | конфиг `vps_init.conf` (bash, KEY=value) + флаги; спрашивается только пароль |
| Структура | модули `modules/NN_name.sh` + главный `vps_init.sh`; `dotfiles/` для конфигов пользователя |
| Логи | `/var/log/vps_init/vps_init-<дата>.log` (+ `latest.log`), цветная консоль, итоговая сводка. Без Telegram, без dry-run |
| Материал | подробный учебник (зачем → вручную → что делает скрипт → проверка → частые ошибки) + шпаргалка в конце |

## Архитектура и соглашения

- `vps_init.sh`: значения по умолчанию → `source` конфига → флаги (`CLI_*`) → `validate_config` → root → `flock` → `log_init` → модули по порядку.
- Модуль = файл `modules/NN_name.sh` с `MODULE_DESC="..."` (одна строка, в двойных кавычках — парсится sed'ом) и функцией `module_run`.
  Выполняется в подпроцессе `( set -Eeuo pipefail; source file; module_run )` — функции/переменные модулей изолированы,
  переменные конфига доступны. Ошибка прерывает модуль, остальные продолжают. `fatal` (exit 99) останавливает весь запуск.
- Модули не могут передавать переменные друг другу — каждый сам читает конфиг/систему.
- Имена модулей во флагах: полное (`60_tools`) или короткое (`tools`) — `module_in_list`.
- `lib/log.sh`: `log_section`, `log_info`, `log_ok`, `log_skip`, `log_warn`, `log_fail`, `log_debug` (только файл),
  `log_note` (блок «Что дальше» в сводке), `run "Описание" cmd args...` (вывод команды → в лог, в консоль — статус).
  OK/SKIP/WARN/FAIL/NOTE пишутся в `SUMMARY_FILE` (переживает подпроцессы) → `print_summary` в trap EXIT.
  **В `run` нельзя передавать пароли** — аргументы логируются. Для конвейеров: `run "..." bash -c '...'`.
- `lib/utils.sh`: `require_root`, `fatal`, `command_exists`, `detect_os` (OS_ID/OS_VERSION/OS_CODENAME/OS_PRETTY),
  `detect_arch`, `pkg_installed`, `apt_get ...` (обёртка: noninteractive, `NEEDRESTART_MODE=a`, lock timeout 300,
  `--force-confdef/confold` — **все вызовы apt-get только через неё**), `apt_update [force]` (штамп в `STATE_DIR`, 60 мин),
  `apt_install` (только недостающие), `backup_file` (`file.bak.<дата>`), `ensure_line`,
  `install_file src dest [mode] [owner]` (ставит `FILE_CHANGED`), `write_file dest [mode] [owner] <<'EOF'` (то же из stdin).
- Свои конфиги в системе — отдельными файлами `*.d/99-vps-init-*.conf` (sysctl, cloud-init, позже sshd/fail2ban), а не правкой основных.
- Новые настройки: дефолт в `vps_init.sh` + описание в `vps_init.conf.example` + проверка в `validate_config`
  (булевы флаги перечислены в цикле `for flag in ...` — добавлять туда новые).
- Чтение вывода apt и прочих утилит — с `LC_ALL=C`.
- Идемпотентность обязательна: каждый шаг сначала проверяет состояние, иначе `log_skip`.
- Перед изменением системного конфига — `backup_file`.
- Стиль bash: 2 пробела, `[[ ]]`, `(( ))`, `local`, функции с `if` вместо `cond && action` в конце функции (иначе ложный код возврата + set -e).
- Не парсить локализованный вывод (`free` → `/proc/meminfo`); на машине пользователя русская локаль.
- Переменные окружения для тестов: `VPS_INIT_LOG_DIR`, `VPS_INIT_STATE_DIR`, `VPS_INIT_LOCK_FILE`.

## Как проверять

```bash
for f in vps_init.sh lib/*.sh modules/*.sh; do bash -n "$f"; done
# Прогон без root (unshare в sandbox запрещён): копия в scratchpad с отключённым require_root
S=<scratchpad>; rm -rf $S/t && mkdir -p $S/t && cp -r . $S/t/
sed -i 's/^require_root() {/require_root() { return 0;/' $S/t/lib/utils.sh
cd $S/t && VPS_INIT_LOG_DIR=$S/log VPS_INIT_STATE_DIR=$S/state VPS_INIT_LOCK_FILE=$S/lock ./vps_init.sh -c vps_init.conf.example --only preflight
```
Модули, меняющие систему (apt, useradd, sshd), локально не запускать — только синтаксис и логика.

## Прогресс

- [x] **Шаг 1 — каркас**: `vps_init.sh`, `lib/log.sh`, `lib/utils.sh`, `vps_init.conf.example`, `.gitignore`,
      `modules/00_preflight.sh`; `vps_init.md` — введение, разделы 0 (как пользоваться), 1 (как устроен скрипт), 2 (preflight). Проверено прогоном.
- [x] **Шаг 2 — `10_system`**: базовые пакеты (ca-certificates curl wget gnupg unzip sudo), apt upgrade, timezone, NTP
      (timesyncd; chrony не трогаем), hostname, swap (опц.), unattended-upgrades (опц.), проверка reboot-required;
      в utils добавлены `apt_get`, `write_file`; в конфиг — `APT_UPGRADE`; `validate_config` проверяет hostname, SWAP_SIZE, булевы флаги.
      `vps_init.md` — раздел 3. Проверено: `bash -n`, preflight-прогон, валидация конфига, функции модуля с заглушками.
- [ ] Шаг 3 — `20_user`: пользователь, пароль (интерактивно), группы, authorized_keys, `log_note` про `ssh user@ip`
- [ ] Шаг 4 — `30_ssh`: hardening через `/etc/ssh/sshd_config.d/`, проверка ключей, `sshd -t`
- [ ] Шаг 5 — `40_firewall`: UFW + fail2ban
- [ ] Шаг 6 — `50_shell` + `dotfiles/.bashrc`: PS1, история, алиасы, bash-completion, fzf
- [ ] Шаг 7 — `60_tools` + `dotfiles/.vimrc`, `.tmux.conf`, `.gitconfig`: vim, tmux, bat, eza, btop, htop, ncdu, duf, jq, yq, git (бинарники с GitHub — по `ARCH`)
- [ ] Шаг 8 — `70_docker`: Docker Engine + compose, daemon.json, группа docker, lazydocker, prune-таймер; пример reverse proxy в материале
- [ ] Шаг 9 — шпаргалка в `vps_init.md` (tmux, vim, docker, ufw, systemd, логи), финальная вычитка
